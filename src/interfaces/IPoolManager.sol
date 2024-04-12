//SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Currency} from "../types/Currency.sol";
import {PoolKey} from "../types/PoolKey.sol";
import {Pool} from "../libraries/Pool.sol";
import {IFees} from "../interfaces/IFees.sol";
import {BalanceDelta} from "../types/BalanceDelta.sol";
import {PoolId} from "../types/PoolId.sol";
import {Position} from "../libraries/Position.sol";
import {IExtsload} from "../interfaces/IExtsload.sol";

interface IPoolManager is IFees, IExtsload {
    /// @notice PoolManagerMismatch is thrown when pool manager specified in the pool key does not match current contract
    error PoolManagerMismatch();
    /// @notice Pools must have a positive non-zero tickSpacing. Error in transmitted swapFee
    error TickSpacingError();
    /// @notice Error thrown when Unauthorized caller
    error UnauthorizedCaller();
     /// @notice Thrown when trying to interact with a non-initialized pool
    error PoolNotInitialized();
    /// @notice PoolKey must have currencies where address(currency0) < address(currency1)
    error CurrenciesInitializedOutOfOrder();

    /// @notice Emitted when protocol fee is updated
    /// @dev The event is emitted even if the updated protocolFee is the same as previous protocolFee
    event ProtocolFeeUpdated(PoolId indexed id, uint16 protocolFee);

    /// @notice Emitted when a new pool is initialized
    /// @param id The abi encoded hash of the pool key struct for the new pool
    /// @param currency0 The first currency of the pool by address sort order
    /// @param currency1 The second currency of the pool by address sort order
    /// @param fee The fee collected upon every swap in the pool, denominated in hundredths of a bip
    /// @param tickSpacing The minimum number of ticks between initialized ticks
    event Initialize(
        PoolId indexed id,
        Currency indexed currency0,
        Currency indexed currency1,
        uint24 fee,
        int24 tickSpacing
    );

    /// @notice Emitted when a liquidity position is modified
    /// @param id The abi encoded hash of the pool key struct for the pool that was modified
    /// @param sender The address that modified the pool
    /// @param tickLower The lower tick of the position
    /// @param tickUpper The upper tick of the position
    /// @param liquidityDelta The amount of liquidity that was added or removed
    event ModifyLiquidity(
        PoolId indexed id, 
        address indexed sender,
        int24 tickLower,
        int24 tickUpper, 
        int256 liquidityDelta
    );

    /// @notice Emitted for swaps between currency0 and currency1
    /// @param id The abi encoded hash of the pool key struct for the pool that was modified
    /// @param sender The address that initiated the swap call, and that received the callback
    /// @param amount0 The delta of the currency0 balance of the pool
    /// @param amount1 The delta of the currency1 balance of the pool
    /// @param sqrtPriceX96 The sqrt(price) of the pool after the swap, as a Q64.96
    /// @param liquidity The liquidity of the pool after the swap
    /// @param tick The log base 1.0001 of the price of the pool after the swap
    /// @param fee The fee collected upon every swap in the pool, denominated in hundredths of a bip
    /// @param protocolFee Protocol fee from the swap, and it is only on the input currency
    event Swap(
        PoolId indexed id,
        address indexed sender,
        int128 amount0,
        int128 amount1,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        int24 tick,
        uint24 fee,
        uint256 protocolFee
    );

    /// @notice Emitted when donate happen
    /// @param id The abi encoded hash of the pool key struct for the pool that was modified
    /// @param sender The address that modified the pool
    /// @param amount0 The delta of the currency0 balance of the pool
    /// @param amount1 The delta of the currency1 balance of the pool
    /// @param tick The donated tick
    event Donate(
        PoolId indexed id, 
        address indexed sender, 
        uint256 amount0, 
        uint256 amount1, 
        int24 tick
    );

    /// @notice Emitted when a new fee amount is enabled for pool creation
    /// @param fee The enabled fee, denominated in hundredths of a bip
    /// @param tickSpacing The minimum number of ticks between initialized ticks for pools created with the given fee
    event FeeAmountEnabled(
        uint24 indexed fee,
        int24 indexed tickSpacing
    );

    struct ModifyLiquidityParams {
        // the lower and upper tick of the position
        int24 tickLower;
        int24 tickUpper;
        // how to modify the liquidity
        int256 liquidityDelta;
    }

    struct SwapParams {
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Get the current value in slot0 of the given pool
    function getSlot0(PoolId id)
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint16 protocolFee, uint24 swapFee);

    /// @notice Get the current value of liquidity of the given pool
    function getLiquidity(PoolId id) external view returns (uint128 liquidity);

    /// @notice Get the current value of liquidity for the specified pool and position
    function getLiquidity(PoolId id, address owner, int24 tickLower, int24 tickUpper)
        external
        view
        returns (uint128 liquidity);

    /// @notice Get the position struct for a specified pool and position
    function getPosition(PoolId id, address owner, int24 tickLower, int24 tickUpper)
        external
        view
        returns (Position.Info memory position);

    /// @notice Initialize the state for a given pool ID
    function initialize(PoolKey memory key, uint160 sqrtPriceX96)
        external
        returns (int24 tick);

    /// @notice Modify the position for the given pool
    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params)
        external
        returns (BalanceDelta);

    /// @notice Swap against the given pool
    function swap(PoolKey memory key, SwapParams memory params)
        external
        returns (BalanceDelta);

    /// @notice Donate the given currency amounts to the pool with the given pool key
    function donate(PoolKey memory key, uint256 amount0, uint256 amount1)
        external
        returns (BalanceDelta);

    /// @notice Sets the protocol's swap fee for the given pool
    /// Protocol fee is always a portion of swap fee that is owed. If that underlying fee is 0, no protocol fee will accrue even if it is set to > 0.
    function setProtocolFee(PoolKey memory key) external;
}
