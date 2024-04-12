// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TokenFixture} from "../helpers/TokenFixture.sol";
import {PoolKey} from "../../src/types/PoolKey.sol";
import {FeeLibrary} from "../../src/libraries/FeeLibrary.sol";
import {Deployers} from "../helpers/Deployers.sol";
import {OxionStorage} from "../../src/OxionStorage.sol";
import {PoolManager} from "../../src/PoolManager.sol";
import {PoolParametersHelper} from "../../src/libraries/PoolParametersHelper.sol";
import {IFees} from "../../src/interfaces/IFees.sol";
import {IPoolManager} from "../../src/interfaces/IPoolManager.sol";
import {PoolManagerRouter} from "../helpers/PoolManagerRouter.sol";
import {Currency} from "../../src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "../../src/types/PoolId.sol";

contract PoolSwapFeeTest is Deployers, TokenFixture, Test {
    using PoolIdLibrary for PoolKey;

    OxionStorage oxionStorage;
    PoolManager poolManager;
    PoolManagerRouter router;

    PoolKey dynamicFeeKey;
    PoolKey staticFeeKey;

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

    function setUp() public {
        initializeTokens();
        (oxionStorage, poolManager) = createFreshManager();
        router = new PoolManagerRouter(oxionStorage, poolManager);
        IERC20(Currency.unwrap(currency0)).approve(address(router), 10 ether);
        IERC20(Currency.unwrap(currency1)).approve(address(router), 10 ether);

        staticFeeKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            poolManager: poolManager,
            // 50%
            fee: FeeLibrary.ONE_HUNDRED_PERCENT_FEE / 2
        });
    }

    // function testPoolInitializeFailsWithTooLargeFee() public {
    //     vm.expectRevert(IFees.FeeTooLarge.selector);
    //     poolManager.initialize(dynamicFeeKey, SQRT_RATIO_1_1);
    //     {
    //         vm.expectRevert(IFees.FeeTooLarge.selector);
    //         staticFeeKey.fee = FeeLibrary.ONE_HUNDRED_PERCENT_FEE;
    //         poolManager.initialize(staticFeeKey, SQRT_RATIO_1_1);
    //     }
    // }

    function testSwapWorks() public {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            poolManager: poolManager,
            fee: 500
        });

        poolManager.initialize(key, SQRT_RATIO_1_1);

        IPoolManager.ModifyLiquidityParams memory modifyPositionParams =
            IPoolManager.ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1 ether});
        router.modifyPosition(key, modifyPositionParams);

        vm.expectEmit(true, true, true, true);
        emit Swap(
            key.toId(),
            address(router),
            100,
            -98,
            79228162514264329749955861424,
            1000000000000000000,
            -1,
            500,
            0
        );

        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100, sqrtPriceLimitX96: SQRT_RATIO_1_2});

        PoolManagerRouter.SwapTestSettings memory testSettings =
            PoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true});

        router.swap(key, params, testSettings);
    }

    function testSwapWorksWithStaticFee() public {
        // starts from price = 1
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            poolManager: poolManager,
            fee: 500
        });

        poolManager.initialize(key, SQRT_RATIO_1_1);

        IPoolManager.ModifyLiquidityParams memory modifyPositionParams =
            IPoolManager.ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1 ether});
        router.modifyPosition(key, modifyPositionParams);

        vm.expectEmit(true, true, true, true);
        emit Swap(
            key.toId(),
            address(router),
            100,
            -98,
            79228162514264329749955861424,
            1000000000000000000,
            -1,
            500,
            0
        );

        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100, sqrtPriceLimitX96: SQRT_RATIO_1_2});

        PoolManagerRouter.SwapTestSettings memory testSettings =
            PoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true});

        router.swap(key, params, testSettings);
    }

   
}
