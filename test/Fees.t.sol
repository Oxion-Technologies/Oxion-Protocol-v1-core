// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "solmate/test/utils/mocks/MockERC20.sol";
import "../src/test/MockFeePoolManager.sol";
import {
    MockProtocolFeeController,
    RevertingMockProtocolFeeController,
    OutOfBoundsMockProtocolFeeController,
    OverflowMockProtocolFeeController,
    InvalidReturnSizeMockProtocolFeeController
} from "../src/test/fee/MockProtocolFeeController.sol";
import "../src/test/MockOxionStorage.sol";
import "../src/Fees.sol";
import "../src/interfaces/IFees.sol";
import "../src/interfaces/IOxionStorage.sol";
import "../src/interfaces/IPoolManager.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "../src/interfaces/IPoolManager.sol";
import {IFees} from "../src/interfaces/IFees.sol";
import {IPoolManager} from "../src/interfaces/IPoolManager.sol";
import {PoolManager} from "../src/PoolManager.sol";
import {TickMath} from "../src/libraries/TickMath.sol";
import {Pool} from "../src/libraries/Pool.sol";
import {PoolIdLibrary} from "../src/types/PoolId.sol";
import {Deployers} from "./helpers/Deployers.sol";
import {TokenFixture} from "./helpers/TokenFixture.sol";
import {Currency, CurrencyLibrary} from "../src/types/Currency.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {PoolManagerRouter} from "./helpers/PoolManagerRouter.sol";
import {ProtocolFeeControllerTest} from "./helpers/ProtocolFeeControllerTest.sol";
import {IProtocolFeeController} from "../src/interfaces/IProtocolFeeController.sol";
import {Fees} from "../src/Fees.sol";
import {BalanceDelta} from "../src/types/BalanceDelta.sol";
import {PoolKey} from "../src/types/PoolKey.sol";
import {IOxionStorage} from "../src/interfaces/IOxionStorage.sol";
import {OxionStorage} from "../src/OxionStorage.sol";


