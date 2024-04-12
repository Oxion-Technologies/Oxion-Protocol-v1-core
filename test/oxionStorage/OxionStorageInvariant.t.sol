// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import "forge-std/Test.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {OxionStorage} from "../../src/OxionStorage.sol";
import {BalanceDelta, toBalanceDelta} from "../../src/types/BalanceDelta.sol";
import {IPoolManager} from "../../src/interfaces/IPoolManager.sol";
import {Currency} from "../../src/types/Currency.sol";
import {PoolKey} from "../../src/types/PoolKey.sol";
import {IOxionStorage} from "../../src/interfaces/IOxionStorage.sol";
import {SafeCast} from "../../src/libraries/SafeCast.sol";

contract OxionPoolManager is Test {
    using SafeCast for uint128;

    uint256 MAX_TOKEN_BALANCE = uint128(type(int128).max);
    MockERC20 public token0;
    MockERC20 public token1;
    Currency public currency0;
    Currency public currency1;

    uint256 public totalMintedCurrency0;
    uint256 public totalMintedCurrency1;

    uint256 public totalFeeCollected0;
    uint256 public totalFeeCollected1;

    enum ActionType {
        Take,
        Settle,
        SettleAndMintRefund,
        SettleFor,
        Mint,
        Burn
    }

    struct Action {
        ActionType actionType;
        uint128 amt0;
        uint128 amt1;
    }

    PoolKey poolKey;
    OxionStorage oxionStorage;

    constructor(OxionStorage _oxionStorage, MockERC20 _token0, MockERC20 _token1) {
        oxionStorage = _oxionStorage;
        token0 = _token0;
        token1 = _token1;
        currency0 = Currency.wrap(address(token0));
        currency1 = Currency.wrap(address(token1));

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            poolManager: IPoolManager(address(this)),
            fee: 0
        });
    }

    /// @dev In take case, assume user remove liquidity and take token out of oxionStorage
    function take(uint256 amt0, uint256 amt1) public {
        amt0 = bound(amt0, 0, MAX_TOKEN_BALANCE);
        amt1 = bound(amt1, 0, MAX_TOKEN_BALANCE);

        // make sure the oxionStorage has enough liquidity at very beginning
        settle(amt0, amt1);

        oxionStorage.lock(abi.encode(Action(ActionType.Take, uint128(amt0), uint128(amt1))));
    }

    /// @dev In settle case, assume user add liquidity and paying to the oxionStorage
    function settle(uint256 amt0, uint256 amt1) public {
        amt0 = bound(amt0, 0, MAX_TOKEN_BALANCE);
        amt1 = bound(amt1, 0, MAX_TOKEN_BALANCE);

        // mint token to oxionPoolManager, so oxionPoolManager can pay to the oxionStorage
        token0.mint(address(this), amt0);
        token1.mint(address(this), amt1);
        oxionStorage.lock(abi.encode(Action(ActionType.Settle, uint128(amt0), uint128(amt1))));
    }

    /// @dev In settleAndRefund case, assume user add liquidity and paying to the oxionStorage
    ///      but theres another folk who minted extra token to the oxionStorage
    function settleAndMintRefund(uint256 amt0, uint256 amt1, bool sendToOxionStorage) public {
        amt0 = bound(amt0, 0, MAX_TOKEN_BALANCE - 1 ether);
        amt1 = bound(amt1, 0, MAX_TOKEN_BALANCE - 1 ether);

        // someone send some token directly to oxionStorage
        if (sendToOxionStorage) token0.mint(address(oxionStorage), 1 ether);

        // mint token to oxionPoolManager, so oxionPoolManager can pay to the oxionStorage
        token0.mint(address(this), amt0);
        token1.mint(address(this), amt1);
        oxionStorage.lock(abi.encode(Action(ActionType.SettleAndMintRefund, uint128(amt0), uint128(amt1))));
    }

    /// @dev In settleFor case, assume user is paying for hook
    function settleFor(uint256 amt0, uint256 amt1) public {
        amt0 = bound(amt0, 0, MAX_TOKEN_BALANCE);
        amt1 = bound(amt1, 0, MAX_TOKEN_BALANCE);

        // make sure the oxionStorage has enough liquidity at very beginning
        settle(amt0, amt1);

        token0.mint(address(this), amt0);
        token1.mint(address(this), amt1);
        oxionStorage.lock(abi.encode(Action(ActionType.SettleFor, uint128(amt0), uint128(amt1))));
    }

    /// @dev In mint case, assume user remove liquidity and mint nft as reciept
    function mint(uint256 amt0, uint256 amt1) public {
        amt0 = bound(amt0, 0, MAX_TOKEN_BALANCE);
        amt1 = bound(amt1, 0, MAX_TOKEN_BALANCE);

        // make sure the oxionStorage has enough liquidity at very beginning
        settle(amt0, amt1);

        oxionStorage.lock(abi.encode(Action(ActionType.Mint, uint128(amt0), uint128(amt1))));
    }

    /// @dev In burn case, assume user already have minted NFT and want to remove nft
    function burn(uint256 amt0, uint256 amt1) public {
        amt0 = bound(amt0, 0, MAX_TOKEN_BALANCE);
        amt1 = bound(amt1, 0, MAX_TOKEN_BALANCE);

        // pre-req oxionPoolManager minted receipt token
        mint(amt0, amt1);

        // oxionPoolManager burn the nft
        oxionStorage.lock(abi.encode(Action(ActionType.Burn, uint128(amt0), uint128(amt1))));
    }

    /// @dev In collectFee case, assume user already have minted NFT and want to remove nft
    function collectFee(uint256 amt0, uint256 amt1, uint256 feeToCollect0, uint256 feeToCollect1) public {
        amt0 = bound(amt0, 0, MAX_TOKEN_BALANCE);
        amt1 = bound(amt1, 0, MAX_TOKEN_BALANCE);

        feeToCollect0 = bound(feeToCollect0, 0, amt0);
        feeToCollect1 = bound(feeToCollect1, 0, amt1);

        // make sure the oxionStorage has enough liquidity at very beginning
        settle(amt0, amt1);

        oxionStorage.collectFee(currency0, feeToCollect0, makeAddr("protocolFeeRecipient"));
        oxionStorage.collectFee(currency1, feeToCollect1, makeAddr("protocolFeeRecipient"));
        totalFeeCollected0 += feeToCollect0;
        totalFeeCollected1 += feeToCollect1;
    }

    /// @dev positive balanceDelta: oxionPoolManager owes to oxionStorage
    ///      negative balanceDelta: oxionStorage owes to oxionPoolManager
    function lockAcquired(bytes calldata data) external returns (bytes memory) {
        Action memory action = abi.decode(data, (Action));

        if (action.actionType == ActionType.Take) {
            BalanceDelta delta = toBalanceDelta(-(int128(action.amt0)), -(int128(action.amt1)));
            oxionStorage.accountPoolBalanceDelta(poolKey, delta, address(this));

            oxionStorage.take(currency0, address(this), action.amt0);
            oxionStorage.take(currency1, address(this), action.amt1);
        } else if (action.actionType == ActionType.Mint) {
            BalanceDelta delta = toBalanceDelta(-(int128(action.amt0)), -(int128(action.amt1)));
            oxionStorage.accountPoolBalanceDelta(poolKey, delta, address(this));

            oxionStorage.mint(currency0, address(this), action.amt0);
            oxionStorage.mint(currency1, address(this), action.amt1);
            totalMintedCurrency0 += action.amt0;
            totalMintedCurrency1 += action.amt1;
        } else if (action.actionType == ActionType.Settle) {
            BalanceDelta delta = toBalanceDelta(int128(action.amt0), int128(action.amt1));
            oxionStorage.accountPoolBalanceDelta(poolKey, delta, address(this));

            token0.transfer(address(oxionStorage), action.amt0);
            token1.transfer(address(oxionStorage), action.amt1);

            oxionStorage.settle(currency0);
            oxionStorage.settle(currency1);
        } else if (action.actionType == ActionType.SettleAndMintRefund) {
            BalanceDelta delta = toBalanceDelta(int128(action.amt0), int128(action.amt1));
            oxionStorage.accountPoolBalanceDelta(poolKey, delta, address(this));

            token0.transfer(address(oxionStorage), action.amt0);
            token1.transfer(address(oxionStorage), action.amt1);

            (, uint256 refund0) = oxionStorage.settleAndMintRefund(currency0, address(this));
            (, uint256 refund1) = oxionStorage.settleAndMintRefund(currency1, address(this));

            totalMintedCurrency0 += refund0;
            totalMintedCurrency1 += refund1;
        } else if (action.actionType == ActionType.SettleFor) {
            // hook cash out the fee ahead
            BalanceDelta delta = toBalanceDelta(int128(action.amt0), int128(action.amt1));
            oxionStorage.accountPoolBalanceDelta(poolKey, delta, makeAddr("hook"));

            // transfer hook's fee to user
            oxionStorage.settleFor(currency0, makeAddr("hook"), action.amt0);
            oxionStorage.settleFor(currency1, makeAddr("hook"), action.amt1);

            // handle user's own deltas
            token0.transfer(address(oxionStorage), action.amt0);
            token1.transfer(address(oxionStorage), action.amt1);

            oxionStorage.settle(currency0);
            oxionStorage.settle(currency1);
        } else if (action.actionType == ActionType.Burn) {
            BalanceDelta delta = toBalanceDelta(int128(action.amt0), int128(action.amt1));
            oxionStorage.accountPoolBalanceDelta(poolKey, delta, address(this));

            oxionStorage.burn(currency0, action.amt0);
            oxionStorage.burn(currency1, action.amt1);
            totalMintedCurrency0 -= action.amt0;
            totalMintedCurrency1 -= action.amt1;
        }

        return "";
    }
}

