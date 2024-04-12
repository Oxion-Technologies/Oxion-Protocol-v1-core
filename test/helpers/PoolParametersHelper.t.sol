// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PoolParametersHelper} from "../../src/libraries/PoolParametersHelper.sol";

contract PoolParametersHelperTest is Test {
    using PoolParametersHelper for bytes32;

    bytes32 params;

    function testFuzz_SetTickSpacing(int24 tickSpacing) external {
        bytes32 updatedParam = params.setTickSpacing(tickSpacing);
        assertEq(updatedParam.getTickSpacing(), tickSpacing);
    }
}
