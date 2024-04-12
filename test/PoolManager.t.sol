// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {IOxionStorage} from "../src/interfaces/IOxionStorage.sol";
import {ERC20PresetFixedSupply} from "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetFixedSupply.sol";
import {OxionStorage} from "../src/OxionStorage.sol";
import {IPoolManager} from "../src/interfaces/IPoolManager.sol";
import {PoolManager} from "../src/PoolManager.sol";
import {Pool} from "../src/libraries/Pool.sol";
import {Currency, CurrencyLibrary} from "../src/types/Currency.sol";
import {PoolKey} from "../src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "../src/types/PoolId.sol";
import {TickMath} from "../src/libraries/TickMath.sol";
import {IFees} from "../src/interfaces/IFees.sol";
import {PoolManagerRouter} from "./helpers/PoolManagerRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Position} from "../src/libraries/Position.sol";
import {Deployers} from "./helpers/Deployers.sol";
import {TokenFixture, MockERC20} from "./helpers/TokenFixture.sol";
import {FeeLibrary} from "../src/libraries/FeeLibrary.sol";
import {PoolParametersHelper} from "../src/libraries/PoolParametersHelper.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "../src/types/BalanceDelta.sol";
import {NonStandardERC20} from "./helpers/NonStandardERC20.sol";
import {ProtocolFeeControllerTest} from "./helpers/ProtocolFeeControllerTest.sol";
import {IProtocolFeeController} from "../src/interfaces/IProtocolFeeController.sol";
import {FullMath} from "../src/libraries/FullMath.sol";