contract OxionStorageInvariant is Test, GasSnapshot {
    OxionPoolManager public oxionPoolManager;
    OxionStorage public oxionStorage;
    MockERC20 token0;
    MockERC20 token1;

    function setUp() public {
        oxionStorage = new OxionStorage();
        token0 = new MockERC20("TestA", "A", 18);
        token1 = new MockERC20("TestB", "B", 18);
        (token0, token1) = address(token0) > address(token1) ? (token1, token0) : (token0, token1);

        oxionPoolManager = new OxionPoolManager(oxionStorage, token0, token1);
        oxionStorage.registerPoolManager(address(oxionPoolManager));

        // Only call oxionPoolManager, otherwise all other contracts deployed in setUp will be called
        targetContract(address(oxionPoolManager));

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = oxionPoolManager.take.selector;
        selectors[1] = oxionPoolManager.mint.selector;
        selectors[2] = oxionPoolManager.settle.selector;
        selectors[3] = oxionPoolManager.burn.selector;
        selectors[4] = oxionPoolManager.settleFor.selector;
        selectors[5] = oxionPoolManager.collectFee.selector;
        selectors[6] = oxionPoolManager.settleAndMintRefund.selector;
        targetSelector(FuzzSelector({addr: address(oxionPoolManager), selectors: selectors}));
    }

    function invariant_TokenbalanceInOxionStorageGeReserveOfOxionStorage() public {
        (uint256 amt0Bal, uint256 amt1Bal) = getTokenBalanceInOxionStorage();

        assertGe(amt0Bal, oxionStorage.reservesOfStorage(oxionPoolManager.currency0()));
        assertGe(amt1Bal, oxionStorage.reservesOfStorage(oxionPoolManager.currency1()));
    }

    function invariant_TokenbalanceInOxionStorageGeReserveOfPoolManagerPlusSurplusToken() public {
        (uint256 amt0Bal, uint256 amt1Bal) = getTokenBalanceInOxionStorage();

        uint256 totalMintedCurrency0 = oxionPoolManager.totalMintedCurrency0();
        uint256 totalMintedCurrency1 = oxionPoolManager.totalMintedCurrency1();

        IPoolManager manager = IPoolManager(address(oxionPoolManager));
        assertGe(amt0Bal, oxionStorage.reservesOfPoolManager(manager, oxionPoolManager.currency0()) + totalMintedCurrency0);
        assertGe(amt1Bal, oxionStorage.reservesOfPoolManager(manager, oxionPoolManager.currency1()) + totalMintedCurrency1);
    }

    function invariant_ReserveOfOxionStorageEqReserveOfPoolManagerPlusSurplusToken() public {
        uint256 totalMintedCurrency0 = oxionPoolManager.totalMintedCurrency0();
        uint256 totalMintedCurrency1 = oxionPoolManager.totalMintedCurrency1();

        IPoolManager manager = IPoolManager(address(oxionPoolManager));
        assertEq(
            oxionStorage.reservesOfStorage(oxionPoolManager.currency0()),
            oxionStorage.reservesOfPoolManager(manager, oxionPoolManager.currency0()) + totalMintedCurrency0
        );
        assertEq(
            oxionStorage.reservesOfStorage(oxionPoolManager.currency1()),
            oxionStorage.reservesOfPoolManager(manager, oxionPoolManager.currency1()) + totalMintedCurrency1
        );
    }

    function invariant_LockDataLengthZero() public {
        uint256 nonZeroDeltaCount = oxionStorage.getUnsettledDeltasCount();
        assertEq(nonZeroDeltaCount, 0);
    }

    function invariant_Locker() public {
        address locker = oxionStorage.getLocker();
        assertEq(locker, address(0));
    }

    function invariant_TotalMintedCurrency() public {
        uint256 totalMintedCurrency0 = oxionPoolManager.totalMintedCurrency0();
        uint256 totalMintedCurrency1 = oxionPoolManager.totalMintedCurrency1();

        assertEq(totalMintedCurrency0, oxionStorage.balanceOf(address(oxionPoolManager), oxionPoolManager.currency0()));
        assertEq(totalMintedCurrency1, oxionStorage.balanceOf(address(oxionPoolManager), oxionPoolManager.currency1()));
    }

    function invariant_TotalFeeCollected() public {
        uint256 totalFeeCollected0 = oxionPoolManager.totalFeeCollected0();
        uint256 totalFeeCollected1 = oxionPoolManager.totalFeeCollected1();

        assertEq(totalFeeCollected0, token0.balanceOf(makeAddr("protocolFeeRecipient")));
        assertEq(totalFeeCollected1, token1.balanceOf(makeAddr("protocolFeeRecipient")));
    }

    function invariant_TokenBalanceInOxionStorageGeMinted() public {
        (uint256 amt0Bal, uint256 amt1Bal) = getTokenBalanceInOxionStorage();

        assertGe(amt0Bal, oxionStorage.balanceOf(address(oxionPoolManager), oxionPoolManager.currency0()));
        assertGe(amt1Bal, oxionStorage.balanceOf(address(oxionPoolManager), oxionPoolManager.currency1()));
    }

    function getTokenBalanceInOxionStorage() internal view returns (uint256 amt0, uint256 amt1) {
        amt0 = token0.balanceOf(address(oxionStorage));
        amt1 = token1.balanceOf(address(oxionStorage));
    }
}
