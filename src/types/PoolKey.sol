//SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Currency} from "./Currency.sol";
import {IPoolManager} from "../interfaces/IPoolManager.sol";

/// @notice Returns the key for identifying a pool
struct PoolKey {
    /// @notice The lower currency of the pool, sorted numerically
    Currency currency0;
    /// @notice The higher currency of the pool, sorted numerically
    Currency currency1;
    /// @notice The pool manager of the pool
    IPoolManager poolManager;
    /// @notice The pool swap fee
    uint24 fee;
}
