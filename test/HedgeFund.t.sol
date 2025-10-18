// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {HedgeFund, Queue} from "../src/HedgeFund.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {SafeCast} from "openzeppelin-contracts/contracts/utils/math/SafeCast.sol";

contract HedgeFundTest is Test {
    using stdStorage for StdStorage;

    uint256 private constant USDT_DECIMALS = 1e6;
    uint256 private constant PRICE_SCALE = 1e18;
    uint256 private constant ASSET_SCALE = 1e12;
    uint64 private constant MANAGEMENT_FEE_WAD = 2e16;
    uint64 private constant PERFORMANCE_FEE_WAD = 2e17;
    uint256 private constant YEAR = 365 days;

    IERC20 internal usdt = IERC20(0xdAC17F958D2ee523a2206206994597C13D831ec7);
    HedgeFund internal fund;
    Queue internal queue;

    address internal owner = makeAddr("owner");
    address internal user = makeAddr("user");

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"), 23_577_777);

        fund = new HedgeFund(
            owner, address(usdt), "Altitude Hedge Fund Share", "AHFS", "Altitude Hedge Fund Queue", "AHFQ"
        );
        queue = fund.QUEUE();

        _setBalance(user, 1000 * USDT_DECIMALS);
        _setBalance(owner, 1000 * USDT_DECIMALS);

        _setAllowance(user, address(fund), type(uint256).max);
        _setAllowance(owner, address(fund), type(uint256).max);
    }

    function testDepositAndClaim() public {
        uint256 amount = 100 * USDT_DECIMALS;

        vm.prank(user);
        fund.deposit(amount);

        assertEq(usdt.balanceOf(address(fund)), amount);
        assertEq(fund.balanceOf(user), 0);
        assertEq(fund.pendingDeposits(), amount);
        assertEq(queue.balanceOf(user), 1);

        uint256 ownerStart = usdt.balanceOf(owner);

        vm.prank(owner);
        fund.contributeEpoch(0);
        assertEq(usdt.balanceOf(owner), ownerStart + amount);

        vm.prank(user);
        fund.claim();

        uint256 expectedShares = amount * ASSET_SCALE;
        assertEq(fund.balanceOf(user), expectedShares);
        assertEq(fund.pendingDeposits(), 0);
        assertEq(queue.balanceOf(user), 0);
    }

    function testWithdrawFlow() public {
        uint256 amount = 200 * USDT_DECIMALS;
        uint256 startingBalance = usdt.balanceOf(user);

        vm.prank(user);
        fund.deposit(amount);

        vm.prank(owner);
        fund.contributeEpoch(0);

        vm.prank(user);
        fund.claim();

        uint256 shares = fund.balanceOf(user);
        uint256 withdrawShares = shares / 2;

        vm.prank(user);
        fund.withdraw(withdrawShares);

        assertEq(fund.balanceOf(user), shares - withdrawShares);
        assertEq(fund.balanceOf(address(fund)), withdrawShares);
        assertEq(queue.balanceOf(user), 1);

        vm.prank(user);
        fund.claim();
        assertEq(usdt.balanceOf(user), startingBalance - amount);

        uint256 ownerStart = usdt.balanceOf(owner);
        (, int256 deltaPreview,,) = fund.preview(250 * USDT_DECIMALS);

        vm.prank(owner);
        fund.contributeEpoch(250 * USDT_DECIMALS);

        uint256 ownerAfter = usdt.balanceOf(owner);

        if (deltaPreview > 0) {
            uint256 expectedDelta = SafeCast.toUint256(deltaPreview);
            assertEq(ownerStart - ownerAfter, expectedDelta);
        } else if (deltaPreview < 0) {
            uint256 expectedDelta = SafeCast.toUint256(-deltaPreview);
            assertEq(ownerAfter - ownerStart, expectedDelta);
        } else {
            assertEq(ownerAfter, ownerStart);
        }

        vm.prank(user);
        fund.claim();

        (uint256 sharePrice,) = fund.epochs(fund.currentEpoch());
        uint256 value18 = (withdrawShares * sharePrice) / 1e18;
        uint256 expectedPayout = value18 / ASSET_SCALE;

        assertEq(usdt.balanceOf(user), startingBalance - amount + expectedPayout);
        assertEq(fund.balanceOf(address(fund)), 0);
        assertEq(queue.balanceOf(user), 0);
        assertEq(fund.pendingWithdraw(), 0);
    }

    function testClaimDepositsThenWithdraws() public {
        uint256 baseDeposit = 100 * USDT_DECIMALS;

        vm.prank(user);
        fund.deposit(baseDeposit);

        vm.prank(owner);
        fund.contributeEpoch(0);

        vm.prank(user);
        fund.claim();

        uint256 shares = fund.balanceOf(user);
        uint256 withdrawShares = shares / 2;

        vm.prank(user);
        fund.withdraw(withdrawShares);

        uint256 secondDeposit = 50 * USDT_DECIMALS;

        vm.prank(user);
        fund.deposit(secondDeposit);

        vm.prank(owner);
        fund.contributeEpoch(150 * USDT_DECIMALS);

        vm.recordLogs();
        vm.prank(user);
        fund.claim();

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 depositSig = keccak256("DepositClaimed(address,uint256,uint256,uint256,uint64)");
        bytes32 withdrawSig = keccak256("WithdrawClaimed(address,uint256,uint256,uint256,uint64)");

        bytes32[] memory order = new bytes32[](2);
        uint256 found;
        for (uint256 i; i < entries.length; i++) {
            if (entries[i].topics[0] == depositSig || entries[i].topics[0] == withdrawSig) {
                order[found] = entries[i].topics[0];
                found++;
                if (found == 2) break;
            }
        }
        assertEq(found, 2);
        assertEq(order[0], depositSig);
        assertEq(order[1], withdrawSig);
    }

    function testPreviewOwner() public {
        uint256 amount = 100 * USDT_DECIMALS;

        vm.prank(user);
        fund.deposit(amount);

        (, int256 deltaBefore,,) = fund.preview(amount);
        int256 expectedNegative = -SafeCast.toInt256(amount);
        assertEq(deltaBefore, expectedNegative);

        vm.prank(owner);
        fund.contributeEpoch(0);

        vm.prank(user);
        fund.claim();

        uint256 shares = fund.balanceOf(user);
        uint256 withdrawShares = shares / 2;

        vm.prank(user);
        fund.withdraw(withdrawShares);

        (, int256 deltaAfter,,) = fund.preview(amount);
        int256 expectedPositive = SafeCast.toInt256(amount / 2);
        assertEq(deltaAfter, expectedPositive);
    }

    function testManagementFeeAccruesOverTime() public {
        uint256 amount = 100 * USDT_DECIMALS;

        vm.prank(user);
        fund.deposit(amount);

        vm.prank(owner);
        fund.contributeEpoch(0);

        vm.prank(user);
        fund.claim();

        uint256 supply = fund.totalSupply();
        assertEq(supply, amount * ASSET_SCALE);

        uint64 epochBefore = fund.currentEpoch();
        uint256 interval = 1 weeks;
        vm.warp(block.timestamp + interval);

        uint256 nav = amount;
        uint256 managementRate = Math.mulDiv(MANAGEMENT_FEE_WAD, interval, YEAR);
        (
            uint256 expectedSharePrice,
            uint256 expectedManagementShares,
            uint256 expectedManagementValue,
            uint256 supplyAfterManagement
        ) = _computeManagementOutcome(supply, nav, managementRate);

        uint64 nextEpoch = epochBefore + 1;
        uint32 expectedTimestamp = SafeCast.toUint32(block.timestamp);
        uint256 expectedHighWater = PRICE_SCALE;

        vm.expectEmit(true, false, false, true, address(fund));
        emit HedgeFund.EpochContributed(
            nextEpoch,
            nav,
            expectedSharePrice,
            expectedHighWater,
            expectedTimestamp,
            0,
            expectedManagementValue,
            0,
            expectedManagementShares,
            0
        );

        vm.prank(owner);
        fund.contributeEpoch(nav);

        (uint256 sharePriceAfter,) = fund.epochs(fund.currentEpoch());
        assertEq(fund.currentEpoch(), nextEpoch);
        assertEq(sharePriceAfter, expectedSharePrice);
        assertEq(fund.balanceOf(owner), expectedManagementShares);
        assertEq(fund.totalSupply(), supplyAfterManagement);

        uint256 investorValue = Math.mulDiv(supply, sharePriceAfter, PRICE_SCALE) / ASSET_SCALE;
        assertApproxEqAbs(investorValue, nav - expectedManagementValue, 1);
    }

    function testPerformanceFeeOnProfit() public {
        uint256 amount = 100 * USDT_DECIMALS;

        vm.prank(user);
        fund.deposit(amount);

        vm.prank(owner);
        fund.contributeEpoch(0);

        vm.prank(user);
        fund.claim();

        uint256 supply = fund.totalSupply();
        uint64 epochBefore = fund.currentEpoch();

        uint256 nav = 150 * USDT_DECIMALS;
        (
            uint256 expectedSharePrice,
            uint256 expectedPerformanceShares,
            uint256 expectedPerformanceValue,
            uint256 supplyAfterPerformance
        ) = _computePerformanceOutcome(supply, PRICE_SCALE, nav);

        uint64 nextEpoch = epochBefore + 1;
        uint32 expectedTimestamp = SafeCast.toUint32(block.timestamp);
        uint256 expectedHighWater = expectedSharePrice;

        vm.expectEmit(true, false, false, true, address(fund));
        emit HedgeFund.EpochContributed(
            nextEpoch,
            nav,
            expectedSharePrice,
            expectedHighWater,
            expectedTimestamp,
            0,
            0,
            expectedPerformanceValue,
            0,
            expectedPerformanceShares
        );

        vm.prank(owner);
        fund.contributeEpoch(nav);

        (uint256 sharePriceAfter,) = fund.epochs(fund.currentEpoch());
        assertEq(fund.currentEpoch(), nextEpoch);
        assertEq(sharePriceAfter, expectedSharePrice);
        assertEq(fund.balanceOf(owner), expectedPerformanceShares);
        assertEq(fund.totalSupply(), supplyAfterPerformance);

        uint256 investorValue = Math.mulDiv(supply, sharePriceAfter, PRICE_SCALE) / ASSET_SCALE;
        assertApproxEqAbs(investorValue, nav - expectedPerformanceValue, 1);
    }

    function testHighWaterMarkGatesPerformanceFee() public {
        vm.prank(owner);
        fund.setFees(MANAGEMENT_FEE_WAD, PERFORMANCE_FEE_WAD);

        uint256 amount = 100 * USDT_DECIMALS;
        vm.prank(user);
        fund.deposit(amount);

        vm.prank(owner);
        fund.contributeEpoch(0);

        vm.prank(user);
        fund.claim();

        assertEq(fund.highWaterMark(), PRICE_SCALE);
        assertEq(fund.balanceOf(owner), 0);

        vm.prank(owner);
        fund.contributeEpoch(150 * USDT_DECIMALS);

        uint256 afterFirstProfit = fund.balanceOf(owner);
        assertGt(afterFirstProfit, 0);
        uint256 recordedHighWater = fund.highWaterMark();
        (uint256 sharePriceAfterProfit,) = fund.epochs(fund.currentEpoch());
        assertEq(recordedHighWater, sharePriceAfterProfit);

        vm.prank(owner);
        fund.contributeEpoch(120 * USDT_DECIMALS);
        assertEq(fund.balanceOf(owner), afterFirstProfit);
        assertEq(fund.highWaterMark(), recordedHighWater);

        vm.prank(owner);
        fund.contributeEpoch(140 * USDT_DECIMALS);
        assertEq(fund.balanceOf(owner), afterFirstProfit);
        assertEq(fund.highWaterMark(), recordedHighWater);

        vm.prank(owner);
        fund.contributeEpoch(200 * USDT_DECIMALS);
        uint256 finalShares = fund.balanceOf(owner);
        assertGt(finalShares, afterFirstProfit);
        (uint256 latestSharePrice,) = fund.epochs(fund.currentEpoch());
        assertEq(fund.highWaterMark(), latestSharePrice);
    }

    function _computeManagementOutcome(uint256 supply, uint256 nav, uint256 rate)
        internal
        pure
        returns (uint256 sharePrice, uint256 mintedShares, uint256 mintedValue, uint256 supplyAfter)
    {
        if (rate >= PRICE_SCALE) {
            rate = PRICE_SCALE - 1;
        }

        sharePrice = Math.mulDiv(nav * ASSET_SCALE, PRICE_SCALE, supply);
        mintedShares = 0;
        supplyAfter = supply;

        if (sharePrice > 0 && rate > 0) {
            uint256 scaleAfter = PRICE_SCALE - rate;
            sharePrice = Math.mulDiv(sharePrice, scaleAfter, PRICE_SCALE);
            mintedShares = Math.mulDiv(supplyAfter, rate, scaleAfter);
            supplyAfter += mintedShares;
        }

        mintedValue = _sharesToAssetsTest(mintedShares, sharePrice);
        return (sharePrice, mintedShares, mintedValue, supplyAfter);
    }

    function _computePerformanceOutcome(uint256 supply, uint256 baseSharePrice, uint256 nav)
        internal
        pure
        returns (uint256 sharePrice, uint256 mintedShares, uint256 mintedValue, uint256 supplyAfter)
    {
        sharePrice = Math.mulDiv(nav * ASSET_SCALE, PRICE_SCALE, supply);
        mintedShares = 0;
        supplyAfter = supply;

        if (sharePrice > baseSharePrice) {
            uint256 profitPerShare = sharePrice - baseSharePrice;
            uint256 feePerShare = Math.mulDiv(profitPerShare, PERFORMANCE_FEE_WAD, PRICE_SCALE);

            if (feePerShare >= sharePrice) {
                feePerShare = sharePrice == 0 ? 0 : sharePrice - 1;
            }

            if (feePerShare > 0) {
                sharePrice -= feePerShare;
                mintedShares = Math.mulDiv(supplyAfter, feePerShare, sharePrice);
                supplyAfter += mintedShares;
            }
        }

        mintedValue = _sharesToAssetsTest(mintedShares, sharePrice);
        return (sharePrice, mintedShares, mintedValue, supplyAfter);
    }

    function _sharesToAssetsTest(uint256 shares, uint256 sharePrice) internal pure returns (uint256) {
        if (shares == 0 || sharePrice == 0) {
            return 0;
        }
        return Math.mulDiv(shares, sharePrice, PRICE_SCALE * ASSET_SCALE);
    }

    function _setBalance(address to, uint256 amount) internal {
        deal(address(usdt), to, amount, false);
    }

    function _setAllowance(address _owner, address _spender, uint256 _amount) internal {
        uint256 slot =
            stdstore.target(address(usdt)).sig("allowance(address,address)").with_key(_owner).with_key(_spender).find();
        vm.store(address(usdt), bytes32(slot), bytes32(_amount));
    }
}
