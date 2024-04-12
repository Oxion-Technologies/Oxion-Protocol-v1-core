// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {OxionStorage} from "../../src/OxionStorage.sol";
import {BalanceDelta, toBalanceDelta} from "../../src/types/BalanceDelta.sol";
import {ERC20PresetFixedSupply} from "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetFixedSupply.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "../../src/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "../../src/types/Currency.sol";
import {PoolKey} from "../../src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "../../src/types/PoolId.sol";
import {IOxionStorage} from "../../src/interfaces/IOxionStorage.sol";
import {FakePoolManagerRouter} from "./FakePoolManagerRouter.sol";
import {FakePoolManager} from "./FakePoolManager.sol";

/**
 * @notice Basic functionality test for OxionStorage
 * More tests in terms of security and edge cases will be covered by OxionStorageReentracy.t.sol & OxionStorageInvariant.t.sol
 */
contract OxionStorageTest is Test, GasSnapshot {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    event PoolManagerRegistered(address indexed poolManager);
    event LockAcquired();

    OxionStorage public oxionStorage;
    IPoolManager public unRegPoolManager;
    FakePoolManager public fakePoolManager;
    FakePoolManager public fakePoolManager2;
    FakePoolManagerRouter public fakePoolManagerRouter;
    FakePoolManagerRouter public fakePoolManagerRouter2;

    Currency public currency0;
    Currency public currency1;

    PoolKey public poolKey;
    PoolKey public poolKey2;

    function setUp() public {
        oxionStorage = new OxionStorage();
        snapSize("OxionStorageTest#OxionStorage", address(oxionStorage));

        unRegPoolManager = new FakePoolManager(oxionStorage);

        fakePoolManager = new FakePoolManager(oxionStorage);
        fakePoolManager2 = new FakePoolManager(oxionStorage);
        oxionStorage.registerPoolManager(address(fakePoolManager));
        oxionStorage.registerPoolManager(address(fakePoolManager2));

        currency0 = Currency.wrap(address(new ERC20PresetFixedSupply("C0", "C0", 100 ether, address(this))));
        currency1 = Currency.wrap(address(new ERC20PresetFixedSupply("C1", "C1", 100 ether, address(this))));

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            poolManager: fakePoolManager,
            fee: 0
        });

        poolKey = key;
        fakePoolManagerRouter = new FakePoolManagerRouter(oxionStorage, key);

        PoolKey memory key2 = PoolKey({
            currency0: currency0,
            currency1: currency1,
            poolManager: fakePoolManager2,
            fee: 1
        });

        poolKey2 = key2;
        fakePoolManagerRouter2 = new FakePoolManagerRouter(oxionStorage, key2);
    }

    function testRegisterPoolManager() public {
        assertEq(oxionStorage.isPoolManagerRegistered(address(unRegPoolManager)), false);
        assertEq(oxionStorage.isPoolManagerRegistered(address(fakePoolManager)), true);

        vm.expectEmit();
        emit PoolManagerRegistered(address(unRegPoolManager));
        snapStart("OxionStorageTest#registerPoolManager");
        oxionStorage.registerPoolManager(address(unRegPoolManager));
        snapEnd();

        assertEq(oxionStorage.isPoolManagerRegistered(address(unRegPoolManager)), true);
        assertEq(oxionStorage.isPoolManagerRegistered(address(fakePoolManager)), true);
    }

    function testAccountPoolBalanceDeltaFromUnregistedPoolManager() public {
        PoolKey memory key = PoolKey(currency0, currency1, unRegPoolManager, 0x0);
        FakePoolManagerRouter unRegPoolManagerRouter = new FakePoolManagerRouter(oxionStorage, key);
        vm.expectRevert(IOxionStorage.PoolManagerUnregistered.selector);
        vm.prank(address(unRegPoolManagerRouter));
        oxionStorage.lock(hex"01");
    }

    function testAccountPoolBalanceDeltaFromArbitraryAddr() public {
        vm.expectRevert(IOxionStorage.NotFromPoolManager.selector);
        vm.prank(address(fakePoolManagerRouter));
        oxionStorage.lock(hex"10");
    }

    function testAccountPoolBalanceDeltaWithoutLock() public {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            poolManager: fakePoolManager,
            fee: uint24(3000)
        });

        BalanceDelta delta = toBalanceDelta(0x7, 0x8);

        vm.expectRevert(abi.encodeWithSelector(IOxionStorage.NoLocker.selector));
        vm.prank(address(fakePoolManager));
        oxionStorage.accountPoolBalanceDelta(key, delta, address(this));
    }

    function testLockNotSettled() public {
        // router => oxionStorage.lock
        // oxionStorage.lock => periphery.lockAcquired
        // periphery.lockAcquired => FakePoolManager.XXX => oxionStorage.accountPoolBalanceDelta

        vm.expectRevert(IOxionStorage.CurrencyNotSettled.selector);
        vm.prank(address(fakePoolManagerRouter));
        oxionStorage.lock(hex"01");
    }

    function testLockNotSettled2() public {
        // router => oxionStorage.lock
        // oxionStorage.lock => periphery.lockAcquired
        // periphery.lockAcquired => FakePoolManager.XXX => oxionStorage.accountPoolBalanceDelta

        currency0.transfer(address(oxionStorage), 10 ether);

        vm.expectRevert(IOxionStorage.CurrencyNotSettled.selector);
        vm.prank(address(fakePoolManagerRouter));
        oxionStorage.lock(hex"02");
    }

    function testLockNotSettled3() public {
        // router => oxionStorage.lock
        // oxionStorage.lock => periphery.lockAcquired
        // periphery.lockAcquired => FakePoolManager.XXX => oxionStorage.accountPoolBalanceDelta

        currency0.transfer(address(oxionStorage), 10 ether);
        currency1.transfer(address(oxionStorage), 8 ether);

        vm.expectRevert(IOxionStorage.CurrencyNotSettled.selector);
        vm.prank(address(fakePoolManagerRouter));
        oxionStorage.lock(hex"02");
    }

    function testLockNotSettled4() public {
        // router => oxionStorage.lock
        // oxionStorage.lock => periphery.lockAcquired
        // periphery.lockAcquired => FakePoolManager.XXX => oxionStorage.accountPoolBalanceDelta

        currency0.transfer(address(oxionStorage), 10 ether);
        currency1.transfer(address(oxionStorage), 12 ether);

        vm.expectRevert(IOxionStorage.CurrencyNotSettled.selector);
        vm.prank(address(fakePoolManagerRouter));
        oxionStorage.lock(hex"02");
    }

    function testSettleAndMintRefund_WithMint() public {
        address alice = makeAddr("alice");

        // simulate someone transferred token to oxionStorage
        currency0.transfer(address(oxionStorage), 10 ether);
        assertEq(oxionStorage.balanceOf(alice, currency0), 0 ether);

        // settle and refund
        vm.prank(address(fakePoolManagerRouter));
        snapStart("OxionStorageTest#testSettleAndMintRefund_WithMint");
        oxionStorage.lock(abi.encodePacked(hex"18", alice));
        snapEnd();

        // verify excess currency minted to alice
        assertEq(oxionStorage.balanceOf(alice, currency0), 10 ether);
    }

    function testSettleAndMintRefund_WithoutMint() public {
        address alice = makeAddr("alice");

        assertEq(oxionStorage.balanceOf(alice, currency0), 0 ether);

        // settleAndRefund works even if there's no excess currency
        vm.prank(address(fakePoolManagerRouter));
        snapStart("OxionStorageTest#testSettleAndMintRefund_WithoutMint");
        oxionStorage.lock(abi.encodePacked(hex"18", alice));
        snapEnd();

        // verify no extra token minted
        assertEq(oxionStorage.balanceOf(alice, currency0), 0 ether);
    }

    function testSettleAndMintRefund_NegativeBalanceDelta() public {
        // pre-req: ensure oxionStorage has some value in reserveOfVault[] before
        currency0.transfer(address(oxionStorage), 10 ether);
        currency1.transfer(address(oxionStorage), 10 ether);
        vm.prank(address(fakePoolManagerRouter));
        oxionStorage.lock(hex"02");

        // settleAndRefund should not revert even if negative balanceDelta
        currency0.transfer(address(oxionStorage), 3 ether);
        vm.prank(address(fakePoolManagerRouter));
        oxionStorage.lock(hex"19");
    }

    function testNotCorrectPoolManager() public {
        // router => oxionStorage.lock
        // oxionStorage.lock => periphery.lockAcquired
        // periphery.lockAcquired => FakePoolManager.XXX => oxionStorage.accountPoolBalanceDelta

        vm.expectRevert(IOxionStorage.NotFromPoolManager.selector);
        vm.prank(address(fakePoolManagerRouter));
        oxionStorage.lock(hex"06");
    }

    function testLockSettledWhenAddLiquidity() public {
        // router => oxionStorage.lock
        // oxionStorage.lock => periphery.lockAcquired
        // periphery.lockAcquired => FakePoolManager.XXX => oxionStorage.accountPoolBalanceDelta

        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(address(oxionStorage)), 0 ether);
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(address(oxionStorage)), 0 ether);
        assertEq(oxionStorage.reservesOfStorage(currency0), 0 ether);
        assertEq(oxionStorage.reservesOfStorage(currency1), 0 ether);
        assertEq(oxionStorage.reservesOfPoolManager(poolKey.poolManager, currency0), 0 ether);
        assertEq(oxionStorage.reservesOfPoolManager(poolKey.poolManager, currency1), 0 ether);

        currency0.transfer(address(oxionStorage), 10 ether);
        currency1.transfer(address(oxionStorage), 10 ether);

        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(address(oxionStorage)), 10 ether);
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(address(oxionStorage)), 10 ether);
        assertEq(oxionStorage.reservesOfStorage(currency0), 0 ether);
        assertEq(oxionStorage.reservesOfStorage(currency1), 0 ether);
        assertEq(oxionStorage.reservesOfPoolManager(poolKey.poolManager, currency0), 0 ether);
        assertEq(oxionStorage.reservesOfPoolManager(poolKey.poolManager, currency1), 0 ether);

        vm.prank(address(fakePoolManagerRouter));
        snapStart("OxionStorageTest#lockSettledWhenAddLiquidity");
        oxionStorage.lock(hex"02");
        snapEnd();

        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(address(oxionStorage)), 10 ether);
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(address(oxionStorage)), 10 ether);
        assertEq(oxionStorage.reservesOfStorage(currency0), 10 ether);
        assertEq(oxionStorage.reservesOfStorage(currency1), 10 ether);
        assertEq(oxionStorage.reservesOfPoolManager(poolKey.poolManager, currency0), 10 ether);
        assertEq(oxionStorage.reservesOfPoolManager(poolKey.poolManager, currency1), 10 ether);
    }

    function testLockSettledWhenSwap() public {
        // router => oxionStorage.lock
        // oxionStorage.lock => periphery.lockAcquired
        // periphery.lockAcquired => FakePoolManager.XXX => oxionStorage.accountPoolBalanceDelta

        currency0.transfer(address(oxionStorage), 10 ether);
        currency1.transfer(address(oxionStorage), 10 ether);

        vm.prank(address(fakePoolManagerRouter));
        oxionStorage.lock(hex"02");

        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(address(oxionStorage)), 10 ether);
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(address(oxionStorage)), 10 ether);
        assertEq(oxionStorage.reservesOfStorage(currency0), 10 ether);
        assertEq(oxionStorage.reservesOfStorage(currency1), 10 ether);
        assertEq(oxionStorage.reservesOfPoolManager(poolKey.poolManager, currency0), 10 ether);
        assertEq(oxionStorage.reservesOfPoolManager(poolKey.poolManager, currency1), 10 ether);

        currency0.transfer(address(oxionStorage), 3 ether);
        vm.prank(address(fakePoolManagerRouter));
        snapStart("OxionStorageTest#lockSettledWhenSwap");
        oxionStorage.lock(hex"03");
        snapEnd();

        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(address(oxionStorage)), 13 ether);
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(address(oxionStorage)), 7 ether);
        assertEq(oxionStorage.reservesOfStorage(currency0), 13 ether);
        assertEq(oxionStorage.reservesOfStorage(currency1), 7 ether);
        assertEq(oxionStorage.reservesOfPoolManager(poolKey.poolManager, currency0), 13 ether);
        assertEq(oxionStorage.reservesOfPoolManager(poolKey.poolManager, currency1), 7 ether);

        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(address(fakePoolManagerRouter)), 3 ether);
    }

    function testLockWhenAlreadyLocked() public {
        // deposit enough token in
        currency0.transfer(address(oxionStorage), 10 ether);
        currency1.transfer(address(oxionStorage), 10 ether);
        vm.prank(address(fakePoolManagerRouter));
        oxionStorage.lock(hex"02");

        vm.expectRevert(abi.encodeWithSelector(IOxionStorage.LockerAlreadySet.selector, address(fakePoolManagerRouter)));

        vm.prank(address(fakePoolManagerRouter));
        oxionStorage.lock(hex"07");
    }

    function testLockWhenMoreThanOnePoolManagers() public {
        // router => oxionStorage.lock
        // oxionStorage.lock => periphery.lockAcquired
        // periphery.lockAcquired => FakePoolManager.XXX => oxionStorage.accountPoolBalanceDelta

        currency0.transfer(address(oxionStorage), 10 ether);
        currency1.transfer(address(oxionStorage), 10 ether);
        vm.prank(address(fakePoolManagerRouter));
        oxionStorage.lock(hex"02");

        currency0.transfer(address(oxionStorage), 10 ether);
        currency1.transfer(address(oxionStorage), 10 ether);
        vm.prank(address(fakePoolManagerRouter2));
        oxionStorage.lock(hex"02");

        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(address(oxionStorage)), 20 ether);
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(address(oxionStorage)), 20 ether);
        assertEq(oxionStorage.reservesOfStorage(currency0), 20 ether);
        assertEq(oxionStorage.reservesOfStorage(currency1), 20 ether);
        assertEq(oxionStorage.reservesOfPoolManager(poolKey.poolManager, currency0), 10 ether);
        assertEq(oxionStorage.reservesOfPoolManager(poolKey.poolManager, currency1), 10 ether);
        assertEq(oxionStorage.reservesOfPoolManager(poolKey2.poolManager, currency0), 10 ether);
        assertEq(oxionStorage.reservesOfPoolManager(poolKey2.poolManager, currency1), 10 ether);

        currency0.transfer(address(oxionStorage), 3 ether);
        vm.prank(address(fakePoolManagerRouter));
        snapStart("OxionStorageTest#lockSettledWhenMultiHopSwap");
        oxionStorage.lock(hex"03");
        snapEnd();

        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(address(oxionStorage)), 23 ether);
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(address(oxionStorage)), 17 ether);
        assertEq(oxionStorage.reservesOfStorage(currency0), 23 ether);
        assertEq(oxionStorage.reservesOfStorage(currency1), 17 ether);
        assertEq(oxionStorage.reservesOfPoolManager(poolKey.poolManager, currency0), 13 ether);
        assertEq(oxionStorage.reservesOfPoolManager(poolKey.poolManager, currency1), 7 ether);
        assertEq(oxionStorage.reservesOfPoolManager(poolKey2.poolManager, currency0), 10 ether);
        assertEq(oxionStorage.reservesOfPoolManager(poolKey2.poolManager, currency1), 10 ether);

        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(address(fakePoolManagerRouter)), 3 ether);
    }

    function testVault_settleFor() public {
        // make sure router has enough tokens
        currency0.transfer(address(fakePoolManagerRouter), 10 ether);

        vm.prank(address(fakePoolManagerRouter));
        oxionStorage.lock(hex"11");
    }

    function testVaultFuzz_settleFor_arbitraryAmt(uint256 amt) public {
        amt = bound(amt, 0, 10 ether);
        // make sure router has enough tokens
        currency0.transfer(address(fakePoolManagerRouter), amt);

        vm.prank(address(fakePoolManagerRouter));
        oxionStorage.lock(hex"12");
    }

    function testVaultFuzz_mint(uint256 amt) public {
        amt = bound(amt, 0, 10 ether);
        // make sure router has enough tokens
        currency0.transfer(address(oxionStorage), amt);

        vm.prank(address(fakePoolManagerRouter));
        oxionStorage.lock(hex"13");

        assertEq(oxionStorage.balanceOf(address(fakePoolManagerRouter), currency0), amt);
    }

    function testVaultFuzz_mint_toSomeoneElse(uint256 amt) public {
        amt = bound(amt, 0, 10 ether);
        // make sure router has enough tokens
        currency0.transfer(address(oxionStorage), amt);

        vm.prank(address(fakePoolManagerRouter));
        oxionStorage.lock(hex"14");

        assertEq(oxionStorage.balanceOf(Currency.unwrap(poolKey.currency1), currency0), amt);
    }

    function testVaultFuzz_burn(uint256 amt) public {
        amt = bound(amt, 0, 10 ether);
        // make sure router has enough tokens
        currency0.transfer(address(oxionStorage), amt);

        vm.prank(address(fakePoolManagerRouter));
        oxionStorage.lock(hex"15");

        assertEq(oxionStorage.balanceOf(address(fakePoolManagerRouter), currency0), 0);
    }

    function testVaultFuzz_burnHalf(uint256 amt) public {
        amt = bound(amt, 0, 10 ether);
        // make sure router has enough tokens
        currency0.transfer(address(oxionStorage), amt);

        vm.prank(address(fakePoolManagerRouter));
        oxionStorage.lock(hex"16");

        assertEq(oxionStorage.balanceOf(address(fakePoolManagerRouter), currency0), amt - amt / 2);
    }

    function testLockInSufficientBalanceWhenMoreThanOnePoolManagers() public {
        // router => oxionStorage.lock
        // oxionStorage.lock => periphery.lockAcquired
        // periphery.lockAcquired => FakePoolManager.XXX => oxionStorage.accountPoolBalanceDelta

        currency0.transfer(address(oxionStorage), 10 ether);
        currency1.transfer(address(oxionStorage), 10 ether);
        vm.prank(address(fakePoolManagerRouter));
        oxionStorage.lock(hex"02");

        currency0.transfer(address(oxionStorage), 10 ether);
        currency1.transfer(address(oxionStorage), 10 ether);
        vm.prank(address(fakePoolManagerRouter2));
        oxionStorage.lock(hex"02");

        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(address(oxionStorage)), 20 ether);
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(address(oxionStorage)), 20 ether);
        assertEq(oxionStorage.reservesOfStorage(currency0), 20 ether);
        assertEq(oxionStorage.reservesOfStorage(currency1), 20 ether);
        assertEq(oxionStorage.reservesOfPoolManager(poolKey.poolManager, currency0), 10 ether);
        assertEq(oxionStorage.reservesOfPoolManager(poolKey.poolManager, currency1), 10 ether);
        assertEq(oxionStorage.reservesOfPoolManager(poolKey2.poolManager, currency0), 10 ether);
        assertEq(oxionStorage.reservesOfPoolManager(poolKey2.poolManager, currency1), 10 ether);

        assertEq(currency0.balanceOfSelf(), 80 ether);
        currency0.transfer(address(oxionStorage), 15 ether);

        vm.expectRevert(stdError.arithmeticError);
        vm.prank(address(fakePoolManagerRouter));
        oxionStorage.lock(hex"04");
    }

    function testLockFlashloanCrossMoreThanOnePoolManagers() public {
        // router => oxionStorage.lock
        // oxionStorage.lock => periphery.lockAcquired
        // periphery.lockAcquired => FakePoolManager.XXX => oxionStorage.accountPoolBalanceDelta

        currency0.transfer(address(oxionStorage), 10 ether);
        currency1.transfer(address(oxionStorage), 10 ether);
        vm.prank(address(fakePoolManagerRouter));
        oxionStorage.lock(hex"02");

        currency0.transfer(address(oxionStorage), 10 ether);
        currency1.transfer(address(oxionStorage), 10 ether);
        vm.prank(address(fakePoolManagerRouter2));
        oxionStorage.lock(hex"02");

        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(address(oxionStorage)), 20 ether);
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(address(oxionStorage)), 20 ether);
        assertEq(oxionStorage.reservesOfStorage(currency0), 20 ether);
        assertEq(oxionStorage.reservesOfStorage(currency1), 20 ether);
        assertEq(oxionStorage.reservesOfPoolManager(poolKey.poolManager, currency0), 10 ether);
        assertEq(oxionStorage.reservesOfPoolManager(poolKey.poolManager, currency1), 10 ether);
        assertEq(oxionStorage.reservesOfPoolManager(poolKey2.poolManager, currency0), 10 ether);
        assertEq(oxionStorage.reservesOfPoolManager(poolKey2.poolManager, currency1), 10 ether);

        vm.prank(address(fakePoolManagerRouter));
        snapStart("OxionStorageTest#lockSettledWhenFlashloan");
        oxionStorage.lock(hex"05");
        snapEnd();
    }

    function test_CollectFee() public {
        currency0.transfer(address(oxionStorage), 10 ether);
        currency1.transfer(address(oxionStorage), 10 ether);
        vm.prank(address(fakePoolManagerRouter));
        oxionStorage.lock(hex"02");

        // before collectFee assert
        assertEq(oxionStorage.reservesOfStorage(currency0), 10 ether);
        assertEq(oxionStorage.reservesOfPoolManager(poolKey.poolManager, currency0), 10 ether);
        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(address(fakePoolManager)), 0 ether);

        // collectFee
        vm.prank(address(fakePoolManager));
        snapStart("OxionStorageTest#collectFee");
        oxionStorage.collectFee(currency0, 10 ether, address(fakePoolManager));
        snapEnd();

        // after collectFee assert
        assertEq(oxionStorage.reservesOfStorage(currency0), 0 ether);
        assertEq(oxionStorage.reservesOfPoolManager(poolKey.poolManager, currency0), 0 ether);
        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(address(fakePoolManager)), 10 ether);
    }

    function test_CollectFeeFromRandomUser() public {
        currency0.transfer(address(oxionStorage), 10 ether);

        address bob = makeAddr("bob");
        vm.startPrank(bob);

        // expected underflow as reserves are 0 currently
        vm.expectRevert(stdError.arithmeticError);
        oxionStorage.collectFee(currency0, 10 ether, bob);
    }

    function testTake_failsWithNoLiquidity() public {
        vm.expectRevert();
        vm.prank(address(fakePoolManagerRouter));
        oxionStorage.lock(hex"09");
    }

    function testLock_NoOpIsOk() public {
        vm.prank(address(fakePoolManagerRouter));
        snapStart("OxionStorageTest#testLock_NoOp");
        oxionStorage.lock(hex"00");
        snapEnd();
    }

    function testLock_EmitsCorrectId() public {
        vm.expectEmit(false, false, false, true);
        emit LockAcquired();
        vm.prank(address(fakePoolManagerRouter));
        oxionStorage.lock(hex"00");
    }

    function testVault_ethSupport_transferInAndSettle() public {
        FakePoolManagerRouter router = new FakePoolManagerRouter(
            oxionStorage,
            PoolKey({
                currency0: CurrencyLibrary.NATIVE,
                currency1: currency1,
                poolManager: fakePoolManager,
                fee: 0
            })
        );

        // transfer in & settle
        {
            CurrencyLibrary.NATIVE.transfer(address(oxionStorage), 10 ether);
            currency1.transfer(address(oxionStorage), 10 ether);

            vm.prank(address(router));
            oxionStorage.lock(hex"02");

            assertEq(CurrencyLibrary.NATIVE.balanceOf(address(oxionStorage)), 10 ether);
            assertEq(oxionStorage.reservesOfStorage(CurrencyLibrary.NATIVE), 10 ether);
            assertEq(oxionStorage.reservesOfPoolManager(fakePoolManager, CurrencyLibrary.NATIVE), 10 ether);
        }
    }

    function testVault_ethSupport_settleAndTake() public {
        FakePoolManagerRouter router = new FakePoolManagerRouter(
            oxionStorage,
            PoolKey({
                currency0: CurrencyLibrary.NATIVE,
                currency1: currency1,
                poolManager: fakePoolManager,
                fee: 0
            })
        );

        CurrencyLibrary.NATIVE.transfer(address(router), 5 ether);

        // take and settle
        {
            vm.prank(address(router));
            oxionStorage.lock(hex"17");

            assertEq(CurrencyLibrary.NATIVE.balanceOf(address(oxionStorage)), 0);
            assertEq(oxionStorage.reservesOfStorage(CurrencyLibrary.NATIVE), 0);
            assertEq(oxionStorage.reservesOfPoolManager(fakePoolManager, CurrencyLibrary.NATIVE), 0);
        }
    }

    function testVault_ethSupport_flashloan() public {
        FakePoolManagerRouter router = new FakePoolManagerRouter(
            oxionStorage,
            PoolKey({
                currency0: CurrencyLibrary.NATIVE,
                currency1: currency1,
                poolManager: fakePoolManager,
                fee: 0
            })
        );

        // make sure oxionStorage has enough tokens
        CurrencyLibrary.NATIVE.transfer(address(oxionStorage), 10 ether);
        currency1.transfer(address(oxionStorage), 10 ether);
        vm.prank(address(router));
        oxionStorage.lock(hex"02");

        CurrencyLibrary.NATIVE.transfer(address(oxionStorage), 10 ether);
        currency1.transfer(address(oxionStorage), 10 ether);
        vm.prank(address(router));
        oxionStorage.lock(hex"02");

        // take and settle
        {
            vm.prank(address(router));
            oxionStorage.lock(hex"05");
        }
    }
}
