// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {FakePoolManager} from "./FakePoolManager.sol";
import {IOxionStorage} from "../../src/interfaces/IOxionStorage.sol";
import {PoolKey} from "../../src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "../../src/types/Currency.sol";
import {IPoolManager} from "../../src/interfaces/IPoolManager.sol";
import {toBalanceDelta} from "../../src/types/BalanceDelta.sol";

contract FakePoolManagerRouter {
    using CurrencyLibrary for Currency;

    event LockAcquired();

    IOxionStorage oxionStorage;
    PoolKey poolKey;
    FakePoolManager poolManager;
    Forwarder forwarder;

    constructor(IOxionStorage _oxionStorage, PoolKey memory _poolKey) {
        oxionStorage = _oxionStorage;
        poolKey = _poolKey;
        poolManager = FakePoolManager(address(_poolKey.poolManager));
        forwarder = new Forwarder();
    }

    function lockAcquired(bytes calldata data) external returns (bytes memory) {
        emit LockAcquired();

        if (data[0] == 0x01) {
            poolManager.mockAccounting(poolKey, 10 ether, 10 ether);
        } else if (data[0] == 0x02) {
            poolManager.mockAccounting(poolKey, 10 ether, 10 ether);
            oxionStorage.settle(poolKey.currency0);
            oxionStorage.settle(poolKey.currency1);
        } else if (data[0] == 0x03) {
            poolManager.mockAccounting(poolKey, 3 ether, -3 ether);
            oxionStorage.settle(poolKey.currency0);
            oxionStorage.take(poolKey.currency1, address(this), 3 ether);
        } else if (data[0] == 0x04) {
            poolManager.mockAccounting(poolKey, 15 ether, -15 ether);
            oxionStorage.settle(poolKey.currency0);
            oxionStorage.take(poolKey.currency1, address(this), 15 ether);
        } else if (data[0] == 0x05) {
            oxionStorage.take(poolKey.currency0, address(this), 20 ether);
            oxionStorage.take(poolKey.currency1, address(this), 20 ether);

            // ... flashloan logic

            poolKey.currency0.transfer(address(oxionStorage), 20 ether);
            poolKey.currency1.transfer(address(oxionStorage), 20 ether);
            oxionStorage.settle(poolKey.currency0);
            oxionStorage.settle(poolKey.currency1);
        } else if (data[0] == 0x06) {
            // poolKey.poolManager was hacked hence not equal to msg.sender
            PoolKey memory maliciousPoolKey = poolKey;
            maliciousPoolKey.poolManager = IPoolManager(address(0));
            poolManager.mockAccounting(maliciousPoolKey, 3 ether, -3 ether);
        } else if (data[0] == 0x07) {
            // generate nested lock call
            oxionStorage.take(poolKey.currency0, address(this), 5 ether);
            oxionStorage.take(poolKey.currency1, address(this), 5 ether);

            forwarder.forward(oxionStorage);
        } else if (data[0] == 0x08) {
            // settle generated balance delta by 0x07
            poolKey.currency0.transfer(address(oxionStorage), 5 ether);
            poolKey.currency1.transfer(address(oxionStorage), 5 ether);
            oxionStorage.settle(poolKey.currency0);
            oxionStorage.settle(poolKey.currency1);
        } else if (data[0] == 0x09) {
            oxionStorage.take(poolKey.currency1, address(this), 5 ether);
        } else if (data[0] == 0x10) {
            // call accountPoolBalanceDelta from arbitrary addr
            oxionStorage.accountPoolBalanceDelta(poolKey, toBalanceDelta(int128(1), int128(0)), address(0));
        } else if (data[0] == 0x11) {
            // settleFor
            Payer payer = new Payer();
            payer.settleFor(oxionStorage, poolKey, 5 ether);

            poolKey.currency0.transfer(address(oxionStorage), 5 ether);
            payer.settle(oxionStorage, poolKey);

            oxionStorage.take(poolKey.currency0, address(this), 5 ether);
        } else if (data[0] == 0x12) {
            // settleFor(, , 0)
            Payer payer = new Payer();

            uint256 amt = poolKey.currency0.balanceOfSelf();
            poolKey.currency0.transfer(address(oxionStorage), amt);
            payer.settle(oxionStorage, poolKey);

            oxionStorage.take(poolKey.currency0, address(this), amt);

            payer.settleFor(oxionStorage, poolKey, 0);
        } else if (data[0] == 0x13) {
            // mint
            uint256 amt = poolKey.currency0.balanceOf(address(oxionStorage));
            oxionStorage.settle(poolKey.currency0);
            oxionStorage.mint(poolKey.currency0, address(this), amt);
        } else if (data[0] == 0x14) {
            // mint to someone else, poolKey.currency1 for example
            uint256 amt = poolKey.currency0.balanceOf(address(oxionStorage));
            oxionStorage.settle(poolKey.currency0);
            oxionStorage.mint(poolKey.currency0, Currency.unwrap(poolKey.currency1), amt);
        } else if (data[0] == 0x15) {
            // burn

            uint256 amt = poolKey.currency0.balanceOf(address(oxionStorage));
            oxionStorage.settle(poolKey.currency0);
            oxionStorage.mint(poolKey.currency0, address(this), amt);

            oxionStorage.burn(poolKey.currency0, amt);
            oxionStorage.take(poolKey.currency0, address(this), amt);
        } else if (data[0] == 0x16) {
            // burn half if possible

            uint256 amt = poolKey.currency0.balanceOf(address(oxionStorage));
            oxionStorage.settle(poolKey.currency0);

            oxionStorage.mint(poolKey.currency0, address(this), amt);

            oxionStorage.burn(poolKey.currency0, amt / 2);
            oxionStorage.take(poolKey.currency0, address(this), amt / 2);
        } else if (data[0] == 0x17) {
            // settle ETH
            oxionStorage.settle{value: 5 ether}(CurrencyLibrary.NATIVE);
            oxionStorage.take(CurrencyLibrary.NATIVE, address(this), 5 ether);
        } else if (data[0] == 0x18) {
            // call this method via oxionStorage.lock(abi.encodePacked(hex"18", alice));
            address to = address(uint160(uint256(bytes32(data[1:0x15]) >> 96)));
            oxionStorage.settleAndMintRefund(poolKey.currency0, to);
            oxionStorage.settleAndMintRefund(poolKey.currency1, to);
        } else if (data[0] == 0x19) {
            poolManager.mockAccounting(poolKey, 3 ether, -3 ether);
            oxionStorage.settle(poolKey.currency0);

            /// try to call settleAndMintRefund should not revert
            oxionStorage.settleAndMintRefund(poolKey.currency1, address(this));
            oxionStorage.take(poolKey.currency1, address(this), 3 ether);
        }

        return "";
    }

    function callback() external {
        oxionStorage.lock(hex"08");
    }

    receive() external payable {}
}

contract Forwarder {
    function forward(IOxionStorage oxionStorage) external {
        oxionStorage.lock(abi.encode(msg.sender));
    }

    function lockAcquired(bytes calldata data) external returns (bytes memory) {
        address lastLocker = abi.decode(data, (address));
        FakePoolManagerRouter(payable(lastLocker)).callback();
        return "";
    }
}

contract Payer {
    function settleFor(IOxionStorage oxionStorage, PoolKey calldata poolKey, uint256 amt) public {
        oxionStorage.settleFor(poolKey.currency0, msg.sender, amt);
    }

    function settle(IOxionStorage oxionStorage, PoolKey calldata poolKey) public {
        oxionStorage.settle(poolKey.currency0);
    }
}
