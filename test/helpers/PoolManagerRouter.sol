// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IOxionStorage} from "../../src/interfaces/IOxionStorage.sol";
import {PoolKey} from "../../src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "../../src/types/Currency.sol";
import {IPoolManager} from "../../src/interfaces/IPoolManager.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "../../src/types/BalanceDelta.sol";

contract PoolManagerRouter {
    error InvalidAction();

    using CurrencyLibrary for Currency;

    IOxionStorage public immutable oxionStorage;
    IPoolManager public immutable poolManager;

    constructor(IOxionStorage _oxionStorage, IPoolManager _poolManager) {
        oxionStorage = _oxionStorage;
        poolManager = _poolManager;
    }

    struct CallbackData {
        bytes action;
        bytes rawCallbackData;
    }

    struct ModifyPositionCallbackData {
        address sender;
        PoolKey key;
        IPoolManager.ModifyLiquidityParams params;
    }

    struct SwapTestSettings {
        bool withdrawTokens;
        bool settleUsingTransfer;
    }

    struct SwapCallbackData {
        address sender;
        SwapTestSettings testSettings;
        PoolKey key;
        IPoolManager.SwapParams params;
    }

    struct DonateCallbackData {
        address sender;
        PoolKey key;
        uint256 amount0;
        uint256 amount1;
    }

    struct TakeCallbackData {
        address sender;
        PoolKey key;
        uint256 amount0;
        uint256 amount1;
    }

    function modifyPosition(
        PoolKey memory key,
        IPoolManager.ModifyLiquidityParams memory params
    ) external payable returns (BalanceDelta delta) {
        delta = abi.decode(
            oxionStorage.lock(
                abi.encode("modifyPosition", abi.encode(ModifyPositionCallbackData(msg.sender, key, params)))
            ),
            (BalanceDelta)
        );

        // if any ethers left
        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            CurrencyLibrary.NATIVE.transfer(msg.sender, ethBalance);
        }
    }

    function modifyPositionCallback(bytes memory rawData) private returns (bytes memory) {
        ModifyPositionCallbackData memory data = abi.decode(rawData, (ModifyPositionCallbackData));

        BalanceDelta delta = poolManager.modifyLiquidity(data.key, data.params);

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

    function swap(
        PoolKey memory key,
        IPoolManager.SwapParams memory params,
        SwapTestSettings memory testSettings
    ) external payable returns (BalanceDelta delta) {
        delta = abi.decode(
            oxionStorage.lock(
                abi.encode("swap", abi.encode(SwapCallbackData(msg.sender, testSettings, key, params)))
            ),
            (BalanceDelta)
        );

        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) CurrencyLibrary.NATIVE.transfer(msg.sender, ethBalance);
    }

    function swapCallback(bytes memory rawData) private returns (bytes memory) {
        SwapCallbackData memory data = abi.decode(rawData, (SwapCallbackData));

        BalanceDelta delta = poolManager.swap(data.key, data.params);

        if (data.params.zeroForOne) {
            if (delta.amount0() > 0) {
                if (data.testSettings.settleUsingTransfer) {
                    if (data.key.currency0.isNative()) {
                        oxionStorage.settle{value: uint128(delta.amount0())}(data.key.currency0);
                    } else {
                        IERC20(Currency.unwrap(data.key.currency0)).transferFrom(
                            data.sender, address(oxionStorage), uint128(delta.amount0())
                        );
                        oxionStorage.settle(data.key.currency0);
                    }
                } else {
                    oxionStorage.transferFrom(data.sender, address(this), data.key.currency0, uint128(delta.amount0()));
                    oxionStorage.burn(data.key.currency0, uint128(delta.amount0()));
                }
            }
            if (delta.amount1() < 0) {
                if (data.testSettings.withdrawTokens) {
                    oxionStorage.take(data.key.currency1, data.sender, uint128(-delta.amount1()));
                } else {
                    oxionStorage.mint(data.key.currency1, data.sender, uint128(-delta.amount1()));
                }
            }
        } else {
            if (delta.amount1() > 0) {
                if (data.testSettings.settleUsingTransfer) {
                    if (data.key.currency1.isNative()) {
                        oxionStorage.settle{value: uint128(delta.amount1())}(data.key.currency1);
                    } else {
                        IERC20(Currency.unwrap(data.key.currency1)).transferFrom(
                            data.sender, address(oxionStorage), uint128(delta.amount1())
                        );
                        oxionStorage.settle(data.key.currency1);
                    }
                } else {
                    oxionStorage.transferFrom(data.sender, address(this), data.key.currency1, uint128(delta.amount1()));
                    oxionStorage.burn(data.key.currency1, uint128(delta.amount1()));
                }
            }
            if (delta.amount0() < 0) {
                if (data.testSettings.withdrawTokens) {
                    oxionStorage.take(data.key.currency0, data.sender, uint128(-delta.amount0()));
                } else {
                    oxionStorage.mint(data.key.currency0, data.sender, uint128(-delta.amount0()));
                }
            }
        }

        return abi.encode(delta);
    }

    function donate(PoolKey memory key, uint256 amount0, uint256 amount1)
        external
        payable
        returns (BalanceDelta delta)
    {
        delta = abi.decode(
            oxionStorage.lock(
                abi.encode("donate", abi.encode(DonateCallbackData(msg.sender, key, amount0, amount1)))
            ),
            (BalanceDelta)
        );

        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            CurrencyLibrary.NATIVE.transfer(msg.sender, ethBalance);
        }
    }

    function donateCallback(bytes memory rawData) private returns (bytes memory) {
        DonateCallbackData memory data = abi.decode(rawData, (DonateCallbackData));

        BalanceDelta delta = poolManager.donate(data.key, data.amount0, data.amount1);

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

        return abi.encode(delta);
    }

    function take(PoolKey memory key, uint256 amount0, uint256 amount1) external payable {
        oxionStorage.lock(abi.encode("take", abi.encode(TakeCallbackData(msg.sender, key, amount0, amount1))));
    }

    function takeCallback(bytes memory rawData) private returns (bytes memory) {
        TakeCallbackData memory data = abi.decode(rawData, (TakeCallbackData));

        if (data.amount0 > 0) {
            uint256 balBefore = data.key.currency0.balanceOf(data.sender);
            oxionStorage.take(data.key.currency0, data.sender, data.amount0);
            uint256 balAfter = data.key.currency0.balanceOf(data.sender);
            require(balAfter - balBefore == data.amount0);

            if (data.key.currency0.isNative()) {
                oxionStorage.settle{value: uint256(data.amount0)}(data.key.currency0);
            } else {
                IERC20(Currency.unwrap(data.key.currency0)).transferFrom(
                    data.sender, address(oxionStorage), uint256(data.amount0)
                );
                oxionStorage.settle(data.key.currency0);
            }
        }

        if (data.amount1 > 0) {
            uint256 balBefore = data.key.currency1.balanceOf(data.sender);
            oxionStorage.take(data.key.currency1, data.sender, data.amount1);
            uint256 balAfter = data.key.currency1.balanceOf(data.sender);
            require(balAfter - balBefore == data.amount1);

            if (data.key.currency1.isNative()) {
                oxionStorage.settle{value: uint256(data.amount1)}(data.key.currency1);
            } else {
                IERC20(Currency.unwrap(data.key.currency1)).transferFrom(
                    data.sender, address(oxionStorage), uint256(data.amount1)
                );
                oxionStorage.settle(data.key.currency1);
            }
        }

        return abi.encode(0);
    }

    function lockAcquired(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(oxionStorage));

        (bytes memory action, bytes memory rawCallbackData) = abi.decode(data, (bytes, bytes));
        if (keccak256(action) == keccak256("modifyPosition")) {
            return modifyPositionCallback(rawCallbackData);
        } else if (keccak256(action) == keccak256("swap")) {
            return swapCallback(rawCallbackData);
        } else if (keccak256(action) == keccak256("donate")) {
            return donateCallback(rawCallbackData);
        } else if (keccak256(action) == keccak256("take")) {
            return takeCallback(rawCallbackData);
        } else {
            revert InvalidAction();
        }
    }
}
