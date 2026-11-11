// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SellarSafe} from "../src/SellarSafe.sol";
import {SellarShield} from "../src/SellarShield.sol";
import {IStabilityPool, ITroveManager, IPriceFeed} from "../src/interfaces/IMezo.sol";

/// Runs against a fork of Mezo testnet with Mezo's real MUSD, StabilityPool, TroveManager and
/// PriceFeed. Skipped unless FORK=1, because it needs network access:
///
///   FORK=1 forge test --match-contract ForkTest
contract ForkTest is Test {
    IERC20 constant MUSD = IERC20(0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503);
    IStabilityPool constant SP = IStabilityPool(0x1CCA7E410eE41739792eA0A24e00349Dd247680e);
    ITroveManager constant TM = ITroveManager(0xE47c80e8c23f6B4A1aE41c34837a0599D5D16bb0);
    IPriceFeed constant PF = IPriceFeed(0x86bCF0841622a5dAC14A313a15f96A95421b9366);

    SellarShield shield;
    SellarSafe safe;
    bool forked;

    address reviewer = makeAddr("reviewer");
    address ada = makeAddr("ada");
    address agent = makeAddr("agent");
    address vendor = makeAddr("vendor");
    address scammer = makeAddr("scammer");
    address ben = makeAddr("ben");

    function setUp() public {
        if (vm.envOr("FORK", uint256(0)) != 1) return;
        vm.createSelectFork(vm.rpcUrl("mezo_testnet"));
        forked = true;
        shield = new SellarShield(MUSD, SP, PF, reviewer, 10e18, 500e18, 30 days, 30 days);
        safe = new SellarSafe(MUSD, shield, TM, PF, 25, 1 days);
        shield.setSafe(address(safe));

        deal(address(MUSD), ada, 5_000e18);
        deal(address(MUSD), ben, 100e18);
        vm.startPrank(ada);
        MUSD.approve(address(safe), type(uint256).max);
        safe.deposit(ada, 5_000e18);
        safe.configure(agent, 1_000e18, 3_000e18, 0, 0);
        safe.trust(vendor);
        vm.stopPrank();
        vm.prank(ben);
        MUSD.approve(address(shield), type(uint256).max);
    }

    modifier onFork() {
        if (!forked) {
            vm.skip(true);
        }
        _;
    }

    function test_RealMusdHas18Decimals() public onFork {
        assertEq(IERC20Metadata(address(MUSD)).decimals(), 18);
    }

    function test_PayHoldApproveWithRealMusd() public onFork {
        vm.prank(agent);
        (bool paid,) = safe.request(ada, vendor, 100e18, bytes32(0), false);
        assertTrue(paid);
        assertEq(MUSD.balanceOf(vendor), 100e18);

        vm.prank(agent);
        (bool paid2, uint256 id) = safe.request(ada, scammer, 100e18, bytes32(0), false);
        assertFalse(paid2);
        assertEq(MUSD.balanceOf(scammer), 0);
        vm.prank(ada);
        safe.reject(id);
    }

    function test_CoverFundEarnsInTheRealStabilityPool() public onFork {
        deal(address(MUSD), address(shield), 1_000e18);
        shield.rebalance();
        assertEq(shield.fundLiquid(), 250e18);
        assertApproxEqAbs(SP.getCompoundedMUSDDeposit(address(shield)), 750e18, 1e12);
        assertApproxEqAbs(shield.fundAssets(), 1_000e18, 1e12);
        // A second rebalance must never revert, whether or not the pool allows withdrawals right now.
        shield.rebalance();
    }

    function test_ReportConfirmClaimWithRealMusd() public onFork {
        deal(address(MUSD), address(shield), 2_000e18);
        vm.prank(ada);
        safe.trust(scammer);
        vm.prank(agent);
        (bool paid,) = safe.request(ada, scammer, 200e18, bytes32(0), false);
        assertTrue(paid);
        uint256 receiptId = shield.receiptCount() - 1;
        vm.warp(block.timestamp + 1);

        vm.prank(ben);
        shield.report(scammer, keccak256("invoice email"));
        vm.prank(agent);
        (bool paidAgain,) = safe.request(ada, scammer, 50e18, bytes32(0), false);
        assertFalse(paidAgain); // flagged now, so held

        vm.prank(reviewer);
        shield.confirm(scammer);
        uint256 before = MUSD.balanceOf(ada);
        vm.prank(ada);
        shield.claim(receiptId);
        assertEq(MUSD.balanceOf(ada) - before, 200e18);

        uint256 benBefore = MUSD.balanceOf(ben);
        vm.prank(ben);
        shield.withdrawBond(scammer);
        assertEq(MUSD.balanceOf(ben) - benBefore, 10e18);
    }

    function test_LoanHealthReadsRealTroveManager() public onFork {
        (bool hasLoan,) = safe.loanHealth(ada);
        assertFalse(hasLoan);
        // Mezo's price feed reads an oracle precompile that a local fork cannot run, so the price
        // itself is only checked when it is available. On the live chain this call works.
        try PF.fetchPrice{gas: 500_000}() returns (uint256 price) {
            assertGt(price, 0);
        } catch {
            emit log("price oracle precompile is not available in a local fork");
        }
        vm.prank(ada);
        safe.configure(agent, 1_000e18, 3_000e18, 0, 1.5e18);
        // No loan, so the floor has nothing to hold.
        assertEq(safe.check(ada, vendor, 10e18), 0);
    }
}
