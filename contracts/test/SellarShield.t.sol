// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "./Base.t.sol";
import {SellarShield} from "../src/SellarShield.sol";

contract SellarShieldTest is Base {
    address dayo = makeAddr("dayo");

    function _status(address who) internal view returns (SellarShield.Status) {
        return shield.statusOf(who);
    }

    /// Chidi pays the scammer through his own safe account before anyone has reported it.
    function _chidiPaysScammer(uint128 amount) internal returns (uint256 receiptId) {
        address chidiAgent = makeAddr("chidiAgent");
        _fund(chidi, 2_000e18);
        vm.startPrank(chidi);
        safe.deposit(chidi, 2_000e18);
        safe.configure(chidiAgent, 1_000e18, 1_000e18, 0, 0);
        safe.trust(scammer); // he believed the fake invoice
        vm.stopPrank();
        receiptId = shield.receiptCount();
        vm.prank(chidiAgent);
        (bool paid,) = safe.request(chidi, scammer, amount, bytes32(0), false);
        assertTrue(paid);
        vm.warp(block.timestamp + 1);
    }

    function _seedFund(uint256 amount) internal {
        musd.mint(address(shield), amount);
    }

    // ------------------------------------------------ reporting

    function test_OneBondedReportFlags() public {
        _report(ben, scammer);
        (SellarShield.Status s, uint32 n, uint256 bonded) = shield.flagInfo(scammer);
        assertEq(uint8(s), uint8(SellarShield.Status.Flagged));
        assertEq(n, 1);
        assertEq(bonded, BOND);
        assertEq(shield.bondsHeld(), BOND);
        assertEq(shield.fundLiquid(), 0); // a bond is not fund money
    }

    function test_CannotReportTwiceOrSelfOrZero() public {
        _report(ben, scammer);
        _fund(ben, BOND);
        vm.startPrank(ben);
        vm.expectRevert(SellarShield.AlreadyReported.selector);
        shield.report(scammer, bytes32(0));
        vm.expectRevert(SellarShield.SelfReport.selector);
        shield.report(ben, bytes32(0));
        vm.expectRevert(SellarShield.ZeroAddress.selector);
        shield.report(address(0), bytes32(0));
        vm.stopPrank();
    }

    function test_OnlyReviewerResolves() public {
        _report(ben, scammer);
        vm.startPrank(ben);
        vm.expectRevert(SellarShield.NotReviewer.selector);
        shield.confirm(scammer);
        vm.expectRevert(SellarShield.NotReviewer.selector);
        shield.dismiss(scammer);
        vm.stopPrank();
    }

    function test_ConfirmReturnsBondsWithBtcReward() public {
        _report(ben, scammer);
        _report(dayo, scammer);
        vm.deal(address(shield), 1 ether); // BTC earned in the Stability Pool
        vm.prank(reviewer);
        shield.confirm(scammer);
        // 10% of 1 BTC, split between two reporters
        assertEq(shield.btcReserved(), 0.1 ether);

        uint256 musdBefore = musd.balanceOf(ben);
        vm.prank(ben);
        shield.withdrawBond(scammer);
        assertEq(musd.balanceOf(ben) - musdBefore, BOND);
        assertEq(ben.balance, 0.05 ether);

        vm.prank(ben);
        vm.expectRevert(SellarShield.NothingToWithdraw.selector);
        shield.withdrawBond(scammer);

        vm.prank(dayo);
        shield.withdrawBond(scammer);
        assertEq(shield.bondsHeld(), 0);
        assertEq(shield.btcReserved(), 0);
    }

    function test_ConfirmedCaseIsFinal() public {
        _report(ben, scammer);
        vm.prank(reviewer);
        shield.confirm(scammer);
        _fund(dayo, BOND);
        vm.prank(dayo);
        vm.expectRevert(SellarShield.CaseClosed.selector);
        shield.report(scammer, bytes32(0));
    }

    function test_DismissSlashesBondsIntoTheFund() public {
        _report(ben, vendor); // a false report against an honest payee
        vm.prank(reviewer);
        shield.dismiss(vendor);
        assertEq(uint8(_status(vendor)), uint8(SellarShield.Status.Dismissed));
        assertEq(shield.bondsHeld(), 0);
        assertEq(shield.fundLiquid(), BOND);
        vm.prank(ben);
        vm.expectRevert(SellarShield.NothingToWithdraw.selector);
        shield.withdrawBond(vendor);
        // the honest payee is payable again
        (bool paid,) = _request(vendor, 10e18);
        assertTrue(paid);
    }

    function test_DismissedAddressCanBeReportedAgainInANewRound() public {
        _report(ben, vendor);
        vm.prank(reviewer);
        shield.dismiss(vendor);
        _report(ben, vendor); // same reporter, new round, new bond
        assertEq(uint8(_status(vendor)), uint8(SellarShield.Status.Flagged));
        assertEq(shield.bondsHeld(), BOND);
    }

    function test_UnresolvedCaseReleasesBondsAfterTimeout() public {
        _report(ben, scammer);
        vm.prank(ben);
        vm.expectRevert(SellarShield.TooEarly.selector);
        shield.withdrawBond(scammer);
        vm.warp(block.timestamp + RESOLVE_TIMEOUT);
        vm.prank(ben);
        shield.withdrawBond(scammer);
        assertEq(uint8(_status(scammer)), uint8(SellarShield.Status.None));
        assertEq(shield.bondsHeld(), 0);
        // and it can be reported afresh
        _report(ben, scammer);
        assertEq(uint8(_status(scammer)), uint8(SellarShield.Status.Flagged));
    }

    function test_ReviewerHandoverIsTwoStep() public {
        vm.prank(reviewer);
        shield.proposeReviewer(dayo);
        vm.prank(ben);
        vm.expectRevert(SellarShield.NotReviewer.selector);
        shield.acceptReviewer();
        vm.prank(dayo);
        shield.acceptReviewer();
        assertEq(shield.reviewer(), dayo);
    }

    function test_SafeIsSetOnceByDeployer() public {
        vm.expectRevert(SellarShield.SafeAlreadySet.selector);
        shield.setSafe(address(1));
        vm.prank(ben);
        vm.expectRevert(SellarShield.NotDeployer.selector);
        shield.setSafe(address(1));
    }

    function test_OnlySafeRecordsPayments() public {
        vm.prank(ben);
        vm.expectRevert(SellarShield.NotSafe.selector);
        shield.recordPayment(ben, scammer, 1e18);
    }

    // ------------------------------------------------ claims

    function test_VictimWhoPaidBeforeTheReportIsRefunded() public {
        _seedFund(5_000e18);
        uint256 id = _chidiPaysScammer(200e18);
        _report(ben, scammer);
        vm.prank(reviewer);
        shield.confirm(scammer);
        uint256 before = musd.balanceOf(chidi);
        vm.prank(chidi);
        shield.claim(id);
        assertEq(musd.balanceOf(chidi) - before, 200e18);
        vm.prank(chidi);
        vm.expectRevert(SellarShield.AlreadyClaimed.selector);
        shield.claim(id);
    }

    function test_ClaimNeedsConfirmationNotJustAFlag() public {
        _seedFund(5_000e18);
        uint256 id = _chidiPaysScammer(200e18);
        _report(ben, scammer);
        vm.prank(chidi);
        vm.expectRevert(SellarShield.NotConfirmed.selector);
        shield.claim(id);
    }

    function test_OnlyThePayerClaims() public {
        _seedFund(5_000e18);
        uint256 id = _chidiPaysScammer(200e18);
        _report(ben, scammer);
        vm.prank(reviewer);
        shield.confirm(scammer);
        vm.prank(ben);
        vm.expectRevert(SellarShield.NotPayer.selector);
        shield.claim(id);
    }

    function test_PaymentApprovedDespiteAFlagIsNotCovered() public {
        _seedFund(5_000e18);
        _report(ben, scammer);
        vm.warp(block.timestamp + 1);
        (, uint256 holdId) = _request(scammer, 40e18);
        uint256 receiptId = shield.receiptCount();
        vm.prank(ada);
        safe.approve(holdId, true); // ada was warned and paid anyway
        vm.prank(reviewer);
        shield.confirm(scammer);
        vm.prank(ada);
        vm.expectRevert(SellarShield.PaidAfterReport.selector);
        shield.claim(receiptId);
    }

    function test_ClaimOutsideCoverWindowIsRefused() public {
        _seedFund(5_000e18);
        uint256 id = _chidiPaysScammer(200e18);
        vm.warp(block.timestamp + COVER_WINDOW + 1);
        _report(ben, scammer);
        vm.prank(reviewer);
        shield.confirm(scammer);
        vm.prank(chidi);
        vm.expectRevert(SellarShield.OutsideCoverWindow.selector);
        shield.claim(id);
    }

    function test_ClaimIsCappedByClaimCapAndFundShare() public {
        _seedFund(10_000e18);
        uint256 id = _chidiPaysScammer(900e18);
        _report(ben, scammer);
        vm.prank(reviewer);
        shield.confirm(scammer);
        uint256 before = musd.balanceOf(chidi);
        vm.prank(chidi);
        shield.claim(id);
        assertEq(musd.balanceOf(chidi) - before, CLAIM_CAP);
    }

    function test_SmallFundPaysOnlyItsShare() public {
        uint256 id = _chidiPaysScammer(200e18); // the fund holds only this payment's fee
        uint256 fund = shield.fundAssets();
        _report(ben, scammer);
        vm.prank(reviewer);
        shield.confirm(scammer);
        uint256 before = musd.balanceOf(chidi);
        vm.prank(chidi);
        shield.claim(id);
        assertEq(musd.balanceOf(chidi) - before, fund * 2_000 / 10_000);
    }

    function test_ClaimsNeverSpendReporterBonds() public {
        uint256 id = _chidiPaysScammer(200e18);
        _report(ben, scammer);
        _report(dayo, scammer);
        vm.prank(reviewer);
        shield.confirm(scammer);
        vm.prank(chidi);
        shield.claim(id);
        assertGe(musd.balanceOf(address(shield)), shield.bondsHeld());
        vm.prank(ben);
        shield.withdrawBond(scammer);
        vm.prank(dayo);
        shield.withdrawBond(scammer);
    }

    // ------------------------------------------------ Stability Pool

    function test_RebalanceKeepsBufferAndDepositsTheRest() public {
        _seedFund(1_000e18);
        shield.rebalance();
        assertEq(shield.fundLiquid(), 250e18);
        assertEq(sp.deposits(address(shield)), 750e18);
        assertEq(shield.fundAssets(), 1_000e18);
    }

    function test_RebalanceNeverDepositsBonds() public {
        _report(ben, scammer);
        shield.rebalance();
        assertEq(sp.deposits(address(shield)), 0);
        assertEq(musd.balanceOf(address(shield)), BOND);
    }

    function test_ClaimPullsFromThePoolWhenBufferIsShort() public {
        _seedFund(2_000e18);
        uint256 first = _chidiPaysScammer(400e18);
        uint256 second = shield.receiptCount();
        vm.prank(makeAddr("chidiAgent"));
        safe.request(chidi, scammer, 400e18, bytes32(0), false);
        vm.warp(block.timestamp + 1);
        shield.rebalance(); // about 500 liquid, 1,500 in the pool
        _report(ben, scammer);
        vm.prank(reviewer);
        shield.confirm(scammer);

        uint256 before = musd.balanceOf(chidi);
        vm.startPrank(chidi);
        shield.claim(first); // paid from the buffer
        uint256 poolBefore = sp.deposits(address(shield));
        shield.claim(second); // the buffer is short now, so this one draws on the pool
        vm.stopPrank();
        assertLt(sp.deposits(address(shield)), poolBefore);
        assertGt(musd.balanceOf(chidi) - before, 700e18);
    }

    function test_PausedPoolMakesClaimWaitThenSucceed() public {
        _seedFund(1_000e18);
        shield.rebalance(); // 250 liquid
        uint256 id = _chidiPaysScammer(400e18);
        _report(ben, scammer);
        vm.prank(reviewer);
        shield.confirm(scammer);
        // only ~251 MUSD is liquid and the pool refuses withdrawals
        sp.setPaused(true);
        uint256 payout = shield.fundAssets() * 2_000 / 10_000;
        assertLt(payout, 400e18);
        // shrink the buffer so the claim needs the pool
        vm.prank(address(shield));
        musd.transfer(address(0xdead), 200e18);
        vm.prank(chidi);
        vm.expectRevert(SellarShield.FundBusy.selector);
        shield.claim(id);
        shield.rebalance(); // does not revert while paused
        sp.setPaused(false);
        vm.prank(chidi);
        shield.claim(id);
    }

    function test_LiquidationLossShrinksFundAndBtcArrives() public {
        _seedFund(1_000e18);
        shield.rebalance();
        vm.deal(address(sp), 1 ether);
        sp.liquidate(address(shield), 300e18, 0.004 ether);
        assertEq(shield.fundAssets(), 700e18);
        (uint256 held, uint256 pending) = shield.fundBtc();
        assertEq(held, 0);
        assertEq(pending, 0.004 ether);
        shield.rebalance(); // any pool operation delivers the BTC gain
        (held, pending) = shield.fundBtc();
        assertEq(held, 0.004 ether);
        assertEq(pending, 0);
        assertEq(shield.fundLiquid(), 175e18);
    }

    function test_FullyWipedPoolDepositDoesNotBrickTheFund() public {
        _seedFund(1_000e18);
        shield.rebalance();
        sp.liquidate(address(shield), 750e18, 0);
        assertEq(shield.fundAssets(), 250e18);
        shield.rebalance();
        uint256 id = _chidiPaysScammer(40e18);
        _report(ben, scammer);
        vm.prank(reviewer);
        shield.confirm(scammer);
        vm.prank(chidi);
        shield.claim(id);
    }

    // ------------------------------------------------ fuzz

    function testFuzz_ClaimNeverExceedsAmountCapOrFundShare(uint128 paid, uint256 fund) public {
        paid = uint128(bound(paid, 1e18, 1_000e18));
        fund = bound(fund, 0, 100_000e18);
        _seedFund(fund);
        uint256 id = _chidiPaysScammer(paid);
        uint256 assets = shield.fundAssets();
        _report(ben, scammer);
        vm.prank(reviewer);
        shield.confirm(scammer);
        uint256 before = musd.balanceOf(chidi);
        vm.prank(chidi);
        shield.claim(id);
        uint256 got = musd.balanceOf(chidi) - before;
        assertLe(got, paid);
        assertLe(got, CLAIM_CAP);
        assertLe(got, assets * 2_000 / 10_000);
        assertGe(musd.balanceOf(address(shield)), shield.bondsHeld());
    }
}
