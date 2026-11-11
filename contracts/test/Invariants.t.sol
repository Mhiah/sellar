// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SellarSafe} from "../src/SellarSafe.sol";
import {SellarShield} from "../src/SellarShield.sol";
import {IStabilityPool, ITroveManager, IPriceFeed} from "../src/interfaces/IMezo.sol";
import {MockMUSD, MockStabilityPool, MockTroveManager, MockPriceFeed} from "./mocks/Mocks.sol";

/// Random owners, agents, reporters, a reviewer and a misbehaving Stability Pool.
contract Handler is Test {
    MockMUSD public musd;
    MockStabilityPool public sp;
    SellarShield public shield;
    SellarSafe public safe;
    address public reviewer;

    address[4] public owners;
    address[4] public agents;
    address[5] public payees;
    uint256 public unattendedToUntrusted; // must stay 0

    constructor(MockMUSD musd_, MockStabilityPool sp_, SellarShield shield_, SellarSafe safe_, address reviewer_) {
        musd = musd_;
        sp = sp_;
        shield = shield_;
        safe = safe_;
        reviewer = reviewer_;
        for (uint256 i; i < 4; i++) {
            owners[i] = address(uint160(0x1000 + i));
            agents[i] = address(uint160(0x2000 + i));
            musd.mint(owners[i], 1_000_000e18);
            vm.startPrank(owners[i]);
            musd.approve(address(safe), type(uint256).max);
            musd.approve(address(shield), type(uint256).max);
            safe.configure(agents[i], 200e18, 1_000e18, 0, 0);
            vm.stopPrank();
        }
        for (uint256 i; i < 5; i++) {
            payees[i] = address(uint160(0x3000 + i));
        }
        vm.deal(address(sp), 100 ether);
    }

    function deposit(uint256 o, uint256 amount) external {
        o %= 4;
        amount = bound(amount, 1, 10_000e18);
        vm.prank(owners[o]);
        safe.deposit(owners[o], amount);
    }

    function withdraw(uint256 o, uint256 amount) external {
        o %= 4;
        (,,,,,,, uint256 bal,) = safe.accounts(owners[o]);
        if (bal == 0) return;
        vm.prank(owners[o]);
        safe.withdraw(bound(amount, 1, bal));
    }

    function trust(uint256 o, uint256 p, bool on) external {
        vm.prank(owners[o % 4]);
        if (on) try safe.trust(payees[p % 5]) {} catch {}
        else safe.untrust(payees[p % 5]);
    }

    function request(uint256 o, uint256 p, uint128 amount) external {
        o %= 4;
        address to = payees[p % 5];
        amount = uint128(bound(amount, 1, 400e18));
        bool trusted = safe.trustedAt(owners[o], to) != 0;
        vm.prank(agents[o]);
        try safe.request(owners[o], to, amount, bytes32(0), false) returns (bool paid, uint256) {
            if (paid && (!trusted || amount > 200e18)) unattendedToUntrusted++;
        } catch {}
    }

    function approveOrReject(uint256 id, bool yes) external {
        uint256 n = safe.holdCount();
        if (n == 0) return;
        id %= n;
        (address owner,,,,,,) = safe.holds(id);
        vm.prank(owner);
        if (yes) try safe.approve(id, true) {} catch {}
        else try safe.reject(id) {} catch {}
    }

    function report(uint256 o, uint256 p) external {
        vm.prank(owners[o % 4]);
        try shield.report(payees[p % 5], bytes32(0)) {} catch {}
    }

    function resolve(uint256 p, bool confirm) external {
        vm.prank(reviewer);
        if (confirm) try shield.confirm(payees[p % 5]) {} catch {}
        else try shield.dismiss(payees[p % 5]) {} catch {}
    }

    function withdrawBond(uint256 o, uint256 p) external {
        vm.prank(owners[o % 4]);
        try shield.withdrawBond(payees[p % 5]) {} catch {}
    }

    function claim(uint256 id) external {
        uint256 n = shield.receiptCount();
        if (n == 0) return;
        id %= n;
        (address payer,,,,) = shield.receipts(id);
        vm.prank(payer);
        try shield.claim(id) {} catch {}
    }

    function rebalance() external {
        shield.rebalance();
    }

    function poolLiquidation(uint256 lossBps, uint256 btc) external {
        uint256 d = sp.deposits(address(shield));
        if (d == 0) return;
        sp.liquidate(address(shield), d * bound(lossBps, 0, 10_000) / 10_000, bound(btc, 0, 0.01 ether));
    }

    function poolPause(bool p) external {
        sp.setPaused(p);
    }

    function skipTime(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 3 days));
    }

    function sumBalances() external view returns (uint256 total) {
        for (uint256 i; i < 4; i++) {
            (,,,,,,, uint256 bal,) = safe.accounts(owners[i]);
            total += bal;
        }
    }
}

contract InvariantsTest is Test {
    MockMUSD musd;
    MockStabilityPool sp;
    SellarShield shield;
    SellarSafe safe;
    Handler handler;

    function setUp() public {
        vm.warp(1_800_000_000);
        address reviewer = makeAddr("reviewer");
        musd = new MockMUSD();
        sp = new MockStabilityPool(IERC20(address(musd)));
        shield = new SellarShield(
            IERC20(address(musd)), IStabilityPool(address(sp)), reviewer, 10e18, 500e18, 30 days, 30 days
        );
        safe = new SellarSafe(
            IERC20(address(musd)),
            shield,
            ITroveManager(address(new MockTroveManager())),
            IPriceFeed(address(new MockPriceFeed())),
            25,
            1 days
        );
        shield.setSafe(address(safe));
        handler = new Handler(musd, sp, shield, safe, reviewer);
        targetContract(address(handler));
    }

    /// The safe always holds exactly what its owners are owed.
    function invariant_SafeIsFullyBacked() public view {
        assertEq(musd.balanceOf(address(safe)), handler.sumBalances());
    }

    /// Reporter bonds are always in the shield, whatever the cover fund and the pool do.
    function invariant_BondsAreAlwaysLiquid() public view {
        assertGe(musd.balanceOf(address(shield)), shield.bondsHeld());
    }

    /// BTC promised to reporters is always there.
    function invariant_BtcRewardsAreReserved() public view {
        assertGe(address(shield).balance, shield.btcReserved());
    }

    /// No payment ever left unattended to an untrusted payee or above the per-payment limit.
    function invariant_NoUnattendedPaymentBreaksRules() public view {
        assertEq(handler.unattendedToUntrusted(), 0);
    }
}
