// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "./Base.t.sol";
import {SellarSafe} from "../src/SellarSafe.sol";
import {SellarShield} from "../src/SellarShield.sol";

/// What version 2 added: the fund sells its BTC for MUSD at Mezo's price, per-owner lists of holds
/// and receipts, owner releases that do not use the agent's daily allowance, and receipts that
/// remember a warning.
contract SellarV2Test is Base {
    address buyer = makeAddr("buyer");

    function setUp() public override {
        super.setUp();
        _fund(buyer, 100_000e18);
    }

    // ------------------------------------------------ the fund sells its BTC

    function test_FundSellsBtcAtTheFeedPriceLessOnePercent() public {
        vm.deal(address(shield), 0.01 ether); // BTC the fund earned
        uint256 fundBefore = shield.fundLiquid();
        (uint256 cost, uint256 price) = shield.quoteBtc(0.01 ether);
        assertEq(price, 100_000e18);
        assertEq(cost, 990e18); // 0.01 BTC at 100,000 MUSD, less 1%
        vm.prank(buyer);
        shield.buyBtc(0.01 ether, cost);
        assertEq(buyer.balance, 0.01 ether);
        assertEq(shield.fundLiquid() - fundBefore, 990e18); // the BTC became refund money
        assertEq(shield.btcForSale(), 0);
    }

    function test_BtcSetAsideForReportersIsNotForSale() public {
        _report(ben, scammer);
        vm.deal(address(shield), 1 ether);
        vm.prank(reviewer);
        shield.confirm(scammer); // reserves 0.1 BTC for ben
        assertEq(shield.btcForSale(), 0.9 ether);
        vm.prank(buyer);
        vm.expectRevert(SellarShield.NotEnoughBtc.selector);
        shield.buyBtc(0.95 ether, type(uint256).max);
        vm.prank(buyer);
        shield.buyBtc(0.9 ether, type(uint256).max);
        vm.prank(ben);
        shield.withdrawBond(scammer); // ben's reward is still there
        assertEq(ben.balance, 0.1 ether);
    }

    function test_BuyerIsProtectedIfThePriceMoves() public {
        vm.deal(address(shield), 0.01 ether);
        vm.prank(buyer);
        vm.expectRevert(SellarShield.CostsMoreThanMax.selector);
        shield.buyBtc(0.01 ether, 989e18);
    }

    function test_NoSaleWithoutAPrice() public {
        vm.deal(address(shield), 0.01 ether);
        pf.setBroken(true);
        vm.prank(buyer);
        vm.expectRevert();
        shield.buyBtc(0.01 ether, type(uint256).max);
        assertEq(shield.btcForSale(), 0.01 ether);
    }

    function test_CannotBuyZeroOrMoreThanThereIs() public {
        vm.startPrank(buyer);
        vm.expectRevert(SellarShield.NotEnoughBtc.selector);
        shield.buyBtc(0, type(uint256).max);
        vm.expectRevert(SellarShield.NotEnoughBtc.selector);
        shield.buyBtc(1, type(uint256).max);
        vm.stopPrank();
    }

    function test_PoolGainsBecomeRefundMoneyEndToEnd() public {
        musd.mint(address(shield), 1_000e18);
        shield.rebalance(); // 750 MUSD into the pool
        vm.deal(address(sp), 1 ether);
        sp.liquidate(address(shield), 300e18, 0.004 ether); // the pool turns 300 MUSD into 0.004 BTC
        assertEq(shield.fundAssets(), 700e18);
        shield.rebalance(); // collects the BTC
        vm.prank(buyer);
        shield.buyBtc(0.004 ether, type(uint256).max);
        assertEq(shield.fundAssets(), 700e18 + 396e18); // 0.004 BTC at 100,000, less 1%
    }

    function testFuzz_SaleNeverUndersellsOrTouchesBonds(uint96 btc, uint96 amount) public {
        btc = uint96(bound(btc, 1, 100 ether));
        amount = uint96(bound(amount, 1, btc));
        _report(ben, scammer);
        vm.deal(address(shield), btc);
        uint256 fundBefore = shield.fundLiquid();
        (uint256 cost,) = shield.quoteBtc(amount);
        _fund(buyer, cost);
        vm.prank(buyer);
        shield.buyBtc(amount, cost);
        assertEq(shield.fundLiquid() - fundBefore, cost);
        assertEq(cost, uint256(amount) * 100_000e18 * 9_900 / 1e18 / 10_000);
        assertGe(musd.balanceOf(address(shield)), shield.bondsHeld());
    }

    // ------------------------------------------------ per-owner lists

    function test_HoldsAreListedPerOwnerNewestFirst() public {
        // another owner makes noise in between
        _fund(chidi, 1_000e18);
        vm.startPrank(chidi);
        safe.deposit(chidi, 1_000e18);
        safe.configure(chidi, 1e18, 1e18, 0, 0);
        vm.stopPrank();
        (, uint256 a) = _request(ben, 1e18);
        for (uint256 i; i < 5; i++) {
            vm.prank(chidi);
            safe.request(chidi, ben, 1e18, bytes32(0), false);
        }
        (, uint256 b) = _request(scammer, 2e18);
        assertEq(safe.holdCountOf(ada), 2);
        assertEq(safe.holdCountOf(chidi), 5);
        uint256[] memory ids = safe.holdIdsOf(ada, 0, 10);
        assertEq(ids.length, 2);
        assertEq(ids[0], b);
        assertEq(ids[1], a);
        assertEq(safe.holdIdsOf(ada, 1, 10)[0], a);
        assertEq(safe.holdIdsOf(ada, 0, 1).length, 1);
        assertEq(safe.holdIdsOf(ada, 2, 10).length, 0);
        assertEq(safe.holdIdsOf(ben, 0, 10).length, 0);
    }

    function test_ReceiptsAreListedPerPayer() public {
        _request(vendor, 10e18);
        _request(vendor, 20e18);
        assertEq(shield.receiptCountOf(ada), 2);
        uint256[] memory ids = shield.receiptIdsOf(ada, 0, 10);
        (,, uint128 newest,,,) = shield.receipts(ids[0]);
        assertEq(newest, 20e18);
        assertEq(shield.receiptIdsOf(ada, 5, 10).length, 0);
        assertEq(shield.receiptCountOf(ben), 0);
    }

    // ------------------------------------------------ owner releases and the daily limit

    function test_OwnerReleaseDoesNotUseTheAgentsDailyAllowance() public {
        (, uint256 id) = _request(ben, 90e18); // held: ben is not trusted
        vm.prank(ada);
        safe.approve(id, false);
        assertEq(safe.spentToday(ada), 0);
        for (uint256 i; i < 3; i++) {
            (bool paid,) = _request(vendor, 100e18); // the agent still has its full 300 for the day
            assertTrue(paid);
        }
        assertEq(safe.spentToday(ada), 300e18);
    }

    // ------------------------------------------------ a warning is remembered

    function test_PaymentMadeWhileFlaggedIsNeverCoveredEvenIfReportsAreRefiled() public {
        musd.mint(address(shield), 5_000e18);
        _report(ben, scammer);
        vm.warp(block.timestamp + 1);
        (, uint256 holdId) = _request(scammer, 40e18);
        uint256 receiptId = shield.receiptCount();
        vm.prank(ada);
        safe.approve(holdId, true); // warned, paid anyway
        (,,,,, bool warned) = shield.receipts(receiptId);
        assertTrue(warned);

        // the report goes stale and is withdrawn, then someone reports again and it is confirmed
        vm.warp(block.timestamp + RESOLVE_TIMEOUT);
        vm.prank(ben);
        shield.withdrawBond(scammer);
        _report(chidi, scammer);
        vm.prank(reviewer);
        shield.confirm(scammer);

        vm.prank(ada);
        vm.expectRevert(SellarShield.PaidAfterReport.selector);
        shield.claim(receiptId);
    }

    function test_PaymentBeforeAnyReportIsNotMarkedWarned() public {
        (bool paid,) = _request(vendor, 10e18);
        assertTrue(paid);
        (,,,,, bool warned) = shield.receipts(0);
        assertFalse(warned);
    }
}
