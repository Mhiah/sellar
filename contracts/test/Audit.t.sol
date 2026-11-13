// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "./Base.t.sol";
import {SellarSafe} from "../src/SellarSafe.sol";
import {SellarShield} from "../src/SellarShield.sol";

/// Tries to call back into the shield while it is being paid BTC.
contract Reenterer {
    SellarShield shield;
    address suspect;
    uint256 public mode; // 1 = withdrawBond again, 2 = buyBtc again, 3 = claim
    bool public reentryFailed;

    constructor(SellarShield s) {
        shield = s;
    }

    function arm(uint256 m, address suspect_) external {
        mode = m;
        suspect = suspect_;
    }

    function report(address s, address musd) external {
        (bool ok,) = musd.call(abi.encodeWithSignature("approve(address,uint256)", address(shield), type(uint256).max));
        require(ok);
        shield.report(s, bytes32(0));
    }

    function withdrawBond(address s) external {
        shield.withdrawBond(s);
    }

    function buy(uint256 btc, uint256 max) external {
        shield.buyBtc(btc, max);
    }

    receive() external payable {
        if (mode == 1) {
            try shield.withdrawBond(suspect) {} catch { reentryFailed = true; }
        } else if (mode == 2) {
            try shield.buyBtc(1, type(uint256).max) {} catch { reentryFailed = true; }
        } else if (mode == 3) {
            try shield.claim(0) {} catch { reentryFailed = true; }
        }
    }
}

