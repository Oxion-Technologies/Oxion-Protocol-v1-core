// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {FeeLibrary} from "../src/libraries/FeeLibrary.sol";
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

contract FeesTest is Test, Deployers, TokenFixture, GasSnapshot {
    using Pool for Pool.State;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    IOxionStorage oxionStorage;
    Pool.State state;
    PoolManager manager;

    PoolManagerRouter router;
    ProtocolFeeControllerTest protocolFeeController;
    PoolKey key;

    bool _zeroForOne = true;
    bool _oneForZero = false;

    function setUp() public {
        initializeTokens();
        (oxionStorage, manager) = Deployers.createFreshManager();

        router = new PoolManagerRouter(oxionStorage, manager);
        protocolFeeController = new ProtocolFeeControllerTest();
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
