// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {Currency} from "../../src/types/Currency.sol";
import {IPoolManager} from "../../src/interfaces/IPoolManager.sol";
import {PoolManager} from "../../src/PoolManager.sol";
import {PoolId, PoolIdLibrary} from "../../src/types/PoolId.sol";
import {PoolKey} from "../../src/types/PoolKey.sol";
import {Constants} from "./Constants.sol";
import {SortTokens} from "./SortTokens.sol";
import {OxionStorage} from "../../src/OxionStorage.sol";
import {IOxionStorage} from "../../src/interfaces/IOxionStorage.sol";

contract Deployers {
    using PoolIdLibrary for PoolKey;

    uint160 constant SQRT_RATIO_1_1 = Constants.SQRT_RATIO_1_1;
    uint160 constant SQRT_RATIO_1_2 = Constants.SQRT_RATIO_1_2;
    uint160 constant SQRT_RATIO_1_4 = Constants.SQRT_RATIO_1_4;
    uint160 constant SQRT_RATIO_4_1 = Constants.SQRT_RATIO_4_1;

    function deployCurrencies(uint256 totalSupply) internal returns (Currency currency0, Currency currency1) {
        MockERC20[] memory tokens = deployTokens(2, totalSupply);
        return SortTokens.sort(tokens[0], tokens[1]);
    }

    function deployTokens(uint8 count, uint256 totalSupply) internal returns (MockERC20[] memory tokens) {
        tokens = new MockERC20[](count);
        for (uint8 i = 0; i < count; i++) {
            tokens[i] = new MockERC20("TEST", "TEST", 18);
            tokens[i].mint(address(this), totalSupply);
        }
    }

    function createPool(IPoolManager manager, uint24 fee, uint160 sqrtPriceX96)
        private
        returns (PoolKey memory key, PoolId id)
    {
        MockERC20[] memory tokens = deployTokens(2, 2 ** 255);
        (Currency currency0, Currency currency1) = SortTokens.sort(tokens[0], tokens[1]);
        key = PoolKey(
            currency0,
            currency1,
            manager,
            fee
        );
        id = key.toId();
        manager.initialize(key, sqrtPriceX96);
    }

    function createFreshPool(uint24 fee, uint160 sqrtPriceX96)
        internal
        returns (IOxionStorage oxionStorage, IPoolManager manager, PoolKey memory key, PoolId id)
    {
        (oxionStorage, manager) = createFreshManager();
        (key, id) = createPool(manager, fee, sqrtPriceX96);
        return (oxionStorage, manager, key, id);
    }

    function createFreshManager() internal returns (OxionStorage oxionStorage, PoolManager manager) {
        oxionStorage = new OxionStorage();
        manager = new PoolManager(oxionStorage, 500000);
        oxionStorage.registerPoolManager(address(manager));
    }
}