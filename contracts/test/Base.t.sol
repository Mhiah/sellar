// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SellarSafe} from "../src/SellarSafe.sol";
import {SellarShield} from "../src/SellarShield.sol";
import {IStabilityPool, ITroveManager, IPriceFeed} from "../src/interfaces/IMezo.sol";
import {MockMUSD, MockStabilityPool, MockTroveManager, MockPriceFeed} from "./mocks/Mocks.sol";

abstract contract Base is Test {
    MockMUSD musd;
    MockStabilityPool sp;
    MockTroveManager tm;
    MockPriceFeed pf;
    SellarShield shield;
    SellarSafe safe;

    address reviewer = makeAddr("reviewer");
    address ada = makeAddr("ada"); // account owner
    address agent = makeAddr("agent"); // ada's AI agent key
    address vendor = makeAddr("vendor"); // a payee ada trusts
    address scammer = makeAddr("scammer");
    address ben = makeAddr("ben");
    address chidi = makeAddr("chidi");

    uint256 constant BOND = 10e18;
    uint256 constant CLAIM_CAP = 500e18;
    uint256 constant COVER_WINDOW = 30 days;
    uint256 constant RESOLVE_TIMEOUT = 30 days;
    uint256 constant FEE_BPS = 25;
    uint256 constant HOLD_TTL = 1 days;

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        musd = new MockMUSD();
        sp = new MockStabilityPool(IERC20(address(musd)));
        tm = new MockTroveManager();
        pf = new MockPriceFeed();
        shield = new SellarShield(
            IERC20(address(musd)),
            IStabilityPool(address(sp)),
            IPriceFeed(address(pf)),
            reviewer,
            BOND,
            CLAIM_CAP,
            COVER_WINDOW,
            RESOLVE_TIMEOUT
        );
        safe = new SellarSafe(
            IERC20(address(musd)), shield, ITroveManager(address(tm)), IPriceFeed(address(pf)), FEE_BPS, HOLD_TTL
        );
        shield.setSafe(address(safe));

        _fund(ada, 10_000e18);
        vm.startPrank(ada);
        safe.deposit(ada, 5_000e18);
        safe.configure(agent, 100e18, 300e18, 1 hours, 0);
        safe.trust(vendor);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 hours);
    }

    function _fund(address who, uint256 amount) internal {
        musd.mint(who, amount);
        vm.startPrank(who);
        musd.approve(address(safe), type(uint256).max);
        musd.approve(address(shield), type(uint256).max);
        vm.stopPrank();
    }

    function _report(address reporter, address suspect) internal {
        if (musd.balanceOf(reporter) < BOND) _fund(reporter, BOND);
        vm.prank(reporter);
        shield.report(suspect, keccak256("evidence"));
    }

    function _request(address to, uint128 amount) internal returns (bool paid, uint256 holdId) {
        vm.prank(agent);
        return safe.request(ada, to, amount, bytes32(0), false);
    }
}
