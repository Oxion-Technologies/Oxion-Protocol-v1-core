// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 Oxion Protocol
pragma solidity ^0.8.24;

import {Position} from "./Position.sol";
import {TickMath} from "./TickMath.sol";
import {BalanceDelta, toBalanceDelta} from "../types/BalanceDelta.sol";
import {Tick} from "./Tick.sol";
import {TickBitmap} from "./TickBitmap.sol";
import {SqrtPriceMath} from "./SqrtPriceMath.sol";
import {SafeCast} from "../libraries/SafeCast.sol";
import {FullMath} from "./FullMath.sol";
import {SwapMath} from "./SwapMath.sol";
import {LiquidityMath} from "./LiquidityMath.sol";

library Pool {
    using SafeCast for int256;
    using SafeCast for uint256;
    using Tick for mapping(int24 => Tick.Info);
    using TickBitmap for mapping(int16 => uint256);
    using Position for mapping(bytes32 => Position.Info);
    using Position for Position.Info;
    using LiquidityMath for uint128;
    using Pool for State;

    /// @notice Thrown when trying to initalize an already initialized pool
    error PoolAlreadyInitialized();

    /// @notice Thrown when trying to interact with a non-initialized pool
    error PoolNotInitialized();

    /// @notice Thrown when trying to swap amount of 0
    error SwapAmountCannotBeZero();

    /// @notice Thrown when sqrtPriceLimitX96 is out of range
    /// @param sqrtPriceCurrentX96 current price in the pool
    /// @param sqrtPriceLimitX96 The price limit specified by user
    error InvalidSqrtPriceLimit(uint160 sqrtPriceCurrentX96, uint160 sqrtPriceLimitX96);

    /// @notice Thrown by donate if there is currently 0 liquidity, since the fees will not go to any liquidity providers
    error NoLiquidityToReceiveFees();

    struct Slot0 {
        // the current price
        uint160 sqrtPriceX96;
        // the current tick
        int24 tick;
        // protocol swap fee represented as integer denominator (1/x), taken as a % of the LP swap fee
        // upper 8 bits are for 1->0, and the lower 8 are for 0->1
        // the minimum permitted denominator is 4 - meaning the maximum protocol fee is 25%
        // granularity is increments of 0.38% (100/type(uint8).max)
        /// bits          16 14 12 10 8  6  4  2  0
        ///               |         swap          |
        ///               ┌───────────┬───────────┬
        /// protocolFee : |  1->0     |  0 -> 1   |
        ///               └───────────┴───────────┴
        uint16 protocolFee;
        // used for the swap fee, either static at initialize
        uint24 swapFee;
    }

    struct State {
        Slot0 slot0;
        /// @dev swap fees
        uint256 feeGrowthGlobal0X128;
        uint256 feeGrowthGlobal1X128;
        /// @dev current active liquidity
        uint128 liquidity;         
        mapping(int24 => Tick.Info) ticks;
        mapping(int16 => uint256) tickBitmap;
        mapping(bytes32 => Position.Info) positions;
    }

    struct ModifyLiquidityParams {
        // the address that owns the position
        address owner;
        // the lower and upper tick of the position
        int24 tickLower;
        int24 tickUpper;
        // any change in liquidity
        int128 liquidityDelta;
        // the spacing between ticks
        int24 tickSpacing;
    }

    struct SwapCache {
        // liquidity at the beginning of the swap
        uint128 liquidityStart;
        // the protocol fee for the input token
        uint8 protocolFee;
    }

    // the top level state of the swap, the results of which are recorded in storage at the end
    struct SwapState {
        // the amount remaining to be swapped in/out of the input/output asset
        int256 amountSpecifiedRemaining;
        // the amount already swapped out/in of the output/input asset
        int256 amountCalculated;
        // current sqrt(price)
        uint160 sqrtPriceX96;
        // the tick associated with the current price
        int24 tick;
        // the swapFee
        uint24 swapFee;
        // the global fee growth of the input token
        uint256 feeGrowthGlobalX128;
        // amount of input token paid as protocol fee
        uint256 protocolFee;
        // the current liquidity in range
        uint128 liquidity;
    }

    struct StepComputations {
        // the price at the beginning of the step
        uint160 sqrtPriceStartX96;
        // the next tick to swap to from the current tick in the swap direction
        int24 tickNext;
        // whether tickNext is initialized or not
        bool initialized;
        // sqrt(price) for the next tick (1/0)
        uint160 sqrtPriceNextX96;
        // how much is being swapped in in this step
        uint256 amountIn;
        // how much is being swapped out
        uint256 amountOut;
        // how much fee is being paid in
        uint256 feeAmount;
    }

    struct SwapParams {
        // The spacing between ticks
        int24 tickSpacing;
        // Indicates whether the swap direction is from token0 to token1 (true) or token1 to token0 (false)
        bool zeroForOne;
        // The specified amount of input or output asset for the swap
        int256 amountSpecified;
        // The square root of the price limit for the swap, expressed as Q64.96
        uint160 sqrtPriceLimitX96;
    }

    struct UpdatePositionCache {
        // Indicates whether the position has been flipped to the lower tick
        bool flippedLower;
        // Indicates whether the position has been flipped to the upper tick
        bool flippedUpper;
        // Indicates whether the position has been flipped to the upper tick
        uint256 feeGrowthInside0X128;
        // Fee growth inside the position's range for token1
        uint256 feeGrowthInside1X128;
        // Fees owed for token0
        uint256 feesOwed0;
        // Fees owed for token1
        uint256 feesOwed1;
        // Maximum liquidity per tick for the position
        uint128 maxLiquidityPerTick;
    }

    /// @notice Initializes the pool state with the provided parameters.
    /// @dev This function is internal and should only be called from within the contract.
    /// @param self Reference to the storage state.
    /// @param sqrtPriceX96 The square root of the current price in Q64.96 format.
    /// @param protocolFee The protocol fee percentage.
    /// @param swapFee The swap fee percentage.
    /// @return tick The tick associated with the provided square root price.
    /// @dev Reverts if the pool is already initialized.
    function initialize(State storage self, uint160 sqrtPriceX96, uint16 protocolFee, uint24 swapFee)
        internal
        returns (int24 tick)
    {
        if (self.slot0.sqrtPriceX96 != 0) revert PoolAlreadyInitialized();

        tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);

        self.slot0 = Slot0({sqrtPriceX96: sqrtPriceX96, tick: tick, protocolFee: protocolFee, swapFee: swapFee});
    }

    /// @dev Effect changes to the liquidity of a position in a pool
    /// @param params the position details and the change to the position's liquidity to effect
    /// @return delta the deltas of the token balances of the pool
    function modifyLiquidity(State storage self, ModifyLiquidityParams memory params)
        internal
        returns (BalanceDelta delta)
    {
        Slot0 memory _slot0 = self.slot0; // SLOAD for gas optimization

        Tick.checkTicks(params.tickLower, params.tickUpper);

        (uint256 feesOwed0, uint256 feesOwed1) = _updatePosition(self, params, _slot0.tick);

        ///@dev calculate the tokens delta needed
        if (params.liquidityDelta != 0) {
            int128 amount0;
            int128 amount1;
            if (_slot0.tick < params.tickLower) {
                // current tick is below the passed range; liquidity can only become in range by crossing from left to
                // right, when we'll need _more_ currency0 (it's becoming more valuable) so user must provide it
                amount0 = SqrtPriceMath.getAmount0Delta(
                    TickMath.getSqrtRatioAtTick(params.tickLower),
                    TickMath.getSqrtRatioAtTick(params.tickUpper),
                    params.liquidityDelta
                ).toInt128();
            } else if (_slot0.tick < params.tickUpper) {
                amount0 = SqrtPriceMath.getAmount0Delta(
                    _slot0.sqrtPriceX96, TickMath.getSqrtRatioAtTick(params.tickUpper), params.liquidityDelta
                ).toInt128();
                amount1 = SqrtPriceMath.getAmount1Delta(
                    TickMath.getSqrtRatioAtTick(params.tickLower), _slot0.sqrtPriceX96, params.liquidityDelta
                ).toInt128();

                self.liquidity = LiquidityMath.addDelta(self.liquidity, params.liquidityDelta);
            } else {
                // current tick is above the passed range; liquidity can only become in range by crossing from right to
                // left, when we'll need _more_ currency1 (it's becoming more valuable) so user must provide it
                amount1 = SqrtPriceMath.getAmount1Delta(
                    TickMath.getSqrtRatioAtTick(params.tickLower),
                    TickMath.getSqrtRatioAtTick(params.tickUpper),
                    params.liquidityDelta
                ).toInt128();
            }

            // Amount required for updating liquidity
            delta = toBalanceDelta(amount0, amount1);
        }

        // Fees earned from LPing are removed from the pool balance.
        delta = delta - toBalanceDelta(feesOwed0.toInt128(), feesOwed1.toInt128());
    }
    
    /// @notice Executes a swap operation according to the provided parameters.
    /// @dev This function is internal and should only be called from within the contract.
    /// @param self Reference to the storage state.
    /// @param params Parameters specifying the swap operation.
    /// @return balanceDelta The change in token balances resulting from the swap.
    /// @return state The state of the swap after execution.
    /// @dev Reverts if the specified swap amount is zero or if the square root price limit is invalid.
    function swap(State storage self, SwapParams memory params)
        internal
        returns (BalanceDelta balanceDelta, SwapState memory state)
    {
        if (params.amountSpecified == 0) revert SwapAmountCannotBeZero();

        Slot0 memory slot0Start = self.slot0;
        if (
            params.zeroForOne
                ? (
                    params.sqrtPriceLimitX96 >= slot0Start.sqrtPriceX96
                        || params.sqrtPriceLimitX96 <= TickMath.MIN_SQRT_RATIO
                )
                : (
                    params.sqrtPriceLimitX96 <= slot0Start.sqrtPriceX96
                        || params.sqrtPriceLimitX96 >= TickMath.MAX_SQRT_RATIO
                )
        ) {
            revert InvalidSqrtPriceLimit(slot0Start.sqrtPriceX96, params.sqrtPriceLimitX96);
        }

        SwapCache memory cache = SwapCache({
            liquidityStart: self.liquidity,
            /// @dev 8 bits for protocol swap fee instead of 4 bits in v3
            protocolFee: params.zeroForOne ? uint8(slot0Start.protocolFee % 256) : uint8(slot0Start.protocolFee >> 8)
        });

        bool exactInput = params.amountSpecified > 0;

        state = SwapState({
            amountSpecifiedRemaining: params.amountSpecified,
            amountCalculated: 0,
            sqrtPriceX96: slot0Start.sqrtPriceX96,
            tick: slot0Start.tick,
            swapFee: slot0Start.swapFee,
            feeGrowthGlobalX128: params.zeroForOne ? self.feeGrowthGlobal0X128 : self.feeGrowthGlobal1X128,
            protocolFee: 0,
            liquidity: cache.liquidityStart
        });

        StepComputations memory step;
        // continue swapping as long as we haven't used the entire input/output and haven't reached the price limit
        while (state.amountSpecifiedRemaining != 0 && state.sqrtPriceX96 != params.sqrtPriceLimitX96) {
            step.sqrtPriceStartX96 = state.sqrtPriceX96;

            (step.tickNext, step.initialized) =
                self.tickBitmap.nextInitializedTickWithinOneWord(state.tick, params.tickSpacing, params.zeroForOne);

            // ensure that we do not overshoot the min/max tick, as the tick bitmap is not aware of these bounds
            if (step.tickNext < TickMath.MIN_TICK) {
                step.tickNext = TickMath.MIN_TICK;
            } else if (step.tickNext > TickMath.MAX_TICK) {
                step.tickNext = TickMath.MAX_TICK;
            }

            // get the price for the next tick
            step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.tickNext);

            // compute values to swap to the target tick, price limit, or point where input/output amount is exhausted
            (state.sqrtPriceX96, step.amountIn, step.amountOut, step.feeAmount) = SwapMath.computeSwapStep(
                state.sqrtPriceX96,
                (
                    params.zeroForOne
                        ? step.sqrtPriceNextX96 < params.sqrtPriceLimitX96
                        : step.sqrtPriceNextX96 > params.sqrtPriceLimitX96
                ) ? params.sqrtPriceLimitX96 : step.sqrtPriceNextX96,
                state.liquidity,
                state.amountSpecifiedRemaining,
                state.swapFee
            );

            if (exactInput) {
                /// @dev SwapMath will always ensure that amountSpecified > amountIn + feeAmount
                unchecked {
                    state.amountSpecifiedRemaining -= (step.amountIn + step.feeAmount).toInt256();
                }

                /// @dev amountCalculated is the amount of output token, hence neg in this case
                state.amountCalculated = state.amountCalculated - step.amountOut.toInt256();
            } else {
                unchecked {
                    state.amountSpecifiedRemaining += step.amountOut.toInt256();
                }
                state.amountCalculated = state.amountCalculated + (step.amountIn + step.feeAmount).toInt256();
            }

            /// @dev if the protocol fee is on, calculate how much is owed, decrement feeAmount, and increment protocolFee
            if (cache.protocolFee > 0) {
                uint256 delta = step.feeAmount / cache.protocolFee;
                unchecked {
                    step.feeAmount -= delta;
                    state.protocolFee += delta;
                }
            }

            // update global fee tracker
            if (state.liquidity > 0) {
                unchecked {
                    state.feeGrowthGlobalX128 += FullMath.mulDiv(step.feeAmount, FullMath.Q128, state.liquidity);
                }
            }

            // shift tick if we reached the next price
            if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
                // if the tick is initialized, run the tick transition
                if (step.initialized) {
                    int128 liquidityNet = self.ticks.cross(
                        step.tickNext,
                        (params.zeroForOne ? state.feeGrowthGlobalX128 : self.feeGrowthGlobal0X128),
                        (params.zeroForOne ? self.feeGrowthGlobal1X128 : state.feeGrowthGlobalX128)
                    );
                    // if we're moving leftward, we interpret liquidityNet as the opposite sign
                    // safe because liquidityNet cannot be type(int128).min
                    unchecked {
                        if (params.zeroForOne) liquidityNet = -liquidityNet;
                    }

                    state.liquidity = state.liquidity.addDelta(liquidityNet);
                }

                unchecked {
                    state.tick = params.zeroForOne ? step.tickNext - 1 : step.tickNext;
                }
            } else if (state.sqrtPriceX96 != step.sqrtPriceStartX96) {
                // recompute unless we're on a lower tick boundary (i.e. already transitioned ticks), and haven't moved
                state.tick = TickMath.getTickAtSqrtRatio(state.sqrtPriceX96);
            }
        }

        // update tick and price if changed
        if (state.tick != slot0Start.tick) {
            (self.slot0.sqrtPriceX96, self.slot0.tick) = (state.sqrtPriceX96, state.tick);
        } else {
            // otherwise just update the price
            self.slot0.sqrtPriceX96 = state.sqrtPriceX96;
        }

        // update liquidity if it changed
        if (cache.liquidityStart != state.liquidity) self.liquidity = state.liquidity;

        // update fee growth global
        if (params.zeroForOne) {
            self.feeGrowthGlobal0X128 = state.feeGrowthGlobalX128;
        } else {
            self.feeGrowthGlobal1X128 = state.feeGrowthGlobalX128;
        }

        unchecked {
            (int128 amount0, int128 amount1) = params.zeroForOne == exactInput
                ? ((params.amountSpecified - state.amountSpecifiedRemaining).toInt128(), state.amountCalculated.toInt128())
                : (
                    (state.amountCalculated.toInt128()),
                    (params.amountSpecified - state.amountSpecifiedRemaining).toInt128()
                );

            balanceDelta = toBalanceDelta(amount0, amount1);
        }
    }

    /// @notice Updates the position and associated ticks in the Oxion Protocol pool.
    /// @dev This function is internal and should only be called from within the contract.
    /// @param self Reference to the storage state.
    /// @param params Parameters specifying the liquidity modification.
    /// @param tick The current tick position.
    /// @return feesOwed0 The fees owed in token0 after the position update.
    /// @return feesOwed1 The fees owed in token1 after the position update.
    /// @dev This function updates the ticks, fee growth, and user positions within the pool.
    function _updatePosition(State storage self, ModifyLiquidityParams memory params, int24 tick)
        internal
        returns (uint256, uint256)
    {
        uint256 _feeGrowthGlobal0X128 = self.feeGrowthGlobal0X128; // SLOAD for gas optimization
        uint256 _feeGrowthGlobal1X128 = self.feeGrowthGlobal1X128; // SLOAD for gas optimization

        // @dev avoid stack too deep
        UpdatePositionCache memory cache;

        ///@dev update ticks if nencessary
        if (params.liquidityDelta != 0) {
            cache.maxLiquidityPerTick = Tick.tickSpacingToMaxLiquidityPerTick(params.tickSpacing);
            cache.flippedLower = self.ticks.update(
                params.tickLower,
                tick,
                params.liquidityDelta,
                _feeGrowthGlobal0X128,
                _feeGrowthGlobal1X128,
                false,
                cache.maxLiquidityPerTick
            );
            cache.flippedUpper = self.ticks.update(
                params.tickUpper,
                tick,
                params.liquidityDelta,
                _feeGrowthGlobal0X128,
                _feeGrowthGlobal1X128,
                true,
                cache.maxLiquidityPerTick
            );

            if (cache.flippedLower) {
                self.tickBitmap.flipTick(params.tickLower, params.tickSpacing);
            }
            if (cache.flippedUpper) {
                self.tickBitmap.flipTick(params.tickUpper, params.tickSpacing);
            }
        }

        (cache.feeGrowthInside0X128, cache.feeGrowthInside1X128) = self.ticks.getFeeGrowthInside(
            params.tickLower, params.tickUpper, tick, _feeGrowthGlobal0X128, _feeGrowthGlobal1X128
        );

        ///@dev update user position and collect fees
        /// must be done after ticks are updated in case of a 0 -> 1 flip
        (cache.feesOwed0, cache.feesOwed1) = self.positions.get(params.owner, params.tickLower, params.tickUpper).update(
            params.liquidityDelta, cache.feeGrowthInside0X128, cache.feeGrowthInside1X128
        );

        ///@dev clear any tick data that is no longer needed
        /// must be done after fee collection in case of a 1 -> 0 flip
        if (params.liquidityDelta < 0) {
            if (cache.flippedLower) {
                self.ticks.clear(params.tickLower);
            }
            if (cache.flippedUpper) {
                self.ticks.clear(params.tickUpper);
            }
        }

        return (cache.feesOwed0, cache.feesOwed1);
    }

    /// @notice Donates tokens to liquidity providers within the pool's range.
    /// @dev This function is internal and should only be called from within the contract.
    /// @param state Reference to the storage state.
    /// @param amount0 The amount of token0 to donate.
    /// @param amount1 The amount of token1 to donate.
    /// @return delta The change in token balances resulting from the donation.
    /// @return tick The current tick position.
    /// @dev Reverts if the pool has no liquidity to receive fees.
    /// @dev This function updates the global fee growth for token0 and token1 based on the donated amounts.
    function donate(State storage state, uint256 amount0, uint256 amount1)
        internal
        returns (BalanceDelta delta, int24 tick)
    {
        if (state.liquidity == 0) revert NoLiquidityToReceiveFees();
        delta = toBalanceDelta(amount0.toInt128(), amount1.toInt128());
        unchecked {
            if (amount0 > 0) {
                state.feeGrowthGlobal0X128 += FullMath.mulDiv(amount0, FullMath.Q128, state.liquidity);
            }
            if (amount1 > 0) {
                state.feeGrowthGlobal1X128 += FullMath.mulDiv(amount1, FullMath.Q128, state.liquidity);
            }
            tick = state.slot0.tick;
        }
    }

    /// @notice Sets the protocol fee for the pool.
    /// @dev This function is internal and should only be called from within the contract.
    /// @param self Reference to the storage state.
    /// @param protocolFee The new protocol fee to be set.
    /// @dev Reverts if the pool is not initialized.
    function setProtocolFee(State storage self, uint16 protocolFee) internal {
        if (self.isNotInitialized()) revert PoolNotInitialized();
        self.slot0.protocolFee = protocolFee;
    }

    // /// @notice Sets the swap fee for the pool.
    // /// @dev This function is internal and should only be called from within the contract.
    // /// @param self Reference to the storage state.
    // /// @param swapFee The new swap fee to be set.
    // /// @dev Reverts if the pool is not initialized.
    // function setSwapFee(State storage self, uint24 swapFee) internal {
    //     if (self.isNotInitialized()) revert PoolNotInitialized();
    //     self.slot0.swapFee = swapFee;
    // }

    /// @notice Checks if the pool is not initialized.
    /// @dev This function is internal and should only be called from within the contract.
    /// @param self Reference to the storage state.
    /// @return True if the pool is not initialized, false otherwise.
    function isNotInitialized(State storage self) internal view returns (bool) {
        return self.slot0.sqrtPriceX96 == 0;
    }
}