contract PoolManagerTest is Test, Deployers, TokenFixture, GasSnapshot {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using PoolParametersHelper for bytes32;
    using FeeLibrary for uint24;

    event Initialize(
        PoolId indexed id,
        Currency indexed currency0,
        Currency indexed currency1,
        uint24 fee,
        int24 tickSpacing
    );

    event ModifyLiquidity(
        PoolId indexed poolId, address indexed sender, int24 tickLower, int24 tickUpper, int256 liquidityDelta
    );

    event Swap(
        PoolId indexed poolId,
        address indexed sender,
        int128 amount0,
        int128 amount1,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        int24 tick,
        uint24 fee,
        uint256 protocolFee
    );

    event Transfer(address caller, address indexed from, address indexed to, Currency indexed currency, uint256 amount);

    event ProtocolFeeUpdated(PoolId indexed id, uint16 protocolFees);

    event Donate(PoolId indexed id, address indexed sender, uint256 amount0, uint256 amount1, int24 tick);

    IOxionStorage public oxionStorage;
    PoolManager public poolManager;
    PoolManagerRouter public router;
    ProtocolFeeControllerTest public protocolFeeController;
    ProtocolFeeControllerTest public feeController;

    function setUp() public {
        initializeTokens();
        (oxionStorage, poolManager) = createFreshManager();
        router = new PoolManagerRouter(oxionStorage, poolManager);
        protocolFeeController = new ProtocolFeeControllerTest();
        feeController = new ProtocolFeeControllerTest();

        IERC20(Currency.unwrap(currency0)).approve(address(router), 10 ether);
        IERC20(Currency.unwrap(currency1)).approve(address(router), 10 ether);
    }

    // **************              *************** //
    // **************  initialize  *************** //
    // **************              *************** //
    function testInitialize_feeRange() external {
        // 100 i.e. 0.01%
        {
            PoolKey memory key = PoolKey({
                currency0: Currency.wrap(makeAddr("token0")),
                currency1: Currency.wrap(makeAddr("token1")),
                poolManager: poolManager,
                fee: uint24(100)
            });

            poolManager.initialize(key, TickMath.MIN_SQRT_RATIO);
        }
        // 500 i.e. 0.05%
        {
            PoolKey memory key = PoolKey({
                currency0: Currency.wrap(makeAddr("token0")),
                currency1: Currency.wrap(makeAddr("token1")),
                poolManager: poolManager,
                fee: uint24(500)
            });

            poolManager.initialize(key, TickMath.MIN_SQRT_RATIO);
        }
        // 3000 i.e. 0.3%
        {
            PoolKey memory key = PoolKey({
                currency0: Currency.wrap(makeAddr("token0")),
                currency1: Currency.wrap(makeAddr("token1")),
                poolManager: poolManager,
                fee: uint24(3000)
            });

            poolManager.initialize(key, TickMath.MIN_SQRT_RATIO);
        }
    }

    function testInitialize_stateCheck() external {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(makeAddr("token0")),
            currency1: Currency.wrap(makeAddr("token1")),
            poolManager: poolManager,
            fee: uint24(3000)
        });

        poolManager.initialize(key, TickMath.MIN_SQRT_RATIO);

        (Pool.Slot0 memory slot0, uint256 feeGrowthGlobal0X128, uint256 feeGrowthGlobal1X128, uint128 liquidity) =
         poolManager.pools(key.toId());

        assertEq(slot0.sqrtPriceX96, TickMath.MIN_SQRT_RATIO);
        assertEq(slot0.tick, TickMath.MIN_TICK);
        assertEq(slot0.protocolFee, 0);
        assertEq(feeGrowthGlobal0X128, 0);
        assertEq(feeGrowthGlobal1X128, 0);
        assertEq(liquidity, 0);
    }

    function testInitialize_gasCheck() external {
        Currency currency0 = Currency.wrap(address(new ERC20PresetFixedSupply("C0", "C0", 100 ether, address(this))));
        Currency currency1 = Currency.wrap(address(new ERC20PresetFixedSupply("C1", "C1", 100 ether, address(this))));

        if (currency0 > currency1) {
            (currency0, currency1) = (currency1, currency0);
        }

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            poolManager: poolManager,
            fee: uint24(3000)
        });

        snapStart("PoolManagerTest#initialize");
        poolManager.initialize(key, TickMath.MIN_SQRT_RATIO);
        snapEnd();
    }

    function test_initialize_forNativeTokens(uint160 sqrtPriceX96) public {
        // Assumptions tested in Pool.t.sol
        sqrtPriceX96 = uint160(bound(sqrtPriceX96, TickMath.MIN_SQRT_RATIO, TickMath.MAX_SQRT_RATIO - 1));

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: currency1,
            fee: 3000,
            poolManager: poolManager
        });

        vm.expectEmit(true, true, true, true);
        emit Initialize(
            key.toId(),
            key.currency0,
            key.currency1,
            key.fee,
            60
        );
        ////////////////////////////////////////////////////////////////////////////////////////////////////////////////
        poolManager.initialize(key, sqrtPriceX96);

        (Pool.Slot0 memory slot0,,,) = poolManager.pools(key.toId());
        assertEq(slot0.sqrtPriceX96, sqrtPriceX96);
        assertEq(slot0.protocolFee, 0);
        assertEq(slot0.tick, TickMath.getTickAtSqrtRatio(sqrtPriceX96));
    }

    function test_initialize_succeedsWithHooks(uint160 sqrtPriceX96) public {
        // Assumptions tested in Pool.t.sol
        sqrtPriceX96 = uint160(bound(sqrtPriceX96, TickMath.MIN_SQRT_RATIO, TickMath.MAX_SQRT_RATIO - 1));

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            poolManager: poolManager
        });

        poolManager.initialize(key, sqrtPriceX96);
        (Pool.Slot0 memory slot0,,,) = poolManager.pools(key.toId());
        assertEq(slot0.sqrtPriceX96, sqrtPriceX96);
    }

    function test_initialize_succeedsWithMaxTickSpacing(uint160 sqrtPriceX96) public {
        // Assumptions tested in Pool.t.sol
        sqrtPriceX96 = uint160(bound(sqrtPriceX96, TickMath.MIN_SQRT_RATIO, TickMath.MAX_SQRT_RATIO - 1));

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            poolManager: poolManager
        });


        vm.expectEmit(true, true, true, true);
        emit Initialize(
            key.toId(),
            key.currency0,
            key.currency1,
            key.fee,
            60
        );

        poolManager.initialize(key, sqrtPriceX96);
    }

    function test_initialize_revertsWithIdenticalTokens(uint160 sqrtPriceX96) public {
        // Assumptions tested in Pool.t.sol
        sqrtPriceX96 = uint160(bound(sqrtPriceX96, TickMath.MIN_SQRT_RATIO, TickMath.MAX_SQRT_RATIO - 1));

        // Both currencies are currency0
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency0,
            fee: 3000,
            poolManager: poolManager
        });

        vm.expectRevert(IPoolManager.CurrenciesInitializedOutOfOrder.selector);
        poolManager.initialize(key, sqrtPriceX96);
    }

    function test_initialize_revertsWithSameTokenCombo(uint160 sqrtPriceX96) public {
        // Assumptions tested in Pool.t.sol
        sqrtPriceX96 = uint160(bound(sqrtPriceX96, TickMath.MIN_SQRT_RATIO, TickMath.MAX_SQRT_RATIO - 1));

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            poolManager: poolManager
        });

        PoolKey memory keyInvertedCurrency = PoolKey({
            currency0: currency1,
            currency1: currency0,
            fee: 3000,
            poolManager: poolManager
        });

        poolManager.initialize(key, sqrtPriceX96);
        vm.expectRevert(IPoolManager.CurrenciesInitializedOutOfOrder.selector);
        poolManager.initialize(keyInvertedCurrency, sqrtPriceX96);
    }

    function test_initialize_revertsWhenPoolAlreadyInitialized(uint160 sqrtPriceX96) public {
        // Assumptions tested in Pool.t.sol
        sqrtPriceX96 = uint160(bound(sqrtPriceX96, TickMath.MIN_SQRT_RATIO, TickMath.MAX_SQRT_RATIO - 1));

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            poolManager: poolManager
        });

        poolManager.initialize(key, sqrtPriceX96);
        vm.expectRevert(Pool.PoolAlreadyInitialized.selector);
        poolManager.initialize(key, sqrtPriceX96);
    }

    function test_initialize_failsWithIncorrectSelectors() public {
    
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 100,
            poolManager: poolManager
        });

        poolManager.initialize(key, SQRT_RATIO_1_1);
    } 

    function test_initialize_succeedsWithCorrectSelectors() public {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 100,
            poolManager: poolManager
        });

        vm.expectEmit(true, true, true, true);
        emit Initialize(
            key.toId(),
            key.currency0,
            key.currency1,
            key.fee,
            1
        );

        poolManager.initialize(key, SQRT_RATIO_1_1);
    }

    function test_initialize_failsIfTickSpaceTooLarge(uint160 sqrtPriceX96) public {
        // Assumptions tested in Pool.t.sol
        sqrtPriceX96 = uint160(bound(sqrtPriceX96, TickMath.MIN_SQRT_RATIO, TickMath.MAX_SQRT_RATIO - 1));

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            poolManager: poolManager
        });


        poolManager.initialize(key, sqrtPriceX96);
    }

    function test_initialize_failsNoOpMissingBeforeCall() public {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            poolManager: poolManager
        });

        poolManager.initialize(key, TickMath.MIN_SQRT_RATIO);
    }

    // **************                  *************** //
    // **************  modifyPosition  *************** //
    // **************                  *************** //

    function testModifyPosition_addLiquidity() external {
        Currency currency0 = Currency.wrap(address(new ERC20PresetFixedSupply("C0", "C0", 1e10 ether, address(this))));
        Currency currency1 = Currency.wrap(address(new ERC20PresetFixedSupply("C1", "C1", 1e10 ether, address(this))));

        if (currency0 > currency1) {
            (currency0, currency1) = (currency1, currency0);
        }

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            poolManager: poolManager,
            fee: uint24(100)
        });

        // price = 100 tick roughly 46054
        poolManager.initialize(key, uint160(10 * FullMath.Q96));

        IERC20(Currency.unwrap(currency0)).approve(address(router), 1e10 ether);
        IERC20(Currency.unwrap(currency1)).approve(address(router), 1e10 ether);

        snapStart("PoolManagerTest#addLiquidity_fromEmpty");
        router.modifyPosition(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.MIN_TICK,
                tickUpper: TickMath.MAX_TICK,
                liquidityDelta: 1e24
            })
        );
        snapEnd();

        {
            uint256 token0Left = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
            uint256 token1Left = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

            // consume both X and Y, python:
            // >>> X = ((1.0001 ** tick0) ** -0.5 - (1.0001 ** tick1) ** -0.5) * 1e24
            // >>> Y = ((1.0001 ** tick1) ** 0.5 - (1.0001 ** tick0) ** 0.5) * 1e24
            assertEq(1e10 ether - token0Left, 99999999999999999945788);
            assertEq(1e10 ether - token1Left, 9999999999999999999945788);

            assertEq(poolManager.getLiquidity(key.toId()), 1e24);
            assertEq(poolManager.getLiquidity(key.toId(), address(router), TickMath.MIN_TICK, TickMath.MAX_TICK), 1e24);

            assertEq(
                poolManager.getPosition(key.toId(), address(router), TickMath.MIN_TICK, TickMath.MAX_TICK)
                    .feeGrowthInside0LastX128,
                0
            );
            assertEq(
                poolManager.getPosition(key.toId(), address(router), TickMath.MIN_TICK, TickMath.MAX_TICK)
                    .feeGrowthInside1LastX128,
                0
            );
        }

        snapStart("PoolManagerTest#addLiquidity_fromNonEmpty");
        router.modifyPosition(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.MIN_TICK,
                tickUpper: TickMath.MAX_TICK,
                liquidityDelta: 1e4
            })
        );
        snapEnd();

        {
            uint256 token0Left = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
            uint256 token1Left = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

            // consume both X and Y, python:
            // >>> X = ((1.0001 ** tick0) ** -0.5 - (1.0001 ** tick1) ** -0.5) * 1e24
            // >>> Y = ((1.0001 ** tick1) ** 0.5 - (1.0001 ** tick0) ** 0.5) * 1e24
            assertEq(1e10 ether - token0Left, 99999999999999999946788);
            assertEq(1e10 ether - token1Left, 10000000000000000000045788);

            assertEq(poolManager.getLiquidity(key.toId()), 1e24 + 1e4);
            assertEq(
                poolManager.getLiquidity(key.toId(), address(router), TickMath.MIN_TICK, TickMath.MAX_TICK), 1e24 + 1e4
            );

            assertEq(
                poolManager.getPosition(key.toId(), address(router), TickMath.MIN_TICK, TickMath.MAX_TICK)
                    .feeGrowthInside0LastX128,
                0
            );
            assertEq(
                poolManager.getPosition(key.toId(), address(router), TickMath.MIN_TICK, TickMath.MAX_TICK)
                    .feeGrowthInside1LastX128,
                0
            );
        }
    }

    function testModifyPosition_Liquidity_aboveCurrentTick() external {
        Currency currency0 = Currency.wrap(address(new ERC20PresetFixedSupply("C0", "C0", 1e30 ether, address(this))));
        Currency currency1 = Currency.wrap(address(new ERC20PresetFixedSupply("C1", "C1", 1e30 ether, address(this))));

        if (currency0 > currency1) {
            (currency0, currency1) = (currency1, currency0);
        }

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            poolManager: poolManager,
            fee: uint24(100)
        });

        // price = 100 tick roughly 46054
        poolManager.initialize(key, uint160(10 * FullMath.Q96));

        IERC20(Currency.unwrap(currency0)).approve(address(router), 1e30 ether);
        IERC20(Currency.unwrap(currency1)).approve(address(router), 1e30 ether);

        router.modifyPosition(
            key, IPoolManager.ModifyLiquidityParams({tickLower: 46055, tickUpper: 46060, liquidityDelta: 1e9})
        );

        uint256 token0Left = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 token1Left = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        // consume X only, python:
        // >>> ((1.0001 ** tick0) ** -0.5 - (1.0001 ** tick1) ** -0.5) * 1e9
        // 24994.381475337836
        assertEq(1e30 ether - token0Left, 24995);
        assertEq(1e30 ether - token1Left, 0);

        // no active liquidity
        assertEq(poolManager.getLiquidity(key.toId()), 0);
        assertEq(poolManager.getLiquidity(key.toId(), address(router), 46055, 46060), 1e9);

        assertEq(poolManager.getPosition(key.toId(), address(this), 46055, 46060).feeGrowthInside0LastX128, 0);
        assertEq(poolManager.getPosition(key.toId(), address(this), 46055, 46060).feeGrowthInside1LastX128, 0);
    }

    function testModifyPosition_addLiquidity_belowCurrentTick() external {
        Currency currency0 = Currency.wrap(address(new ERC20PresetFixedSupply("C0", "C0", 1e30 ether, address(this))));
        Currency currency1 = Currency.wrap(address(new ERC20PresetFixedSupply("C1", "C1", 1e30 ether, address(this))));

        if (currency0 > currency1) {
            (currency0, currency1) = (currency1, currency0);
        }

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            poolManager: poolManager,
            fee: uint24(500)
        });

        // price = 100 tick roughly 46054
        poolManager.initialize(key, uint160(10 * FullMath.Q96));

        IERC20(Currency.unwrap(currency0)).approve(address(router), 1e30 ether);
        IERC20(Currency.unwrap(currency1)).approve(address(router), 1e30 ether);

        router.modifyPosition(
            key, IPoolManager.ModifyLiquidityParams({tickLower: 46000, tickUpper: 46050, liquidityDelta: 1e9})
        );

        uint256 token0Left = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 token1Left = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        // consume Y only, python:
        //>>> ((1.0001 ** tick1) ** 0.5 - (1.0001 ** tick0) ** 0.5) * 1e9
        // 24962530.97288914
        assertEq(1e30 ether - token0Left, 0);
        assertEq(1e30 ether - token1Left, 24962531);

        // no active liquidity
        assertEq(poolManager.getLiquidity(key.toId()), 0);
        assertEq(poolManager.getLiquidity(key.toId(), address(router), 46000, 46050), 1e9);

        assertEq(poolManager.getPosition(key.toId(), address(router), 46000, 46050).feeGrowthInside0LastX128, 0);
        assertEq(poolManager.getPosition(key.toId(), address(router), 46000, 46050).feeGrowthInside1LastX128, 0);
    }

    function testModifyPosition_removeLiquidity_fromEmpty() external {
        Currency currency0 = Currency.wrap(address(new ERC20PresetFixedSupply("C0", "C0", 1e36 ether, address(this))));
        Currency currency1 = Currency.wrap(address(new ERC20PresetFixedSupply("C1", "C1", 1e36 ether, address(this))));

        if (currency0 > currency1) {
            (currency0, currency1) = (currency1, currency0);
        }

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            poolManager: poolManager,
            fee: uint24(3000)
        });

        // price = 100 tick roughly 46054
        poolManager.initialize(key, uint160(10 * FullMath.Q96));

        IERC20(Currency.unwrap(currency0)).approve(address(router), 1e30 ether);
        IERC20(Currency.unwrap(currency1)).approve(address(router), 1e30 ether);

        vm.expectRevert(stdError.arithmeticError);
        router.modifyPosition(
            key, IPoolManager.ModifyLiquidityParams({tickLower: 46000, tickUpper: 46050, liquidityDelta: -1})
        );
    }

    function testModifyPosition_removeLiquidity_updateEmptyPosition() external {
        Currency currency0 = Currency.wrap(address(new ERC20PresetFixedSupply("C0", "C0", 1e36 ether, address(this))));
        Currency currency1 = Currency.wrap(address(new ERC20PresetFixedSupply("C1", "C1", 1e36 ether, address(this))));

        if (currency0 > currency1) {
            (currency0, currency1) = (currency1, currency0);
        }

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            poolManager: poolManager,
            fee: uint24(3000)
        });

        // price = 100 tick roughly 46054
        poolManager.initialize(key, uint160(10 * FullMath.Q96));

        IERC20(Currency.unwrap(currency0)).approve(address(router), 1e30 ether);
        IERC20(Currency.unwrap(currency1)).approve(address(router), 1e30 ether);

        vm.expectRevert(Position.CannotUpdateEmptyPosition.selector);
        router.modifyPosition(
            key, IPoolManager.ModifyLiquidityParams({tickLower: 46000, tickUpper: 46050, liquidityDelta: 0})
        );
    }

    function testModifyPosition_removeLiquidity_empty() external {
        Currency currency0 = Currency.wrap(address(new ERC20PresetFixedSupply("C0", "C0", 1e36 ether, address(this))));
        Currency currency1 = Currency.wrap(address(new ERC20PresetFixedSupply("C1", "C1", 1e36 ether, address(this))));

        if (currency0 > currency1) {
            (currency0, currency1) = (currency1, currency0);
        }

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            poolManager: poolManager,
            fee: uint24(100)
        });

        // price = 1 i.e. tick 0
        poolManager.initialize(key, uint160(1 * FullMath.Q96));

        IERC20(Currency.unwrap(currency0)).approve(address(router), 1e30 ether);
        IERC20(Currency.unwrap(currency1)).approve(address(router), 1e30 ether);

        router.modifyPosition(
            key, IPoolManager.ModifyLiquidityParams({tickLower: -1, tickUpper: 1, liquidityDelta: 100 ether})
        );

        assertEq(poolManager.getLiquidity(key.toId()), 100 ether, "total liquidity should be 1000");
        assertEq(
            poolManager.getLiquidity(key.toId(), address(router), -1, 1), 100 ether, "router's liquidity should be 1000"
        );

        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(address(oxionStorage)), 4999625031247266);
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(address(oxionStorage)), 4999625031247266);

        assertEq(poolManager.getPosition(key.toId(), address(router), -1, 1).feeGrowthInside0LastX128, 0);
        assertEq(poolManager.getPosition(key.toId(), address(router), -1, 1).feeGrowthInside1LastX128, 0);

        router.modifyPosition(
            key, IPoolManager.ModifyLiquidityParams({tickLower: -1, tickUpper: 1, liquidityDelta: -100 ether})
        );

        assertEq(poolManager.getLiquidity(key.toId()), 0);
        assertEq(poolManager.getLiquidity(key.toId(), address(router), -1, 1), 0);

        // expected to receive 0, but got 1 because of precision loss
        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(address(oxionStorage)), 1);
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(address(oxionStorage)), 1);

        assertEq(poolManager.getPosition(key.toId(), address(router), -1, 1).feeGrowthInside0LastX128, 0);
        assertEq(poolManager.getPosition(key.toId(), address(router), -1, 1).feeGrowthInside1LastX128, 0);
    }

    function testModifyPosition_removeLiquidity_halfAndThenAll() external {
        Currency currency0 = Currency.wrap(address(new ERC20PresetFixedSupply("C0", "C0", 1e30 ether, address(this))));
        Currency currency1 = Currency.wrap(address(new ERC20PresetFixedSupply("C1", "C1", 1e30 ether, address(this))));

        if (currency0 > currency1) {
            (currency0, currency1) = (currency1, currency0);
        }

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            poolManager: poolManager,
            fee: uint24(500)
        });

        // price = 100 tick roughly 46054
        poolManager.initialize(key, uint160(10 * FullMath.Q96));

        IERC20(Currency.unwrap(currency0)).approve(address(router), 1e30 ether);
        IERC20(Currency.unwrap(currency1)).approve(address(router), 1e30 ether);

        router.modifyPosition(
            key, IPoolManager.ModifyLiquidityParams({tickLower: 46000, tickUpper: 46050, liquidityDelta: 1e9})
        );

        {
            uint256 token0Left = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
            uint256 token1Left = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

            // consume Y only, python:
            //>>> ((1.0001 ** tick1) ** 0.5 - (1.0001 ** tick0) ** 0.5) * 1e9
            // 24962530.97288914
            assertEq(1e30 ether - token0Left, 0);
            assertEq(1e30 ether - token1Left, 24962531);

            // no active liquidity
            assertEq(poolManager.getLiquidity(key.toId()), 0);
            assertEq(poolManager.getLiquidity(key.toId(), address(router), 46000, 46050), 1e9);

            assertEq(poolManager.getPosition(key.toId(), address(router), 46000, 46050).feeGrowthInside0LastX128, 0);
            assertEq(poolManager.getPosition(key.toId(), address(router), 46000, 46050).feeGrowthInside1LastX128, 0);
        }

        // remove half
        snapStart("PoolManagerTest#removeLiquidity_toNonEmpty");
        router.modifyPosition(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: 46000, tickUpper: 46050, liquidityDelta: -5 * 1e8})
        );
        snapEnd();

        {
            uint256 token0Left = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
            uint256 token1Left = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

            // half of 24962531
            assertEq(1e30 ether - token0Left, 0);
            assertEq(1e30 ether - token1Left, 12481266);

            // no active liquidity
            assertEq(poolManager.getLiquidity(key.toId()), 0);
            assertEq(poolManager.getLiquidity(key.toId(), address(router), 46000, 46050), 5 * 1e8);

            assertEq(poolManager.getPosition(key.toId(), address(router), 46000, 46050).feeGrowthInside0LastX128, 0);
            assertEq(poolManager.getPosition(key.toId(), address(router), 46000, 46050).feeGrowthInside1LastX128, 0);
        }

        router.modifyPosition(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: 46000, tickUpper: 46050, liquidityDelta: -5 * 1e8})
        );

        {
            uint256 token0Left = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
            uint256 token1Left = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

            // back to 0
            assertEq(1e30 ether - token0Left, 0);

            // expected to receive 0, but got 1 because of precision loss
            assertEq(1e30 ether - token1Left, 1);

            // no active liquidity
            assertEq(poolManager.getLiquidity(key.toId()), 0);
            assertEq(poolManager.getLiquidity(key.toId(), address(router), 46000, 46050), 0);

            assertEq(poolManager.getPosition(key.toId(), address(router), 46000, 46050).feeGrowthInside0LastX128, 0);
            assertEq(poolManager.getPosition(key.toId(), address(router), 46000, 46050).feeGrowthInside1LastX128, 0);
        }
    }

    function testModifyPosition_failsIfNotInitialized() public {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            poolManager: poolManager
        });
        vm.expectRevert();
        router.modifyPosition(
            key, IPoolManager.ModifyLiquidityParams({tickLower: 0, tickUpper: 60, liquidityDelta: 100})
        );
    }

    function testModifyPosition_succeedsIfInitialized(uint160 sqrtPriceX96) public {
        sqrtPriceX96 = uint160(bound(sqrtPriceX96, TickMath.MIN_SQRT_RATIO, TickMath.MAX_SQRT_RATIO - 1));

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            poolManager: poolManager
        });

        poolManager.initialize(key, sqrtPriceX96);

        vm.expectEmit(true, true, true, true);
        emit ModifyLiquidity(key.toId(), address(router), 0, 60, 100);

        router.modifyPosition(
            key, IPoolManager.ModifyLiquidityParams({tickLower: 0, tickUpper: 60, liquidityDelta: 100})
        );
    }

    function testModifyPosition_succeedsForNativeTokensIfInitialized(uint160 sqrtPriceX96) public {
        sqrtPriceX96 = uint160(bound(sqrtPriceX96, TickMath.MIN_SQRT_RATIO, TickMath.MAX_SQRT_RATIO - 1));

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: currency1,
            fee: 3000,
            poolManager: poolManager
        });

        poolManager.initialize(key, sqrtPriceX96);
        vm.expectEmit(true, true, true, true);
        emit ModifyLiquidity(key.toId(), address(router), 0, 60, 100);

        router.modifyPosition{value: 100}(
            key, IPoolManager.ModifyLiquidityParams({tickLower: 0, tickUpper: 60, liquidityDelta: 100})
        );
    }

    function testModifyPosition_succeedsWithHooksIfInitialized(uint160 sqrtPriceX96) public {
        sqrtPriceX96 = uint160(bound(sqrtPriceX96, TickMath.MIN_SQRT_RATIO, TickMath.MAX_SQRT_RATIO - 1));

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            poolManager: poolManager
        });

        IPoolManager.ModifyLiquidityParams memory params =
            IPoolManager.ModifyLiquidityParams({tickLower: 0, tickUpper: 60, liquidityDelta: 100});

        poolManager.initialize(key, sqrtPriceX96);

        BalanceDelta balanceDelta;
        // create a new context to swallow up the revert
        try PoolManagerTest(payable(this)).tryExecute(
            address(router),
            abi.encodeWithSelector(PoolManagerRouter.modifyPosition.selector, key, params)
        ) {
            revert("must revert");
        } catch (bytes memory result) {
            balanceDelta = abi.decode(result, (BalanceDelta));
        }
        router.modifyPosition(key, params);
    }

    function testModifyPosition_succeedsWithCorrectSelectors() public {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 100,
            poolManager: poolManager
        });

        IPoolManager.ModifyLiquidityParams memory params =
            IPoolManager.ModifyLiquidityParams({tickLower: 0, tickUpper: 60, liquidityDelta: 100});

        poolManager.initialize(key, SQRT_RATIO_1_1);

        vm.expectEmit(true, true, true, true);
        emit ModifyLiquidity(key.toId(), address(router), 0, 60, 100);

        router.modifyPosition(key, params);
    }

    function testModifyPosition_withNative_gas() public {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: currency1,
            fee: 3000,
            poolManager: poolManager
        });

        poolManager.initialize(key, SQRT_RATIO_1_1);

        snapStart("PoolManagerTest#addLiquidity_nativeToken");
        router.modifyPosition{value: 100}(
            key, IPoolManager.ModifyLiquidityParams({tickLower: 0, tickUpper: 60, liquidityDelta: 100})
        );
        snapEnd();
    }

    // **************        *************** //
    // **************  swap  *************** //
    // **************        *************** //

    function testSwap_runOutOfLiquidity() external {
        Currency currency0 = Currency.wrap(address(new ERC20PresetFixedSupply("C0", "C0", 1e30 ether, address(this))));
        Currency currency1 = Currency.wrap(address(new ERC20PresetFixedSupply("C1", "C1", 1e30 ether, address(this))));

        if (currency0 > currency1) {
            (currency0, currency1) = (currency1, currency0);
        }

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            poolManager: poolManager,
            fee: uint24(100)
        });

        // price = 100 tick roughly 46054
        poolManager.initialize(key, uint160(10 * FullMath.Q96));

        IERC20(Currency.unwrap(currency0)).approve(address(router), 1e30 ether);
        IERC20(Currency.unwrap(currency1)).approve(address(router), 1e30 ether);

        router.modifyPosition(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: 46053, tickUpper: 46055, liquidityDelta: 1000000 ether})
        );

        // token0: roughly 5 ether
        assertEq(oxionStorage.reservesOfStorage(currency0), 4977594234867895338);
        // token1: roughly 502 ether
        assertEq(oxionStorage.reservesOfStorage(currency1), 502165582277283491084);

        // swap 10 ether token0 for token1
        snapStart("PoolManagerTest#swap_runOutOfLiquidity");
        router.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: 10 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_RATIO + 1
            }),
            PoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true})
        );
        snapEnd();

        //        console2.log("token0 balance: ", int256(oxionStorage.reservesOfStorage(currency0)));
        //        console2.log("token1 balance: ", int256(oxionStorage.reservesOfStorage(currency1)));
    }

    function testSwap_failsIfNotInitialized(uint160 sqrtPriceX96) public {
        sqrtPriceX96 = uint160(bound(sqrtPriceX96, TickMath.MIN_SQRT_RATIO, TickMath.MAX_SQRT_RATIO - 1));

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            poolManager: poolManager
        });

        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100, sqrtPriceLimitX96: sqrtPriceX96});

        PoolManagerRouter.SwapTestSettings memory testSettings =
            PoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true});

        vm.expectRevert();
        router.swap(key, params, testSettings);
    }

    function testSwap_succeedsIfInitialized() public {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            poolManager: poolManager
        });

        poolManager.initialize(key, SQRT_RATIO_1_1);

        IPoolManager.ModifyLiquidityParams memory modifyPositionParams =
            IPoolManager.ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1 ether});

        router.modifyPosition(key, modifyPositionParams);

        vm.expectEmit(true, true, true, true);
        emit Swap(
            key.toId(), address(router), 100, -98, 79228162514264329749955861424, 1000000000000000000, -1, 3000, 0
        );

        // sell base token(x) for quote token(y), pricea(y / x) decreases
        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100, sqrtPriceLimitX96: SQRT_RATIO_1_2});

        PoolManagerRouter.SwapTestSettings memory testSettings =
            PoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true});

        router.swap(key, params, testSettings);
    }

    function testSwap_crossLmTickUncalled() public {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            poolManager: poolManager
        });

        poolManager.initialize(key, SQRT_RATIO_1_1);

        IPoolManager.ModifyLiquidityParams memory modifyPositionParams =
            IPoolManager.ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 1 ether});

        router.modifyPosition(key, modifyPositionParams);

        // sell base token(x) for quote token(y), pricea(y / x) decreases
        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 0.1 ether, sqrtPriceLimitX96: SQRT_RATIO_1_2});

        PoolManagerRouter.SwapTestSettings memory testSettings =
            PoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true});

        router.swap(key, params, testSettings);
    }

    function testSwap_crossLmTickCalled() public {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            poolManager: poolManager
        });

        poolManager.initialize(key, SQRT_RATIO_1_1);
        IPoolManager.ModifyLiquidityParams memory modifyPositionParams =
            IPoolManager.ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1 ether});

        router.modifyPosition(key, modifyPositionParams);

        // vm.expectEmit(true, true, true, true);
        // emit Swap(
        //     key.toId(),
        //     address(router),
        //     3013394245478362,
        //     -2995354955910780,
        //     56022770974786139918731938227,
        //     0,
        //     -6932,
        //     3000,
        //     0
        // );

        // sell base token(x) for quote token(y), pricea(y / x) decreases
        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 0.1 ether, sqrtPriceLimitX96: SQRT_RATIO_1_2});

        PoolManagerRouter.SwapTestSettings memory testSettings =
            PoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true});

        router.swap(key, params, testSettings);
    }

    function testSwap_succeedsWithNativeTokensIfInitialized() public {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: currency1,
            fee: 3000,
            poolManager: poolManager
        });

        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100, sqrtPriceLimitX96: SQRT_RATIO_1_2});

        PoolManagerRouter.SwapTestSettings memory testSettings =
            PoolManagerRouter.SwapTestSettings({withdrawTokens: false, settleUsingTransfer: false});

        poolManager.initialize(key, SQRT_RATIO_1_1);

        vm.expectEmit(true, true, true, true);
        emit Swap(key.toId(), address(router), 0, 0, SQRT_RATIO_1_2, 0, -6932, 3000, 0);

        router.swap(key, params, testSettings);
    }

    function testSwap_succeedsWithHooksIfInitialized() public {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            poolManager: poolManager
        });

        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100, sqrtPriceLimitX96: SQRT_RATIO_1_2});

        PoolManagerRouter.SwapTestSettings memory testSettings =
            PoolManagerRouter.SwapTestSettings({withdrawTokens: false, settleUsingTransfer: false});

        poolManager.initialize(key, SQRT_RATIO_1_1);

        BalanceDelta balanceDelta;
        // create a new context to swallow up the revert
        try PoolManagerTest(payable(this)).tryExecute(
            address(router),
            abi.encodeWithSelector(PoolManagerRouter.swap.selector, key, params, testSettings)
        ) {
            revert("must revert");
        } catch (bytes memory result) {
            balanceDelta = abi.decode(result, (BalanceDelta));
        }
        router.swap(key, params, testSettings);
    }

    function testSwap_succeedsWithCorrectSelectors() public {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 100,
            poolManager: poolManager
        });

        IPoolManager.ModifyLiquidityParams memory params =
            IPoolManager.ModifyLiquidityParams({tickLower: 0, tickUpper: 60, liquidityDelta: 100});

        IPoolManager.SwapParams memory swapParams =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 10, sqrtPriceLimitX96: SQRT_RATIO_1_2});

        PoolManagerRouter.SwapTestSettings memory testSettings =
            PoolManagerRouter.SwapTestSettings({withdrawTokens: false, settleUsingTransfer: false});

        poolManager.initialize(key, SQRT_RATIO_1_1);
        router.modifyPosition(key, params);

        vm.expectEmit(true, true, true, true);
        emit Swap(key.toId(), address(router), 0, 0, SQRT_RATIO_1_2, 0, -6932, 100, 0);

        router.swap(key, swapParams, testSettings);
    }

    function testSwap_leaveSurplusTokenInVault() public {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            poolManager: poolManager
        });

        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100, sqrtPriceLimitX96: SQRT_RATIO_1_2});

        PoolManagerRouter.SwapTestSettings memory testSettings =
            PoolManagerRouter.SwapTestSettings({withdrawTokens: false, settleUsingTransfer: true});

        poolManager.initialize(key, SQRT_RATIO_1_1);
        router.modifyPosition(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1000000000000000000})
        );

        vm.expectEmit(true, true, true, true);
        emit Transfer(address(router), address(0), address(this), currency1, 98);
        router.swap(key, params, testSettings);

        uint256 surplusTokenAmount = oxionStorage.balanceOf(address(this), currency1);
        assertEq(surplusTokenAmount, 98);
    }

    function testSwap_useSurplusTokenAsInput() public {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            poolManager: poolManager
        });

        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100, sqrtPriceLimitX96: SQRT_RATIO_1_2});

        PoolManagerRouter.SwapTestSettings memory testSettings =
            PoolManagerRouter.SwapTestSettings({withdrawTokens: false, settleUsingTransfer: true});

        poolManager.initialize(key, SQRT_RATIO_1_1);
        router.modifyPosition(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1000000000000000000})
        );
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(router), address(0), address(this), currency1, 98);
        router.swap(key, params, testSettings);

        uint256 surplusTokenAmount = oxionStorage.balanceOf(address(this), currency1);
        assertEq(surplusTokenAmount, 98);

        // give permission for router to burn the surplus tokens
        oxionStorage.approve(address(router), currency0, type(uint256).max);
        oxionStorage.approve(address(router), currency1, type(uint256).max);

        // swap from currency1 to currency0 again, using surplus tokne as input
        params = IPoolManager.SwapParams({zeroForOne: false, amountSpecified: -25, sqrtPriceLimitX96: SQRT_RATIO_4_1});

        testSettings = PoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: false});

        vm.expectEmit(true, true, true, true);
        emit Transfer(address(router), address(router), address(0), currency1, 27);
        router.swap(key, params, testSettings);

        surplusTokenAmount = oxionStorage.balanceOf(address(this), currency1);
        assertEq(surplusTokenAmount, 71);
    }

    function testSwap_gas() public {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            poolManager: poolManager
        });

        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100, sqrtPriceLimitX96: SQRT_RATIO_1_2});

        PoolManagerRouter.SwapTestSettings memory testSettings =
            PoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true});

        poolManager.initialize(key, SQRT_RATIO_1_1);
        router.swap(key, params, testSettings);

        params = IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100, sqrtPriceLimitX96: SQRT_RATIO_1_4});
        testSettings = PoolManagerRouter.SwapTestSettings({withdrawTokens: false, settleUsingTransfer: false});

        snapStart("PoolManagerTest#swap_simple");
        router.swap(key, params, testSettings);
        snapEnd();
    }

    function testSwap_withNative_gas() public {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            poolManager: poolManager
        });

        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100, sqrtPriceLimitX96: SQRT_RATIO_1_2});

        PoolManagerRouter.SwapTestSettings memory testSettings =
            PoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true});

        poolManager.initialize(key, SQRT_RATIO_1_1);
        router.swap(key, params, testSettings);

        params = IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100, sqrtPriceLimitX96: SQRT_RATIO_1_4});
        testSettings = PoolManagerRouter.SwapTestSettings({withdrawTokens: false, settleUsingTransfer: false});

        snapStart("PoolManagerTest#swap_withNative");
        router.swap(key, params, testSettings);
        snapEnd();
    }

    function testSwap_leaveSurplusTokenInVault_gas() public {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            poolManager: poolManager
        });

        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100, sqrtPriceLimitX96: SQRT_RATIO_1_2});

        PoolManagerRouter.SwapTestSettings memory testSettings =
            PoolManagerRouter.SwapTestSettings({withdrawTokens: false, settleUsingTransfer: true});

        poolManager.initialize(key, SQRT_RATIO_1_1);
        router.modifyPosition(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1000000000000000000})
        );

        snapStart("PoolManagerTest#swap_leaveSurplusTokenInVault");
        router.swap(key, params, testSettings);
        snapEnd();
    }

    function testSwap_useSurplusTokenAsInput_gas() public {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            poolManager: poolManager
        });

        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100, sqrtPriceLimitX96: SQRT_RATIO_1_2});

        PoolManagerRouter.SwapTestSettings memory testSettings =
            PoolManagerRouter.SwapTestSettings({withdrawTokens: false, settleUsingTransfer: true});

        poolManager.initialize(key, SQRT_RATIO_1_1);
        router.modifyPosition(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1000000000000000000})
        );
        router.swap(key, params, testSettings);

        uint256 surplusTokenAmount = oxionStorage.balanceOf(address(this), currency1);
        assertEq(surplusTokenAmount, 98);

        // give permission for router to burn the surplus tokens
        oxionStorage.approve(address(router), currency0, type(uint256).max);
        oxionStorage.approve(address(router), currency1, type(uint256).max);

        // swap from currency1 to currency0 again, using surplus tokne as input
        params = IPoolManager.SwapParams({zeroForOne: false, amountSpecified: -25, sqrtPriceLimitX96: SQRT_RATIO_4_1});

        testSettings = PoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: false});

        snapStart("PoolManagerTest#swap_useSurplusTokenAsInput");
        router.swap(key, params, testSettings);
        snapEnd();
    }

    function testSwap_againstLiq_gas() public {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            poolManager: poolManager
        });

        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100, sqrtPriceLimitX96: SQRT_RATIO_1_2});

        PoolManagerRouter.SwapTestSettings memory testSettings =
            PoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true});

        poolManager.initialize(key, SQRT_RATIO_1_1);
        router.modifyPosition(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1000000000000000000})
        );

        router.swap(key, params, testSettings);

        params = IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100, sqrtPriceLimitX96: SQRT_RATIO_1_4});

        snapStart("PoolManagerTest#swap_againstLiquidity");
        router.swap(key, params, testSettings);
        snapEnd();
    }

    function testSwap_againstLiqWithNative_gas() public {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: currency1,
            fee: 3000,
            poolManager: poolManager
        });

        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100, sqrtPriceLimitX96: SQRT_RATIO_1_2});

        PoolManagerRouter.SwapTestSettings memory testSettings =
            PoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true});

        poolManager.initialize(key, SQRT_RATIO_1_1);
        router.modifyPosition{value: 1 ether}(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1 ether})
        );

        router.swap{value: 1 ether}(key, params, testSettings);

        params = IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100, sqrtPriceLimitX96: SQRT_RATIO_1_4});

        snapStart("PoolManagerTest#swap_againstLiquidity");
        router.swap{value: 1 ether}(key, params, testSettings);
        snapEnd();
    }

    // **************        *************** //
    // **************  donate  *************** //
    // **************        *************** //

    function testDonateFailsIfNotInitialized() public {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 100,
            poolManager: poolManager
        });
        vm.expectRevert(abi.encodeWithSelector(Pool.PoolNotInitialized.selector));
        router.donate(key, 100, 100);
    }

    function testDonateFailsIfNoLiquidity(uint160 sqrtPriceX96) public {
        sqrtPriceX96 = uint160(bound(sqrtPriceX96, TickMath.MIN_SQRT_RATIO, TickMath.MAX_SQRT_RATIO - 1));

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 100,
            poolManager: poolManager
        });
        poolManager.initialize(key, sqrtPriceX96);
        vm.expectRevert(abi.encodeWithSelector(Pool.NoLiquidityToReceiveFees.selector));
        router.donate(key, 100, 100);
    }

    // test successful donation if pool has liquidity
    function testDonateSucceedsWhenPoolHasLiquidity() public {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 100,
            poolManager: poolManager
        });
        poolManager.initialize(key, SQRT_RATIO_1_1);

        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams(-60, 60, 100);
        router.modifyPosition(key, params);
        snapStart("PoolManagerTest#donateBothTokens");
        router.donate(key, 100, 200);
        snapEnd();

        (, uint256 feeGrowthGlobal0X128, uint256 feeGrowthGlobal1X128,) = poolManager.pools(key.toId());
        assertEq(feeGrowthGlobal0X128, 340282366920938463463374607431768211456);
        assertEq(feeGrowthGlobal1X128, 680564733841876926926749214863536422912);
    }

    function testDonateSucceedsForNativeTokensWhenPoolHasLiquidity() public {
        vm.deal(address(this), 1 ether);

        PoolKey memory key = PoolKey({
            currency0: CurrencyLibrary.NATIVE,
            currency1: currency1,
            fee: 100,
            poolManager: poolManager
        });
        poolManager.initialize(key, SQRT_RATIO_1_1);

        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams(-60, 60, 100);
        router.modifyPosition{value: 1}(key, params);
        router.donate{value: 100}(key, 100, 200);

        (, uint256 feeGrowthGlobal0X128, uint256 feeGrowthGlobal1X128,) = poolManager.pools(key.toId());
        assertEq(feeGrowthGlobal0X128, 340282366920938463463374607431768211456);
        assertEq(feeGrowthGlobal1X128, 680564733841876926926749214863536422912);
    }

    function testDonateFailsWithIncorrectSelectors() public {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 100,
            poolManager: poolManager
        });
        poolManager.initialize(key, SQRT_RATIO_1_1);

        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams(-60, 60, 100);
        router.modifyPosition(key, params);
        router.donate(key, 100, 200);
        router.donate(key, 100, 200);
    }

    function testDonateSucceedsWithCorrectSelectors() public {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 100,
            poolManager: poolManager
        });
        poolManager.initialize(key, SQRT_RATIO_1_1);

        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams(-60, 60, 100);
        router.modifyPosition(key, params);

        router.donate(key, 100, 200);
    }

    function testDonateSuccessWithEventEmitted() public {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 100,
            poolManager: poolManager
        });
        poolManager.initialize(key, SQRT_RATIO_1_1);

        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams(-60, 60, 100);
        router.modifyPosition(key, params);

        (, int24 tick,,) = poolManager.getSlot0(key.toId());

        vm.expectEmit();
        emit Donate(key.toId(), address(router), 100, 0, tick);

        router.donate(key, 100, 0);
    }

    function testGasDonateOneToken() public {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 100,
            poolManager: poolManager
        });
        poolManager.initialize(key, SQRT_RATIO_1_1);

        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams(-60, 60, 100);
        router.modifyPosition(key, params);

        snapStart("PoolManagerTest#gasDonateOneToken");
        router.donate(key, 100, 0);
        snapEnd();
    }

    function testTake_failsWithInvalidTokensThatDoNotReturnTrueOnTransfer() public {
        NonStandardERC20 invalidToken = new NonStandardERC20(2 ** 255);
        Currency invalidCurrency = Currency.wrap(address(invalidToken));
        bool currency0Invalid = invalidCurrency < currency0;
        PoolKey memory key = PoolKey({
            currency0: currency0Invalid ? invalidCurrency : currency0,
            currency1: currency0Invalid ? currency0 : invalidCurrency,
            fee: 3000,
            poolManager: poolManager
        });

        invalidToken.approve(address(router), type(uint256).max);
        invalidToken.approve(address(router), type(uint256).max);
        MockERC20(Currency.unwrap(currency0)).approve(address(router), type(uint256).max);

        poolManager.initialize(key, SQRT_RATIO_1_1);
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams(-60, 60, 1000);
        router.modifyPosition(key, params);

        (uint256 amount0, uint256 amount1) = currency0Invalid ? (1, 0) : (0, 1);
        vm.expectRevert();
        router.take(key, amount0, amount1);

        // should not revert when non zero amount passed in for valid currency
        // assertions inside router because it takes then settles
        (amount0, amount1) = currency0Invalid ? (0, 1) : (1, 0);
        router.take(key, amount0, amount1);
    }

    function testTake_succeedsWithPoolWithLiquidity() public {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 100,
            poolManager: poolManager
        });
        poolManager.initialize(key, SQRT_RATIO_1_1);

        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams(-60, 60, 100);
        router.modifyPosition(key, params);
        router.take(key, 1, 1); // assertions inside router because it takes then settles
    }

    function testTake_succeedsWithPoolWithLiquidityWithNativeToken() public {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: currency1,
            fee: 100,
            poolManager: poolManager
        });
        poolManager.initialize(key, SQRT_RATIO_1_1);

        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams(-60, 60, 100);
        router.modifyPosition{value: 100}(key, params);
        router.take{value: 1}(key, 1, 1); // assertions inside router because it takes then settles
    }

    function testSetProtocolFee_updatesProtocolFeeForInitializedPool() public {
        uint16 protocolFee = 4;

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 100,
            poolManager: poolManager
        });
        poolManager.initialize(key, SQRT_RATIO_1_1);

        (Pool.Slot0 memory slot0,,,) = poolManager.pools(key.toId());
        assertEq(slot0.protocolFee, 0);
        poolManager.setProtocolFeeController(IProtocolFeeController(address(feeController)));
        feeController.setSwapFeeForPool(key.toId(), uint16(protocolFee));

        vm.expectEmit(false, false, false, true);
        emit ProtocolFeeUpdated(key.toId(), protocolFee);
        poolManager.setProtocolFee(key);
    }

    function testCollectProtocolFees_initializesWithProtocolFeeIfCalled() public {
        uint16 protocolFee = 1028; // 00000100 00000100 i.e. 25%
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 100,
            poolManager: poolManager
        });
        poolManager.setProtocolFeeController(IProtocolFeeController(address(feeController)));
        feeController.setSwapFeeForPool(key.toId(), uint16(protocolFee));

        poolManager.initialize(key, SQRT_RATIO_1_1);
        (Pool.Slot0 memory slot0,,,) = poolManager.pools(key.toId());
        assertEq(slot0.protocolFee, protocolFee);
    }

    function testCollectProtocolFees_ERC20_allowsOwnerToAccumulateFees() public {
        uint16 protocolFee = 1028; // 00000100 00000100 i.e. 25%
        // swap fee i.e. 0.3% * protocol fee i.e. 25% * input amount i.e. 10000 = 0.075%
        uint256 expectedFees = uint256(10000) * 3000 / 1000000 * 25 / 100;

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            poolManager: poolManager
        });
        poolManager.setProtocolFeeController(IProtocolFeeController(address(feeController)));
        feeController.setSwapFeeForPool(key.toId(), uint16(protocolFee));

        poolManager.initialize(key, SQRT_RATIO_1_1);
        (Pool.Slot0 memory slot0,,,) = poolManager.pools(key.toId());
        assertEq(slot0.protocolFee, protocolFee);

        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams(-120, 120, 10 ether);
        router.modifyPosition(key, params);
        router.swap(
            key,
            IPoolManager.SwapParams(true, 10000, SQRT_RATIO_1_2),
            PoolManagerRouter.SwapTestSettings(true, true)
        );

        assertEq(poolManager.protocolFeesAccrued(currency0), expectedFees);
        assertEq(poolManager.protocolFeesAccrued(currency1), 0);
        assertEq(currency0.balanceOf(address(1)), 0);
        poolManager.collectProtocolFees(address(1), currency0, expectedFees);
        assertEq(currency0.balanceOf(address(1)), expectedFees);
        assertEq(poolManager.protocolFeesAccrued(currency0), 0);
    }

    function testCollectProtocolFees_ERC20_returnsAllFeesIf0IsProvidedAsParameter() public {
        uint16 protocolFee = 1028; // 00000100 00000100 i.e. 25%
        // swap fee i.e. 0.3% * protocol fee i.e. 25% * input amount i.e. 10000 = 0.075%
        uint256 expectedFees = uint256(10000) * 3000 / 1000000 * 25 / 100;

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            poolManager: poolManager
        });
        poolManager.setProtocolFeeController(IProtocolFeeController(address(feeController)));
        feeController.setSwapFeeForPool(key.toId(), uint16(protocolFee));

        poolManager.initialize(key, SQRT_RATIO_1_1);
        (Pool.Slot0 memory slot0,,,) = poolManager.pools(key.toId());
        assertEq(slot0.protocolFee, protocolFee);

        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams(-120, 120, 10 ether);
        router.modifyPosition(key, params);
        router.swap(
            key,
            IPoolManager.SwapParams(true, 10000, SQRT_RATIO_1_2),
            PoolManagerRouter.SwapTestSettings(true, true)
        );

        assertEq(poolManager.protocolFeesAccrued(currency0), expectedFees);
        assertEq(poolManager.protocolFeesAccrued(currency1), 0);
        assertEq(currency0.balanceOf(address(1)), 0);
        poolManager.collectProtocolFees(address(1), currency0, 0);
        assertEq(currency0.balanceOf(address(1)), expectedFees);
        assertEq(poolManager.protocolFeesAccrued(currency0), 0);
    }

    function testCollectProtocolFees_nativeToken_allowsOwnerToAccumulateFees() public {
        uint16 protocolFee = 1028; // 00000100 00000100 i.e. 25%
        // swap fee i.e. 0.3% * protocol fee i.e. 25% * input amount i.e. 10000 = 0.075%
        uint256 expectedFees = uint256(10000) * 3000 / 1000000 * 25 / 100;
        Currency nativeCurrency = Currency.wrap(address(0));

        PoolKey memory key = PoolKey({
            currency0: nativeCurrency,
            currency1: currency1,
            fee: 3000,
            poolManager: poolManager
        });
        poolManager.setProtocolFeeController(IProtocolFeeController(address(feeController)));
        feeController.setSwapFeeForPool(key.toId(), uint16(protocolFee));

        poolManager.initialize(key, SQRT_RATIO_1_1);
        (Pool.Slot0 memory slot0,,,) = poolManager.pools(key.toId());
        assertEq(slot0.protocolFee, protocolFee);

        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams(-120, 120, 10 ether);
        router.modifyPosition{value: 10 ether}(key, params);
        router.swap{value: 10000}(
            key,
            IPoolManager.SwapParams(true, 10000, SQRT_RATIO_1_2),
            PoolManagerRouter.SwapTestSettings(true, true)
        );

        assertEq(poolManager.protocolFeesAccrued(nativeCurrency), expectedFees);
        assertEq(poolManager.protocolFeesAccrued(currency1), 0);
        assertEq(nativeCurrency.balanceOf(address(1)), 0);
        poolManager.collectProtocolFees(address(1), nativeCurrency, expectedFees);
        assertEq(nativeCurrency.balanceOf(address(1)), expectedFees);
        assertEq(poolManager.protocolFeesAccrued(nativeCurrency), 0);
    }

    function testCollectProtocolFees_nativeToken_returnsAllFeesIf0IsProvidedAsParameter() public {
        uint16 protocolFee = 1028; // 00000100 00000100 i.e. 25%
        // swap fee i.e. 0.3% * protocol fee i.e. 25% * input amount i.e. 10000 = 0.075%
        uint256 expectedFees = uint256(10000) * 3000 / 1000000 * 25 / 100;
        Currency nativeCurrency = Currency.wrap(address(0));

        PoolKey memory key = PoolKey({
            currency0: nativeCurrency,
            currency1: currency1,
            fee: 3000,
            poolManager: poolManager
        });
        poolManager.setProtocolFeeController(IProtocolFeeController(address(feeController)));
        feeController.setSwapFeeForPool(key.toId(), uint16(protocolFee));

        poolManager.initialize(key, SQRT_RATIO_1_1);
        (Pool.Slot0 memory slot0,,,) = poolManager.pools(key.toId());
        assertEq(slot0.protocolFee, protocolFee);

        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams(-120, 120, 10 ether);
        router.modifyPosition{value: 10 ether}(key, params);
        router.swap{value: 10000}(
            key,
            IPoolManager.SwapParams(true, 10000, SQRT_RATIO_1_2),
            PoolManagerRouter.SwapTestSettings(true, true)
        );

        assertEq(poolManager.protocolFeesAccrued(nativeCurrency), expectedFees);
        assertEq(poolManager.protocolFeesAccrued(currency1), 0);
        assertEq(nativeCurrency.balanceOf(address(1)), 0);
        poolManager.collectProtocolFees(address(1), nativeCurrency, 0);
        assertEq(nativeCurrency.balanceOf(address(1)), expectedFees);
        assertEq(poolManager.protocolFeesAccrued(nativeCurrency), 0);
    }

    // function testFuzzUpdateDynamicSwapFee(uint24 _swapFee) public {
    //     vm.assume(_swapFee < FeeLibrary.ONE_HUNDRED_PERCENT_FEE);

    //     PoolKey memory key = PoolKey({
    //         currency0: currency0,
    //         currency1: currency1,
    //         fee: uint24(3000), // 3000 = 0.3%
    //         poolManager: poolManager
    //     });

    //     poolManager.initialize(key, TickMath.MIN_SQRT_RATIO);

    //     (,,, uint24 swapFee) = poolManager.getSlot0(key.toId());
    //     assertEq(swapFee, _swapFee);
    // }

    function tryExecute(address target, bytes memory msgData) external {
        (bool success, bytes memory result) = target.call(msgData);
        if (!success) {
            return;
        }

        assembly {
            revert(add(result, 0x20), mload(result))
        }
    }

    fallback() external payable {}

    receive() external payable {}
}