/// Independent audit tests. The first half checks that the intended controls hold against a
/// hostile caller. The second half (names starting with test_Finding) reproduces weaknesses the
/// audit found, so they stay visible and are caught if the design changes.
contract AuditTest is Base {
    address mallory = makeAddr("mallory");

    // ------------------------------------------------------------ controls that must hold

    function test_StrangerCannotSpendFromSomeoneElsesAccount() public {
        vm.prank(mallory);
        vm.expectRevert(SellarSafe.NotAgent.selector);
        safe.request(ada, mallory, 1e18, bytes32(0), false);

        uint256 before = musd.balanceOf(mallory);
        vm.prank(mallory);
        vm.expectRevert(SellarSafe.InsufficientBalance.selector);
        safe.withdraw(1);
        assertEq(musd.balanceOf(mallory), before);
    }

    function test_AgentCannotWithdrawOrChangeTheRules() public {
        // withdraw and configure act on the caller's own account, so the agent only touches its own (empty) one
        vm.startPrank(agent);
        vm.expectRevert(SellarSafe.InsufficientBalance.selector);
        safe.withdraw(1);
        safe.configure(agent, type(uint128).max, type(uint128).max, 0, 0);
        safe.trust(mallory);
        vm.stopPrank();
        (, , , , uint128 perPayment,,,,) = safe.accounts(ada);
        assertEq(perPayment, 100e18, "ada's limit is unchanged");
        (bool paid,) = _request(mallory, 1e18);
        assertFalse(paid, "mallory is still not trusted by ada");
    }

    function test_OnlyTheOwnerCanReleaseOrRejectAHold() public {
        (, uint256 id) = _request(scammer, 5e18);
        vm.startPrank(mallory);
        vm.expectRevert(SellarSafe.NotOwner.selector);
        safe.approve(id, true);
        vm.expectRevert(SellarSafe.NotOwner.selector);
        safe.reject(id);
        vm.stopPrank();
        vm.startPrank(agent);
        vm.expectRevert(SellarSafe.NotOwner.selector);
        safe.approve(id, true);
        vm.stopPrank();
    }

    function test_AHoldPaysOnceAndNeverAfterRejectOrExpiry() public {
        (, uint256 a) = _request(scammer, 5e18);
        (, uint256 b) = _request(scammer, 6e18);
        (, uint256 c) = _request(scammer, 7e18);
        vm.startPrank(ada);
        safe.approve(a, false);
        vm.expectRevert(SellarSafe.NotPending.selector);
        safe.approve(a, false);
        safe.reject(b);
        vm.expectRevert(SellarSafe.NotPending.selector);
        safe.approve(b, false);
        vm.warp(block.timestamp + HOLD_TTL + 1);
        vm.expectRevert(SellarSafe.HoldExpired.selector);
        safe.approve(c, false);
        vm.stopPrank();
        assertEq(musd.balanceOf(scammer), 5e18);
    }

    function test_FrozenAccountPaysNothingButOwnerCanStillWithdraw() public {
        (, uint256 id) = _request(scammer, 5e18);
        vm.prank(agent);
        safe.freeze(ada);
        vm.prank(agent);
        vm.expectRevert(SellarSafe.AccountFrozen.selector);
        safe.request(ada, vendor, 1e18, bytes32(0), false);
        vm.startPrank(ada);
        vm.expectRevert(SellarSafe.AccountFrozen.selector);
        safe.approve(id, false);
        safe.withdraw(100e18);
        vm.stopPrank();
        // the agent cannot lift the freeze
        vm.prank(agent);
        safe.unfreeze(); // acts on the agent's own account only
        (, bool frozen,,,,,,,) = safe.accounts(ada);
        assertTrue(frozen);
    }

    function test_OnlyTheSafeRecordsPaymentsAndSafeIsSetOnce() public {
        vm.prank(mallory);
        vm.expectRevert(SellarShield.NotSafe.selector);
        shield.recordPayment(mallory, scammer, 500e18);
        vm.expectRevert(SellarShield.SafeAlreadySet.selector);
        shield.setSafe(mallory);
        vm.prank(mallory);
        vm.expectRevert(SellarShield.NotDeployer.selector);
        shield.setSafe(mallory);
    }

    function test_OnlyTheReviewerResolvesAndHandoverNeedsAcceptance() public {
        _report(ben, scammer);
        vm.startPrank(mallory);
        vm.expectRevert(SellarShield.NotReviewer.selector);
        shield.confirm(scammer);
        vm.expectRevert(SellarShield.NotReviewer.selector);
        shield.dismiss(scammer);
        vm.expectRevert(SellarShield.NotReviewer.selector);
        shield.proposeReviewer(mallory);
        vm.expectRevert(SellarShield.NotReviewer.selector);
        shield.acceptReviewer();
        vm.stopPrank();
    }

    function test_RefundCannotBeClaimedTwiceOrBySomeoneElse() public {
        musd.mint(address(shield), 5_000e18);
        _request(vendor, 50e18); // receipt 0, paid before any report
        vm.warp(block.timestamp + 1 hours);
        _report(ben, vendor);
        vm.prank(reviewer);
        shield.confirm(vendor);
        vm.prank(mallory);
        vm.expectRevert(SellarShield.NotPayer.selector);
        shield.claim(0);
        vm.startPrank(ada);
        shield.claim(0);
        vm.expectRevert(SellarShield.AlreadyClaimed.selector);
        shield.claim(0);
        vm.stopPrank();
    }

    function test_BondCannotBeWithdrawnTwice() public {
        _report(ben, scammer);
        vm.prank(reviewer);
        shield.confirm(scammer);
        vm.startPrank(ben);
        shield.withdrawBond(scammer);
        vm.expectRevert(SellarShield.NothingToWithdraw.selector);
        shield.withdrawBond(scammer);
        vm.stopPrank();
        assertEq(shield.bondsHeld(), 0);
    }

    function test_ReentryWhileBeingPaidBtcIsRefused() public {
        // BTC reward path
        vm.deal(address(shield), 10 ether);
        Reenterer r = new Reenterer(shield);
        musd.mint(address(r), BOND);
        r.report(scammer, address(musd));
        _report(ben, scammer);
        vm.prank(reviewer);
        shield.confirm(scammer);
        r.arm(1, scammer);
        r.withdrawBond(scammer);
        assertTrue(r.reentryFailed(), "second withdrawBond inside the first must fail");
        assertEq(address(r).balance, 0.5 ether, "paid its reward once");

        // BTC sale path
        Reenterer buyer = new Reenterer(shield);
        musd.mint(address(buyer), 1_000_000e18);
        vm.prank(address(buyer));
        musd.approve(address(shield), type(uint256).max);
        buyer.arm(2, address(0));
        buyer.buy(1 ether, type(uint256).max);
        assertTrue(buyer.reentryFailed(), "buyBtc inside buyBtc must fail");
        assertEq(address(buyer).balance, 1 ether);
    }

    function testFuzz_AccountsNeverMix(uint96 adaPays, uint96 benDeposit) public {
        adaPays = uint96(bound(adaPays, 1, 100e18));
        benDeposit = uint96(bound(benDeposit, 1, 1_000_000e18));
        _fund(ben, benDeposit);
        vm.prank(ben);
        safe.deposit(ben, benDeposit);
        _request(vendor, adaPays);
        (,,,,,,, uint256 benBal,) = safe.accounts(ben);
        assertEq(benBal, benDeposit, "ben's balance is untouched by ada's agent");
        vm.prank(ben);
        safe.withdraw(benDeposit);
        assertEq(musd.balanceOf(ben), benDeposit);
    }

    // ------------------------------------------------------------ findings (weaknesses reproduced)

    /// F-01. A scammer can pay himself from accounts he controls, get himself (correctly) confirmed
    /// as a scam, and claim refunds as his own "victims". No dishonest reviewer is needed.
    function test_Finding_F01_FakeVictimsDrainMostOfTheCoverFund() public {
        musd.mint(address(shield), 5_000e18); // the cover fund built up from other people's fees
        uint256 fundBefore = shield.fundAssets();
        address payable thief = payable(makeAddr("thief")); // the "scam" address, same person as the puppets
        uint256 spent;
        uint256 n = 10;
        address[] memory puppets = new address[](n);
        for (uint256 i; i < n; i++) {
            address p = makeAddr(string(abi.encodePacked("puppet", vm.toString(i))));
            puppets[i] = p;
            _fund(p, 502e18);
            vm.startPrank(p);
            safe.deposit(p, 502e18);
            safe.configure(p, 500e18, 500e18, 0, 0);
            safe.trust(thief);
            safe.request(p, thief, 500e18, bytes32(0), false); // 500 goes to himself, 1.25 fee is the only cost
            vm.stopPrank();
            spent += 1.25e18;
        }
        vm.warp(block.timestamp + 1 hours);
        _report(ben, thief); // any honest reporter; the address really does look like a scam
        vm.prank(reviewer);
        shield.confirm(thief);
        uint256 stolen;
        for (uint256 i; i < n; i++) {
            uint256 b = musd.balanceOf(puppets[i]);
            vm.prank(puppets[i]);
            shield.claim(i);
            stolen += musd.balanceOf(puppets[i]) - b;
        }
        uint256 fundAfter = shield.fundAssets();
        emit log_named_decimal_uint("fund before", fundBefore, 18);
        emit log_named_decimal_uint("fund after", fundAfter, 18);
        emit log_named_decimal_uint("attacker cost (fees)", spent, 18);
        emit log_named_decimal_uint("attacker took", stolen, 18);
        assertGt(stolen, 4_000e18, "most of the fund is gone");
        assertLt(spent, 13e18);
    }

    /// F-02. A flag costs nothing if the reviewer never acts: the reporter takes the bond back after
    /// the timeout, having blocked unattended payments to that payee for the whole period.
    function test_Finding_F02_FreeFlagWhenReviewerIsAbsent() public {
        uint256 before = musd.balanceOf(mallory);
        _fund(mallory, BOND);
        vm.prank(mallory);
        shield.report(vendor, bytes32(0));
        (bool paid,) = _request(vendor, 10e18);
        assertFalse(paid, "ada's trusted vendor is now held");
        vm.warp(block.timestamp + RESOLVE_TIMEOUT);
        vm.prank(mallory);
        shield.withdrawBond(vendor);
        assertEq(musd.balanceOf(mallory), before + BOND, "the attacker got the whole bond back");
        // and can do it again at once
        vm.prank(mallory);
        shield.report(vendor, bytes32(0));
        (paid,) = _request(vendor, 10e18);
        assertFalse(paid);
    }

    /// F-03. The reviewer plus one 10 MUSD report can block an address for good. Even the owner
    /// cannot release a payment to a confirmed address through Sellar.
    function test_Finding_F03_ConfirmedAddressIsBlockedForeverWithNoAppeal() public {
        (, uint256 id) = _request(scammer, 5e18);
        _report(ben, vendor);
        _report(ben, scammer);
        vm.startPrank(reviewer);
        shield.confirm(vendor);
        shield.confirm(scammer);
        vm.stopPrank();
        vm.prank(ada);
        vm.expectRevert(SellarSafe.ConfirmedScam.selector);
        safe.approve(id, true);
        vm.prank(reviewer);
        vm.expectRevert(SellarShield.NotFlagged.selector);
        shield.dismiss(vendor); // no way back
        vm.prank(ada);
        safe.withdraw(100e18); // the owner's own money is never trapped
    }

    /// F-04. The BTC reward is split equally, so late or sock-puppet reporters take most of it from
    /// the person who reported first.
    function test_Finding_F04_SockPuppetReportersDiluteTheFirstReporter() public {
        vm.deal(address(shield), 10 ether); // 1 BTC of reward at stake (10%)
        _report(ben, scammer); // the honest first reporter
        for (uint256 i; i < 9; i++) {
            _report(makeAddr(string(abi.encodePacked("sock", vm.toString(i)))), scammer);
        }
        vm.prank(reviewer);
        shield.confirm(scammer);
        vm.prank(ben);
        shield.withdrawBond(scammer);
        assertEq(ben.balance, 0.1 ether, "ben found the scam and got a tenth of the reward");
    }

    /// F-05. The daily limit resets at midnight UTC, so an agent can spend two days' allowance in
    /// two seconds across the boundary.
    function test_Finding_F05_TwoDaysAllowanceAcrossMidnight() public {
        uint256 midnight = (block.timestamp / 1 days + 1) * 1 days;
        vm.warp(midnight - 1);
        for (uint256 i; i < 3; i++) {
            (bool p,) = _request(vendor, 100e18);
            assertTrue(p);
        }
        (bool over,) = _request(vendor, 100e18);
        assertFalse(over, "the 300 limit holds within one day");
        vm.prank(ada);
        safe.reject(0);
        vm.warp(midnight + 1);
        for (uint256 i; i < 3; i++) {
            (bool p,) = _request(vendor, 100e18);
            assertTrue(p);
        }
        assertEq(musd.balanceOf(vendor), 600e18, "600 MUSD in two seconds against a 300 daily limit");
    }

    /// F-06. The sale price comes only from Mezo's price feed. If that feed reads low, the fund's
    /// BTC goes cheap. There is no second source or sanity bound.
    function test_Finding_F06_FundSellsAtWhateverTheFeedSays() public {
        vm.deal(address(shield), 1 ether);
        vm.store(address(pf), bytes32(uint256(0)), bytes32(uint256(1_000e18))); // feed reads 1,000 instead of 100,000
        _fund(mallory, 1_000e18);
        vm.prank(mallory);
        uint256 cost = shield.buyBtc(1 ether, type(uint256).max);
        assertEq(cost, 990e18, "1 BTC sold for 990 MUSD");
    }

    /// F-07. Payments under 400 wei of MUSD pay no cover fee (rounding down). Not economic to abuse.
    function test_Finding_F07_DustPaymentsPayNoFee() public {
        uint256 fund = shield.fundLiquid();
        _request(vendor, 399);
        assertEq(shield.fundLiquid(), fund);
    }
}
