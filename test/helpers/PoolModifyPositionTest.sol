// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CurrencyLibrary, Currency} from "../../src/types/Currency.sol";
import {ILockCallback} from "../../src/interfaces/ILockCallback.sol";
import {IPoolManager} from "../../src/interfaces/IPoolManager.sol";
import {IOxionStorage} from "../../src/interfaces/IOxionStorage.sol";
import {BalanceDelta} from "../../src/types/BalanceDelta.sol";
import {PoolKey} from "../../src/types/PoolKey.sol";

contract PoolModifyPositionTest is ILockCallback {
    using CurrencyLibrary for Currency;

    IOxionStorage public immutable oxionStorage;
    IPoolManager public immutable manager;

    constructor(IOxionStorage _oxionStorage, IPoolManager _manager) {
        oxionStorage = _oxionStorage;
        manager = _manager;
    }

    struct CallbackData {
        address sender;
        PoolKey key;
        IPoolManager.ModifyLiquidityParams params;
    }

    function modifyPosition(
        PoolKey memory key,
        IPoolManager.ModifyLiquidityParams memory params
    ) external payable returns (BalanceDelta delta) {
        delta = abi.decode(oxionStorage.lock(abi.encode(CallbackData(msg.sender, key, params))), (BalanceDelta));

        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            CurrencyLibrary.NATIVE.transfer(msg.sender, ethBalance);
        }
    }

    function lockAcquired(bytes calldata rawData) external returns (bytes memory) {
        require(msg.sender == address(oxionStorage));

        CallbackData memory data = abi.decode(rawData, (CallbackData));

        BalanceDelta delta = manager.modifyLiquidity(data.key, data.params);

        if (delta.amount0() > 0) {
            if (data.key.currency0.isNative()) {
                oxionStorage.settle{value: uint128(delta.amount0())}(data.key.currency0);
            } else {
                IERC20(Currency.unwrap(data.key.currency0)).transferFrom(
                    data.sender, address(oxionStorage), uint128(delta.amount0())
                );
                oxionStorage.settle(data.key.currency0);
            }
        }
        if (delta.amount1() > 0) {
            if (data.key.currency1.isNative()) {
                oxionStorage.settle{value: uint128(delta.amount1())}(data.key.currency1);
            } else {
                IERC20(Currency.unwrap(data.key.currency1)).transferFrom(
                    data.sender, address(oxionStorage), uint128(delta.amount1())
                );
                oxionStorage.settle(data.key.currency1);
            }
        }

        if (delta.amount0() < 0) {
            oxionStorage.take(data.key.currency0, data.sender, uint128(-delta.amount0()));
        }
        if (delta.amount1() < 0) {
            oxionStorage.take(data.key.currency1, data.sender, uint128(-delta.amount1()));
        }

        return abi.encode(delta);
    }
}
