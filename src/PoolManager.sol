// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 Oxion Protocol
pragma solidity ^0.8.24;

import {Fees} from "./Fees.sol";
import {IOxionStorage} from "./interfaces/IOxionStorage.sol";
import {PoolId, PoolIdLibrary} from "./types/PoolId.sol";
import {Pool} from "./libraries/Pool.sol";
import {Position} from "./libraries/Position.sol";
import {PoolKey} from "./types/PoolKey.sol";
import {IPoolManager} from "./interfaces/IPoolManager.sol";
import {IDynamicFeeManager} from "./interfaces/IDynamicFeeManager.sol";
import {PoolParametersHelper} from "./libraries/PoolParametersHelper.sol";
import {FeeLibrary} from "./libraries/FeeLibrary.sol";
import {PoolId, PoolIdLibrary} from "./types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "./types/BalanceDelta.sol";
import {Extsload} from "./Extsload.sol";
import {SafeCast} from "./libraries/SafeCast.sol";

contract PoolManager is IPoolManager, Fees, Extsload {
    using SafeCast for int256;
    using PoolIdLibrary for PoolKey;
    using FeeLibrary for uint24;
    using PoolParametersHelper for bytes32;
    using Pool for *;
    using Position for mapping(bytes32 => Position.Info);

    mapping(uint24 => int24) public feeAmountTickSpacing;

    mapping(PoolId id => Pool.State) public pools;

    constructor(IOxionStorage _oxionStorage, uint256 controllerGasLimit) Fees(_oxionStorage, controllerGasLimit) 
    {
        feeAmountTickSpacing[100] = 1;
        emit FeeAmountEnabled(100, 1);

        feeAmountTickSpacing[500] = 10;
        emit FeeAmountEnabled(500, 10);

        feeAmountTickSpacing[3000] = 60;
        emit FeeAmountEnabled(3000, 60);
    }

    /// @notice pool manager specified in the pool key must match current contract
    modifier poolManagerMatch(address poolManager) {
        if (address(this) != poolManager) revert PoolManagerMismatch();
        _;
    }

    /// @inheritdoc IPoolManager
    function getSlot0(PoolId id)
        external
        view
        override
        returns (uint160 sqrtPriceX96, int24 tick, uint16 protocolFee, uint24 swapFee)
    {
        Pool.Slot0 memory slot0 = pools[id].slot0;
        return (slot0.sqrtPriceX96, slot0.tick, slot0.protocolFee, slot0.swapFee);
    }

    /// @inheritdoc IPoolManager
    function getLiquidity(PoolId id) external view override returns (uint128 liquidity) {
        return pools[id].liquidity;
    }

    /// @inheritdoc IPoolManager
    function getLiquidity(PoolId id, address _owner, int24 tickLower, int24 tickUpper)
        external
        view
        override
        returns (uint128 liquidity)
    {
        return pools[id].positions.get(_owner, tickLower, tickUpper).liquidity;
    }

    /// @inheritdoc IPoolManager
    function getPosition(PoolId id, address owner, int24 tickLower, int24 tickUpper)
        external
        view
        override
        returns (Position.Info memory position)
    {
        return pools[id].positions.get(owner, tickLower, tickUpper);
    }

    /// @inheritdoc IPoolManager
    function initialize(PoolKey memory key, uint160 sqrtPriceX96)
        external
        override
        poolManagerMatch(address(key.poolManager))
        returns (int24 tick)
    {
        int24 tickSpacing = feeAmountTickSpacing[key.fee];

        if (tickSpacing == 0) revert TickSpacingError();
        if (key.currency0 >= key.currency1) revert CurrenciesInitializedOutOfOrder();
    
        PoolId id = key.toId();
        (, uint16 protocolFee) = _fetchProtocolFee(key);
        uint24 swapFee = key.fee;
        tick = pools[id].initialize(sqrtPriceX96, protocolFee, swapFee);

        /// @notice Make sure the first event is noted, so that later events from afterHook won't get mixed up with this one
        emit Initialize(id, key.currency0, key.currency1, key.fee, tickSpacing);
    }

    /// @inheritdoc IPoolManager
    function modifyLiquidity(
        PoolKey memory key,
        IPoolManager.ModifyLiquidityParams memory params
    ) external override poolManagerMatch(address(key.poolManager)) returns (BalanceDelta delta) {
        PoolId id = key.toId();
        _checkPoolInitialized(id);

        delta = pools[id].modifyLiquidity(
            Pool.ModifyLiquidityParams({
                owner: msg.sender,
                tickLower: params.tickLower,
                tickUpper: params.tickUpper,
                liquidityDelta: params.liquidityDelta.toInt128(),
                ///////////////////////////////////////////////////
                tickSpacing: feeAmountTickSpacing[key.fee]
            })
        );

        oxionStorage.accountPoolBalanceDelta(key, delta, msg.sender);

        /// @notice Make sure the first event is noted, so that later events from afterHook won't get mixed up with this one
        emit ModifyLiquidity(id, msg.sender, params.tickLower, params.tickUpper, params.liquidityDelta);
    }

    /// @inheritdoc IPoolManager
    function swap(PoolKey memory key, IPoolManager.SwapParams memory params)
        external
        override
        poolManagerMatch(address(key.poolManager))
        returns (BalanceDelta delta)
    {
        PoolId id = key.toId();
        _checkPoolInitialized(id);

        Pool.SwapState memory state;
        (delta, state) = pools[id].swap(
            Pool.SwapParams({
                ////////////////////////////////////////////////////////
                tickSpacing: feeAmountTickSpacing[key.fee],
                zeroForOne: params.zeroForOne,
                amountSpecified: params.amountSpecified,
                sqrtPriceLimitX96: params.sqrtPriceLimitX96
            })
        );

        /// @dev delta already includes protocol fee
        /// all tokens go into the Oxion Storage
        oxionStorage.accountPoolBalanceDelta(key, delta, msg.sender);
        
        unchecked {
            if (state.protocolFee > 0) {
                protocolFeesAccrued[params.zeroForOne ? key.currency0 : key.currency1] += state.protocolFee;
            }
        }

        /// @notice Make sure the first event is noted, so that later events from afterHook won't get mixed up with this one
        emit Swap(
            id,
            msg.sender,
            delta.amount0(),
            delta.amount1(),
            state.sqrtPriceX96,
            state.liquidity,
            state.tick,
            state.swapFee,
            state.protocolFee
        );
    }

    /// @inheritdoc IPoolManager
    function donate(PoolKey memory key, uint256 amount0, uint256 amount1)
        external
        override
        poolManagerMatch(address(key.poolManager))
        returns (BalanceDelta delta)
    {
        PoolId id = key.toId();
        _checkPoolInitialized(id);

        int24 tick;
        (delta, tick) = pools[id].donate(amount0, amount1);
        oxionStorage.accountPoolBalanceDelta(key, delta, msg.sender);

        /// @notice Make sure the first event is noted, so that later events from afterHook won't get mixed up with this one
        emit Donate(id, msg.sender, amount0, amount1, tick);
    }

    /// @inheritdoc IPoolManager
    function setProtocolFee(PoolKey memory key) external {
        (bool success, uint16 newProtocolFee) = _fetchProtocolFee(key);
        if (!success) revert ProtocolFeeControllerCallFailedOrInvalidResult();
        PoolId id = key.toId();
        pools[id].setProtocolFee(newProtocolFee);
        emit ProtocolFeeUpdated(id, newProtocolFee);
    }

    function _checkPoolInitialized(PoolId id) internal view {
        if (pools[id].isNotInitialized()) revert PoolNotInitialized();
    }
}
