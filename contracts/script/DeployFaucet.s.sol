// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SellarFaucet} from "../src/SellarFaucet.sol";
import {SellarSafe} from "../src/SellarSafe.sol";

/// Deploys the testnet faucet (25 MUSD per address) for the deployed SellarSafe.
contract DeployFaucet is Script {
    function run() external {
        require(block.chainid == 31611, "testnet only");
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        SellarFaucet faucet = new SellarFaucet(
            IERC20(0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503),
            SellarSafe(0x9bf0180a21fFfB35b815Bf0B264706E72e0a26Aa),
            25e18
        );
        vm.stopBroadcast();
        console.log("SellarFaucet", address(faucet));
    }
}
