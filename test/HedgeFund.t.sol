// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {HedgeFund, Queue} from "../src/HedgeFund.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract HedgeFundTest is Test {
    using stdStorage for StdStorage;

    uint256 private constant USDT_DECIMALS = 1e6;
    uint256 private constant SHARES_SCALE = 1e12;

    IERC20 internal usdt = IERC20(0xdAC17F958D2ee523a2206206994597C13D831ec7);
    HedgeFund internal fund;
    Queue internal queue;

    address internal owner = makeAddr("owner");
    address internal user = makeAddr("user");

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"), 23_577_777);

        fund = new HedgeFund(owner, address(usdt));
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

        uint256 expectedShares = amount * SHARES_SCALE;
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
        (, int256 deltaPreview) = fund.preview(250 * USDT_DECIMALS);

        vm.prank(owner);
        fund.contributeEpoch(250 * USDT_DECIMALS);

        uint256 ownerAfter = usdt.balanceOf(owner);

        if (deltaPreview > 0) {
            assertEq(ownerStart - ownerAfter, uint256(deltaPreview));
        } else if (deltaPreview < 0) {
            assertEq(ownerAfter - ownerStart, uint256(-deltaPreview));
        } else {
            assertEq(ownerAfter, ownerStart);
        }

        vm.prank(user);
        fund.claim();

        (uint256 sharePrice,) = fund.epochs(fund.currentEpoch());
        uint256 value18 = (withdrawShares * sharePrice) / 1e18;
        uint256 expectedPayout = value18 / SHARES_SCALE;

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
        bytes32 depositSig = keccak256("DepositClaimed(address,uint256,uint256,uint256,uint256)");
        bytes32 withdrawSig = keccak256("WithdrawClaimed(address,uint256,uint256,uint256,uint256)");

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

        (, int256 deltaBefore) = fund.preview(amount);
        assertEq(deltaBefore, -int256(amount));

        vm.prank(owner);
        fund.contributeEpoch(0);

        vm.prank(user);
        fund.claim();

        uint256 shares = fund.balanceOf(user);
        uint256 withdrawShares = shares / 2;

        vm.prank(user);
        fund.withdraw(withdrawShares);

        (, int256 deltaAfter) = fund.preview(amount);
        assertEq(deltaAfter, int256(amount / 2));
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
