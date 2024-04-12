// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {Test} from "forge-std/Test.sol";
import {PoolParametersHelper} from "../../src/libraries/PoolParametersHelper.sol";

contract PoolParametersHelperTest is Test, GasSnapshot {
    function testGetTickSpacing() public {
        bytes32 paramsWithTickSpacing0 = bytes32(uint256(0x0));
        int24 tickSpacing0 = PoolParametersHelper.getTickSpacing(paramsWithTickSpacing0);
        assertEq(tickSpacing0, 0);

        bytes32 paramsWithTickSpacingNegative13 = bytes32(uint256(0xfffff30000));
        snapStart("PoolParametersHelperTest#getTickSpacing");
        int24 tickSpacingNegative13 = PoolParametersHelper.getTickSpacing(paramsWithTickSpacingNegative13);
        snapEnd();
        assertEq(tickSpacingNegative13, -13);

        bytes32 paramsWithTickSpacing5 = bytes32(uint256(0x0000050000));
        int24 tickSpacingNegative5 = PoolParametersHelper.getTickSpacing(paramsWithTickSpacing5);
        assertEq(tickSpacingNegative5, 5);
    }
}
