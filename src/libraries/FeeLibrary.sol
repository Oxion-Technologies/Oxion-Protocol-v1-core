// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 Oxion Protocol
pragma solidity ^0.8.24;

/// @dev Library for parsing swap fee info from PoolKey.fee:
/// 24 bits (upper 4 bits are used to store flag, if swap fee is static, parse lower 20 bits to get swap fee)
/// 1. flag to indicate the activation of dynamic swap fee, otherwise static swap fee is used
///     - if dynamic swap fee is activated, then the swap fee is controlled by IDynamicFeeManager(hook).getFee()
///     - if dynamic swap fee is not activated, then the swap fee is controlled by PoolKey.fee itself
/// 2. protocol fee is controlled by protocolFeeController, not PoolKey.fee
///     - protocol fee is controlled by IProtocolFeeController(hook).protocolFeeForPool()
library FeeLibrary {
    /// @dev swap fee is stored in PoolKey as uint24
    uint24 public constant STATIC_FEE_MASK = 0x0FFFFF;
    uint24 public constant DYNAMIC_FEE_FLAG = 0x800000; // 1000

    /// @dev used as max swap fee for a pool. for CL, its 100%, for bin, its 10%
    uint24 public constant ONE_HUNDRED_PERCENT_FEE = 1_000_000;
    uint24 public constant TEN_PERCENT_FEE = 100_000;

    /// @notice Checks if the provided fee value represents a dynamic fee.
    /// @dev This function is internal and should only be called from within the contract.
    /// @param self The fee value to be checked.
    /// @return True if the fee is dynamic, false otherwise.
    function isDynamicFee(uint24 self) internal pure returns (bool) {
        return self & DYNAMIC_FEE_FLAG != 0;
    }

    /// @notice Checks if the static fee is too large compared to the maximum fee.
    /// @dev This function is internal and should only be called from within the contract.
    /// @param self The static fee value.
    /// @param maxFee The maximum fee value.
    /// @return Whether the static fee is too large compared to the maximum fee.
    function isStaticFeeTooLarge(uint24 self, uint24 maxFee) internal pure returns (bool) {
        return self & STATIC_FEE_MASK >= maxFee;
    }

    /// @notice Retrieves the static fee value from the provided input.
    /// @dev This function is internal and should only be called from within the contract.
    /// @param self The input value containing the static fee.
    /// @return The static fee value extracted from the input.
    function getStaticFee(uint24 self) internal pure returns (uint24) {
        return self & STATIC_FEE_MASK;
    }
}