contract FeesTest is Test, Deployers, TokenFixture, GasSnapshot {
    using Pool for Pool.State;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    MockFeePoolManager poolManager;
    MockProtocolFeeController feeController;
    RevertingMockProtocolFeeController revertingFeeController;
    OutOfBoundsMockProtocolFeeController outOfBoundsFeeController;
    OverflowMockProtocolFeeController overflowFeeController;
    InvalidReturnSizeMockProtocolFeeController invalidReturnSizeFeeController;

    MockOxionStorage oxionStorage;
    PoolKey key;
    Pool.State state;
    PoolManager manager;

    PoolManagerRouter router;
    ProtocolFeeControllerTest protocolFeeController;
    OxionStorage oxionStorageMain;

    bool _zeroForOne = true;
    bool _oneForZero = false;

    address alice = makeAddr("alice");
    MockERC20 token0;
    MockERC20 token1;

    event ProtocolFeeControllerUpdated(address protocolFeeController);

    function setUp() public {
        initializeTokens();
        oxionStorage = new MockOxionStorage();
        poolManager = new MockFeePoolManager(IOxionStorage(address(oxionStorage)), 500_000);
        feeController = new MockProtocolFeeController();
        revertingFeeController = new RevertingMockProtocolFeeController();
        outOfBoundsFeeController = new OutOfBoundsMockProtocolFeeController();
        overflowFeeController = new OverflowMockProtocolFeeController();
        invalidReturnSizeFeeController = new InvalidReturnSizeMockProtocolFeeController();

        (oxionStorageMain, manager) = Deployers.createFreshManager();
        router = new PoolManagerRouter(oxionStorageMain, manager);
        protocolFeeController = new ProtocolFeeControllerTest();

        token0 = new MockERC20("TestA", "A", 18);
        token1 = new MockERC20("TestB", "B", 18);

        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            poolManager: IPoolManager(address(poolManager)),
            fee: 0
        });

        MockERC20(Currency.unwrap(currency0)).approve(address(router), 10 ether);
        MockERC20(Currency.unwrap(currency1)).approve(address(router), 10 ether);

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            poolManager: manager,
            fee: uint24(3000)
        });

        manager.initialize(key, SQRT_RATIO_1_1);
    }

    function testSetProtocolFeeController() public {
        vm.expectEmit();
        emit ProtocolFeeControllerUpdated(address(feeController));

        poolManager.setProtocolFeeController(IProtocolFeeController(address(feeController)));
        assertEq(address(poolManager.protocolFeeController()), address(feeController));
    }

    function testSwap_NoProtocolFee() public {
        poolManager.initialize(key, new bytes(0));

        (uint256 protocolFee0, uint256 protocolFee1) = poolManager.swap(key, 1e18, 1e18);
        assertEq(protocolFee0, 0);
        assertEq(protocolFee1, 0);
    }

    function testInit_WhenFeeController_ProtocolFeeCannotBeFetched() public {
        MockFeePoolManager poolManagerWithLowControllerGasLimit =
            new MockFeePoolManager(IOxionStorage(address(oxionStorage)), 5000_000);
        PoolKey memory _key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            poolManager: IPoolManager(address(poolManagerWithLowControllerGasLimit)),
            fee: uint24(0)
        });
        poolManagerWithLowControllerGasLimit.setProtocolFeeController(feeController);

        vm.expectRevert(IFees.ProtocolFeeCannotBeFetched.selector);
        poolManagerWithLowControllerGasLimit.initialize{gas: 2000_000}(_key, new bytes(0));
    }

    function testInit_WhenFeeControllerRevert() public {
        poolManager.setProtocolFeeController(revertingFeeController);
        poolManager.initialize(key, new bytes(0));

        assertEq(poolManager.getProtocolFee(key), 0);
    }

    function testInit_WhenFeeControllerOutOfBound() public {
        poolManager.setProtocolFeeController(outOfBoundsFeeController);
        assertEq(address(poolManager.protocolFeeController()), address(outOfBoundsFeeController));
        poolManager.initialize(key, new bytes(0));

        assertEq(poolManager.getProtocolFee(key), 0);
    }

    function testInit_WhenFeeControllerOverflow() public {
        poolManager.setProtocolFeeController(overflowFeeController);
        assertEq(address(poolManager.protocolFeeController()), address(overflowFeeController));
        poolManager.initialize(key, new bytes(0));

        assertEq(poolManager.getProtocolFee(key), 0);
    }

    function testInit_WhenFeeControllerInvalidReturnSize() public {
        poolManager.setProtocolFeeController(invalidReturnSizeFeeController);
        assertEq(address(poolManager.protocolFeeController()), address(invalidReturnSizeFeeController));
        poolManager.initialize(key, new bytes(0));

        assertEq(poolManager.getProtocolFee(key), 0);
    }

    function testInitFuzz(uint16 fee) public {
        poolManager.setProtocolFeeController(feeController);

        vm.mockCall(
            address(feeController),
            abi.encodeWithSelector(IProtocolFeeController.protocolFeeForPool.selector, key),
            abi.encode(fee)
        );

        poolManager.initialize(key, new bytes(0));

        if (fee != 0) {
            uint16 fee0 = fee % 256;
            uint16 fee1 = fee >> 8;

            if (
                (fee0 != 0 && fee0 < poolManager.MIN_PROTOCOL_FEE_DENOMINATOR())
                    || (fee1 != 0 && fee1 < poolManager.MIN_PROTOCOL_FEE_DENOMINATOR())
            ) {
                // invalid fee, fallback to 0
                assertEq(poolManager.getProtocolFee(key), 0);
            } else {
                assertEq(poolManager.getProtocolFee(key), fee);
            }
        }
    }

    function testSwap_OnlyProtocolFee() public {
        // set protocolFee as 10% of fee
        uint16 protocolFee = _buildSwapFee(10, 10); // 10%
        feeController.setProtocolFeeForPool(key, protocolFee);
        poolManager.setProtocolFeeController(IProtocolFeeController(address(feeController)));

        poolManager.initialize(key, new bytes(0));
        (uint256 protocolFee0, uint256 protocolFee1) = poolManager.swap(key, 1e18, 1e18);
        assertEq(protocolFee0, 1e17);
        assertEq(protocolFee1, 1e17);
    }

    function test_CheckProtocolFee_SwapFee() public {
        uint16 protocolFee = _buildSwapFee(3, 3); // 25% is the limit, 3 = amt/3 = 33%
        feeController.setProtocolFeeForPool(key, protocolFee);
        poolManager.setProtocolFeeController(IProtocolFeeController(address(feeController)));

        // wont revert but set protocolFee as 0
        poolManager.initialize(key, new bytes(0));
        assertEq(poolManager.getProtocolFee(key), 0);
    }

    function test_CollectProtocolFee_OnlyOwnerOrFeeController() public {
        vm.expectRevert(IFees.InvalidProtocolFeeCollector.selector);

        vm.prank(address(alice));
        poolManager.collectProtocolFees(alice, Currency.wrap(address(token0)), 1e18);
    }

    function test_CollectProtocolFee() public {
        // set protocolFee as 10% of fee
        feeController.setProtocolFeeForPool(key, _buildSwapFee(10, 10));
        poolManager.setProtocolFeeController(IProtocolFeeController(address(feeController)));
        poolManager.initialize(key, new bytes(0));
        (uint256 protocolFee0, uint256 protocolFee1) = poolManager.swap(key, 1e18, 1e18);
        assertEq(protocolFee0, 1e17);
        assertEq(protocolFee1, 1e17);

        // send some token to vault as poolManager.swap doesn't have tokens
        token0.mint(address(oxionStorage), 1e17);
        token1.mint(address(oxionStorage), 1e17);

        // before collect
        assertEq(token0.balanceOf(alice), 0);
        assertEq(token1.balanceOf(alice), 0);
        assertEq(token0.balanceOf(address(oxionStorage)), 1e17);
        assertEq(token1.balanceOf(address(oxionStorage)), 1e17);

        // collect
        vm.prank(address(feeController));
        poolManager.collectProtocolFees(alice, Currency.wrap(address(token0)), 1e17);
        poolManager.collectProtocolFees(alice, Currency.wrap(address(token1)), 1e17);

        // after collect
        assertEq(token0.balanceOf(alice), 1e17);
        assertEq(token1.balanceOf(alice), 1e17);
        assertEq(token0.balanceOf(address(oxionStorage)), 0);
        assertEq(token1.balanceOf(address(oxionStorage)), 0);
    }

    function _buildSwapFee(uint16 fee0, uint16 fee1) public pure returns (uint16) {
        return fee0 + (fee1 << 8);
    }

    function testSetProtocolFeeControllerFuzz(uint16 protocolSwapFee) public {
        vm.assume(protocolSwapFee < 2 ** 16);

        (Pool.Slot0 memory slot0,,,) = manager.pools(key.toId());
        assertEq(slot0.protocolFee, 0);

        protocolFeeController.setSwapFeeForPool(key.toId(), protocolSwapFee);
        manager.setProtocolFeeController(IProtocolFeeController(protocolFeeController));

        uint16 protocolSwapFee0 = protocolSwapFee % 256;
        uint16 protocolSwapFee1 = protocolSwapFee >> 8;

        if ((protocolSwapFee1 != 0 && protocolSwapFee1 < 4) || (protocolSwapFee0 != 0 && protocolSwapFee0 < 4)) {
            vm.expectRevert(IFees.ProtocolFeeControllerCallFailedOrInvalidResult.selector);
            manager.setProtocolFee(key);
            return;
        }
        manager.setProtocolFee(key);

        (slot0,,,) = manager.pools(key.toId());

        assertEq(slot0.protocolFee, protocolSwapFee);
    }

    function testNoProtocolFee(uint16 protocolSwapFee) public {
        vm.assume(protocolSwapFee < 2 ** 16);
        vm.assume(protocolSwapFee >> 8 >= 4);
        vm.assume(protocolSwapFee % 256 >= 4);

        protocolFeeController.setSwapFeeForPool(key.toId(), protocolSwapFee);
        manager.setProtocolFeeController(IProtocolFeeController(protocolFeeController));
        manager.setProtocolFee(key);

        (Pool.Slot0 memory slot0,,,) = manager.pools(key.toId());
        assertEq(slot0.protocolFee, protocolSwapFee);

        int256 liquidityDelta = 10000;
        IPoolManager.ModifyLiquidityParams memory params =
            IPoolManager.ModifyLiquidityParams(-60, 60, liquidityDelta);
        router.modifyPosition(key, params);

        // Fees dont accrue for positive liquidity delta.
        assertEq(manager.protocolFeesAccrued(currency0), 0);
        assertEq(manager.protocolFeesAccrued(currency1), 0);

        IPoolManager.ModifyLiquidityParams memory params2 =
            IPoolManager.ModifyLiquidityParams(-60, 60, -liquidityDelta);
        router.modifyPosition(key, params2);

        uint16 protocolSwapFee1 = (protocolSwapFee >> 8);

        // No fees should accrue bc there is no hook so the protocol cant take withdraw fees.
        assertEq(manager.protocolFeesAccrued(currency0), 0);
        assertEq(manager.protocolFeesAccrued(currency1), 0);

        // add larger liquidity
        params = IPoolManager.ModifyLiquidityParams(-60, 60, 10e18);
        router.modifyPosition(key, params);

        MockERC20(Currency.unwrap(currency1)).approve(address(router), type(uint256).max);
        router.swap(
            key,
            IPoolManager.SwapParams(false, 10000, TickMath.MAX_SQRT_RATIO - 1),
            PoolManagerRouter.SwapTestSettings(true, true)
        );
        // key3 pool is 30 bps => 10000 * 0.003 (.3%) = 30
        uint256 expectedSwapFeeAccrued = 30;

        uint256 expectedProtocolAmount1 = protocolSwapFee1 == 0 ? 0 : expectedSwapFeeAccrued / protocolSwapFee1;
        assertEq(manager.protocolFeesAccrued(currency0), 0);
        assertEq(manager.protocolFeesAccrued(currency1), expectedProtocolAmount1);
    }

    function testCollectFees() public {
        uint16 protocolFee = _computeFee(_oneForZero, 10); // 10% on 1 to 0 swaps
        protocolFeeController.setSwapFeeForPool(key.toId(), protocolFee);
        manager.setProtocolFeeController(IProtocolFeeController(protocolFeeController));
        manager.setProtocolFee(key);

        (Pool.Slot0 memory slot0,,,) = manager.pools(key.toId());
        assertEq(slot0.protocolFee, protocolFee);

        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams(-120, 120, 10e18);
        router.modifyPosition(key, params);
        // 1 for 0 swap
        MockERC20(Currency.unwrap(currency1)).approve(address(router), type(uint256).max);
        router.swap(
            key,
            IPoolManager.SwapParams(false, 10000, TickMath.MAX_SQRT_RATIO - 1),
            PoolManagerRouter.SwapTestSettings(true, true)
        );

        uint256 expectedProtocolFees = 3; // 10% of 30 is 3
        vm.prank(address(protocolFeeController));
        manager.collectProtocolFees(address(protocolFeeController), currency1, 0);
        assertEq(currency1.balanceOf(address(protocolFeeController)), expectedProtocolFees);
    }

    // If zeroForOne is true, then value is set on the lower bits. If zeroForOne is false, then value is set on the higher bits.
    function _computeFee(bool zeroForOne, uint16 value) internal pure returns (uint16 fee) {
        if (zeroForOne) {
            fee = value % 256;
        } else {
            fee = value << 8;
        }
    }
}
