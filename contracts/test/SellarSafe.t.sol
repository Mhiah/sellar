// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "./Base.t.sol";
import {SellarSafe} from "../src/SellarSafe.sol";
import {SellarShield} from "../src/SellarShield.sol";

contract SellarSafeTest is Base {
    // ------------------------------------------------ the happy path

    function test_TrustedPayeeWithinLimitsPaysAtOnce() public {
        (bool paid,) = _request(vendor, 40e18);
        assertTrue(paid);
        assertEq(musd.balanceOf(vendor), 40e18);
        uint256 fee = 40e18 * FEE_BPS / 10_000;
        (,,,,,,, uint256 bal,) = safe.accounts(ada);
        assertEq(bal, 5_000e18 - 40e18 - fee);
        assertEq(shield.fundLiquid(), fee);
        assertEq(shield.receiptCount(), 1);
    }

    // ------------------------------------------------ the attack the product exists for

    function test_PoisonedInvoiceAddressIsHeldNotPaid() public {
        (bool paid, uint256 id) = _request(scammer, 40e18);
        assertFalse(paid);
        assertEq(musd.balanceOf(scammer), 0);
        (,,,, uint32 reasons, SellarSafe.HoldState state,) = safe.holds(id);
        assertEq(reasons, safe.R_UNKNOWN_PAYEE());
        assertEq(uint8(state), uint8(SellarSafe.HoldState.Pending));
    }

    function test_AgentCannotApproveItsOwnHold() public {
        (, uint256 id) = _request(scammer, 40e18);
        vm.prank(agent);
        vm.expectRevert(SellarSafe.NotOwner.selector);
        safe.approve(id, true);
    }

    function test_StrangerCannotApproveOrReject() public {
        (, uint256 id) = _request(scammer, 40e18);
        vm.startPrank(ben);
        vm.expectRevert(SellarSafe.NotOwner.selector);
        safe.approve(id, true);
        vm.expectRevert(SellarSafe.NotOwner.selector);
        safe.reject(id);
        vm.stopPrank();
    }

    function test_AgentCannotWithdrawTrustOrConfigure() public {
        vm.startPrank(agent);
        vm.expectRevert(SellarSafe.InsufficientBalance.selector);
        safe.withdraw(1e18);
        // These act on the agent's own (empty) account, never on ada's.
        safe.trust(scammer);
        safe.configure(agent, type(uint128).max, type(uint128).max, 0, 0);
        vm.stopPrank();
        assertEq(safe.trustedAt(ada, scammer), 0);
        (bool paid,) = _request(scammer, 40e18);
        assertFalse(paid);
    }

    function test_OnlyTheAgentCanRequest() public {
        vm.prank(ben);
        vm.expectRevert(SellarSafe.NotAgent.selector);
        safe.request(ada, vendor, 1e18, bytes32(0), false);
    }

    // ------------------------------------------------ approve / reject

    function test_OwnerApprovesExactPaymentOnce() public {
        (, uint256 id) = _request(ben, 40e18);
        vm.prank(ada);
        safe.approve(id, false);
        assertEq(musd.balanceOf(ben), 40e18);
        vm.prank(ada);
        vm.expectRevert(SellarSafe.NotPending.selector);
        safe.approve(id, false);
    }

    function test_RejectedHoldCannotBeApproved() public {
        (, uint256 id) = _request(ben, 40e18);
        vm.startPrank(ada);
        safe.reject(id);
        vm.expectRevert(SellarSafe.NotPending.selector);
        safe.approve(id, false);
        vm.stopPrank();
        assertEq(musd.balanceOf(ben), 0);
    }

    function test_HoldExpires() public {
        (, uint256 id) = _request(ben, 40e18);
        vm.warp(block.timestamp + HOLD_TTL + 1);
        vm.prank(ada);
        vm.expectRevert(SellarSafe.HoldExpired.selector);
        safe.approve(id, false);
    }

    // ------------------------------------------------ limits and cooldown

    function test_OverPerPaymentLimitIsHeld() public {
        (bool paid, uint256 id) = _request(vendor, 101e18);
        assertFalse(paid);
        (,,,, uint32 reasons,,) = safe.holds(id);
        assertEq(reasons, safe.R_OVER_PAYMENT_LIMIT());
    }

    function test_DailyLimitHoldsThenResetsNextDay() public {
        for (uint256 i; i < 3; i++) {
            (bool ok,) = _request(vendor, 100e18);
            assertTrue(ok);
        }
        (bool paid, uint256 id) = _request(vendor, 1e18);
        assertFalse(paid);
        (,,,, uint32 reasons,,) = safe.holds(id);
        assertEq(reasons, safe.R_OVER_DAILY_LIMIT());
        vm.warp(block.timestamp + 1 days);
        (paid,) = _request(vendor, 1e18);
        assertTrue(paid);
    }

    function test_NewlyTrustedPayeeWaitsOutCooldown() public {
        vm.prank(ada);
        safe.trust(ben);
        (bool paid, uint256 id) = _request(ben, 10e18);
        assertFalse(paid);
        (,,,, uint32 reasons,,) = safe.holds(id);
        assertEq(reasons, safe.R_COOLDOWN());
        vm.warp(block.timestamp + 1 hours);
        (paid,) = _request(ben, 10e18);
        assertTrue(paid);
    }

    function test_UntrustedPayeeIsHeldAgain() public {
        vm.prank(ada);
        safe.untrust(vendor);
        (bool paid,) = _request(vendor, 10e18);
        assertFalse(paid);
    }

    function test_AgentCanAskForAHuman() public {
        vm.prank(agent);
        (bool paid, uint256 id) = safe.request(ada, vendor, 10e18, keccak256("invoice-4471"), true);
        assertFalse(paid);
        (,,,, uint32 reasons,, bytes32 memo) = safe.holds(id);
        assertEq(reasons, safe.R_AGENT_ESCALATED());
        assertEq(memo, keccak256("invoice-4471"));
    }

    // ------------------------------------------------ freeze

    function test_FreezeBlocksRequestsAndApprovals() public {
        (, uint256 id) = _request(ben, 40e18);
        vm.prank(agent);
        safe.freeze(ada); // the agent may freeze
        vm.prank(agent);
        vm.expectRevert(SellarSafe.AccountFrozen.selector);
        safe.request(ada, vendor, 1e18, bytes32(0), false);
        vm.prank(ada);
        vm.expectRevert(SellarSafe.AccountFrozen.selector);
        safe.approve(id, false);
        // only the owner can unfreeze; the agent's call touches its own account
        vm.prank(agent);
        safe.unfreeze();
        vm.prank(agent);
        vm.expectRevert(SellarSafe.AccountFrozen.selector);
        safe.request(ada, vendor, 1e18, bytes32(0), false);
        vm.prank(ada);
        safe.unfreeze();
        (bool paid,) = _request(vendor, 1e18);
        assertTrue(paid);
    }

    function test_StrangerCannotFreeze() public {
        vm.prank(ben);
        vm.expectRevert(SellarSafe.NotOwner.selector);
        safe.freeze(ada);
    }

    function test_OwnerCanWithdrawWhileFrozen() public {
        vm.startPrank(ada);
        safe.freeze(ada);
        safe.withdraw(5_000e18);
        vm.stopPrank();
        assertEq(musd.balanceOf(ada), 10_000e18);
    }

    // ------------------------------------------------ the scam list

    function test_FlaggedPayeeIsHeldEvenIfTrusted() public {
        _report(ben, vendor);
        (bool paid, uint256 id) = _request(vendor, 10e18);
        assertFalse(paid);
        (,,,, uint32 reasons,,) = safe.holds(id);
        assertEq(reasons, safe.R_FLAGGED());
    }

    function test_CannotTrustAFlaggedAddress() public {
        _report(ben, scammer);
        vm.prank(ada);
        vm.expectRevert(SellarSafe.PayeeFlagged.selector);
        safe.trust(scammer);
    }

    function test_ApprovalGoesStaleIfPayeeFlaggedAfterTheHold() public {
        (, uint256 id) = _request(scammer, 40e18);
        _report(ben, scammer);
        vm.startPrank(ada);
        vm.expectRevert(SellarSafe.FlaggedSinceHold.selector);
        safe.approve(id, false);
        safe.approve(id, true); // the owner can still decide, knowingly
        vm.stopPrank();
        assertEq(musd.balanceOf(scammer), 40e18);
    }

    function test_ConfirmedScamCanNeverBeApproved() public {
        (, uint256 id) = _request(scammer, 40e18);
        _report(ben, scammer);
        vm.prank(reviewer);
        shield.confirm(scammer);
        vm.prank(ada);
        vm.expectRevert(SellarSafe.ConfirmedScam.selector);
        safe.approve(id, true);
    }

    // ------------------------------------------------ Mezo loan health

    function test_LowLoanHealthHoldsPayments() public {
        vm.prank(ada);
        safe.configure(agent, 100e18, 300e18, 1 hours, 1.5e18);
        (bool paid,) = _request(vendor, 10e18); // no loan: nothing to protect
        assertTrue(paid);

        tm.set(ada, 1, 1.4e18);
        uint256 id;
        (paid, id) = _request(vendor, 10e18);
        assertFalse(paid);
        (,,,, uint32 reasons,,) = safe.holds(id);
        assertEq(reasons, safe.R_LOW_LOAN_HEALTH());

        tm.set(ada, 1, 1.6e18);
        (paid,) = _request(vendor, 10e18);
        assertTrue(paid);
        (bool hasLoan, uint256 icr) = safe.loanHealth(ada);
        assertTrue(hasLoan);
        assertEq(icr, 1.6e18);
    }

    function test_UnreadableMezoStateFailsClosed() public {
        vm.prank(ada);
        safe.configure(agent, 100e18, 300e18, 1 hours, 1.5e18);
        tm.set(ada, 1, 2e18);
        pf.setBroken(true);
        (bool paid,) = _request(vendor, 10e18);
        assertFalse(paid);
        pf.setBroken(false);
        tm.setBroken(true);
        (paid,) = _request(vendor, 10e18);
        assertFalse(paid);
    }

    // ------------------------------------------------ misc

    function test_InsufficientBalanceReverts() public {
        vm.prank(ada);
        safe.configure(agent, type(uint128).max, type(uint128).max, 0, 0);
        vm.prank(agent);
        vm.expectRevert(SellarSafe.InsufficientBalance.selector);
        safe.request(ada, vendor, 5_000e18, bytes32(0), false); // balance cannot cover amount + fee
    }

    function test_FeeCannotExceedCap() public {
        vm.expectRevert(SellarSafe.FeeTooHigh.selector);
        new SellarSafe(musd, shield, tm_(), pf_(), 101, HOLD_TTL);
    }

    function tm_() internal view returns (ITM) {
        return ITM(address(tm));
    }

    function pf_() internal view returns (IPF) {
        return IPF(address(pf));
    }

    // ------------------------------------------------ fuzz

    /// Whatever the agent asks for, money only leaves on its own to a trusted payee within limits.
    function testFuzz_UnattendedPaymentsRespectRules(address to, uint128 amount) public {
        vm.assume(to != address(0) && to != address(safe) && to != address(shield));
        amount = uint128(bound(amount, 1, 4_000e18));
        uint256 before = musd.balanceOf(to);
        vm.prank(agent);
        (bool paid,) = safe.request(ada, to, amount, bytes32(0), false);
        if (paid) {
            assertEq(to, vendor);
            assertLe(amount, 100e18);
            assertEq(musd.balanceOf(to) - before, amount);
        } else {
            assertEq(musd.balanceOf(to), before);
        }
    }

    function testFuzz_DailySpendNeverExceedsLimitUnattended(uint128[8] memory amounts) public {
        uint256 sent;
        for (uint256 i; i < amounts.length; i++) {
            uint128 amt = uint128(bound(amounts[i], 1, 150e18));
            (bool paid,) = _request(vendor, amt);
            if (paid) sent += amt;
        }
        assertLe(sent, 300e18);
        assertEq(safe.spentToday(ada), sent);
    }
}

import {ITroveManager as ITM, IPriceFeed as IPF} from "../src/interfaces/IMezo.sol";
