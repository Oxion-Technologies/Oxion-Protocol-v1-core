// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {PoolKey} from "../../src/types/PoolKey.sol";
import {IOxionStorage} from "../../src/interfaces/IOxionStorage.sol";
import {BalanceDelta, toBalanceDelta} from "../../src/types/BalanceDelta.sol";
import {IPoolManager} from "../../src/interfaces/IPoolManager.sol";
import {PoolId} from "../../src/types/PoolId.sol";
import {Position} from "../../src/libraries/Position.sol";
import {Currency} from "../../src/types/Currency.sol";
import {IProtocolFeeController} from "../../src/interfaces/IProtocolFeeController.sol";

contract FakePoolManager is IPoolManager {
    IOxionStorage public oxionStorage;

    constructor(IOxionStorage _oxionStorage) {
        oxionStorage = _oxionStorage;
    }

    function mockAccounting(PoolKey calldata poolKey, int128 delta0, int128 delta1) external {
        oxionStorage.accountPoolBalanceDelta(poolKey, toBalanceDelta(delta0, delta1), msg.sender);
    }

    function setProtocolFee(PoolKey memory key) external override {}

    function getSlot0(PoolId id)
        external
        view
        override
        returns (uint160 sqrtPriceX96, int24 tick, uint16 protocolFee, uint24 swapFee) {}

    function getLiquidity(PoolId id) external view override returns (uint128 liquidity) {}

    function getLiquidity(PoolId id, address owner, int24 tickLower, int24 tickUpper)
        external
        view
        override
        returns (uint128 liquidity) {}

    function getPosition(PoolId id, address owner, int24 tickLower, int24 tickUpper)
        external
        view
        override
        returns (Position.Info memory position) {}

    function initialize(PoolKey memory key, uint160 sqrtPriceX96)
        external
        override
        returns (int24 tick) {}

    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params)
        external
        override
        returns (BalanceDelta) {}

    function swap(PoolKey memory key, SwapParams memory params)
        external
        override
        returns (BalanceDelta) {}

    function donate(PoolKey memory key, uint256 amount0, uint256 amount1)
        external
        override
        returns (BalanceDelta) {}

    function MIN_PROTOCOL_FEE_DENOMINATOR() external view override returns (uint8) {}

    function protocolFeesAccrued(Currency) external view override returns (uint256) {}

    function setProtocolFeeController(IProtocolFeeController controller) external override {}

    function collectProtocolFees(address recipient, Currency currency, uint256 amount)
        external
        override
        returns (uint256 amountCollected) {}

    function extsload(bytes32 slot) external view override returns (bytes32 value) {}

    function extsload(bytes32[] memory slots) external view override returns (bytes32[] memory) {}
}
