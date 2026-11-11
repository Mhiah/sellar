// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "./Base.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SellarFaucet} from "../src/SellarFaucet.sol";
import {SellarSafe} from "../src/SellarSafe.sol";

contract SellarFaucetTest is Base {
    SellarFaucet faucet;
    address judge = makeAddr("judge");

    function setUp() public override {
        super.setUp();
        faucet = new SellarFaucet(IERC20(address(musd)), safe, 25e18);
        musd.mint(address(faucet), 60e18);
    }

    function _balance(address who) internal view returns (uint256 bal) {
        (,,,,,,, bal,) = safe.accounts(who);
    }

    function test_DripLandsInTheCallersSafe() public {
        vm.prank(judge);
        faucet.drip();
        assertEq(_balance(judge), 25e18);
        assertEq(musd.balanceOf(judge), 0);
        assertEq(faucet.remaining(), 1);
    }

    function test_OncePerAddress() public {
        vm.startPrank(judge);
        faucet.drip();
        vm.expectRevert(SellarFaucet.AlreadyClaimed.selector);
        faucet.drip();
        vm.stopPrank();
    }

    function test_EmptyFaucetSaysSo() public {
        vm.prank(judge);
        faucet.drip();
        vm.prank(ben);
        faucet.drip();
        vm.prank(chidi);
        vm.expectRevert(SellarFaucet.Empty.selector);
        faucet.drip();
    }

    /// The whole try-it path with one wallet: get MUSD, act as your own agent, get held, release.
    function test_TryItPathWithOneWallet() public {
        address stranger = makeAddr("stranger");
        vm.startPrank(judge);
        faucet.drip();
        safe.configure(judge, 10e18, 20e18, 0, 0);
        (bool paid, uint256 id) = safe.request(judge, stranger, 5e18, bytes32(0), false);
        assertFalse(paid);
        assertEq(musd.balanceOf(stranger), 0);
        safe.approve(id, false);
        vm.stopPrank();
        assertEq(musd.balanceOf(stranger), 5e18);
    }
}
