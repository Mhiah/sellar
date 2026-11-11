// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SellarSafe} from "../src/SellarSafe.sol";
import {SellarShield} from "../src/SellarShield.sol";
import {SellarFaucet} from "../src/SellarFaucet.sol";
import {IStabilityPool, ITroveManager, IPriceFeed} from "../src/interfaces/IMezo.sol";

/// Deploys SellarShield, SellarSafe and (on testnet) SellarFaucet against Mezo's own MUSD contracts.
/// Addresses are from the official package mezo-org/musd-contracts v1.1.0 on npm.
///
///   forge script script/Deploy.s.sol --rpc-url mezo_testnet --broadcast
///
/// Env: PRIVATE_KEY (deployer), REVIEWER (optional, defaults to the deployer).
contract Deploy is Script {
    struct Mezo {
        address musd;
        address stabilityPool;
        address troveManager;
        address priceFeed;
    }

    function mezo() internal view returns (Mezo memory) {
        if (block.chainid == 31611) {
            // Mezo testnet (deployments/matsnet)
            return Mezo({
                musd: 0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503,
                stabilityPool: 0x1CCA7E410eE41739792eA0A24e00349Dd247680e,
                troveManager: 0xE47c80e8c23f6B4A1aE41c34837a0599D5D16bb0,
                priceFeed: 0x86bCF0841622a5dAC14A313a15f96A95421b9366
            });
        }
        if (block.chainid == 31612) {
            // Mezo mainnet (deployments/mainnet)
            return Mezo({
                musd: 0xdD468A1DDc392dcdbEf6db6e34E89AA338F9F186,
                stabilityPool: 0x73245Eff485aB3AAc1158B3c4d8f4b23797B0e32,
                troveManager: 0x94AfB503dBca74aC3E4929BACEeDfCe19B93c193,
                priceFeed: 0xc5aC5A8892230E0A3e1c473881A2de7353fFcA88
            });
        }
        revert("unsupported chain");
    }

    function run() external {
        Mezo memory m = mezo();
        uint256 key = vm.envUint("PRIVATE_KEY");
        address reviewer = vm.envOr("REVIEWER", vm.addr(key));

        vm.startBroadcast(key);
        SellarShield shield = new SellarShield(
            IERC20(m.musd),
            IStabilityPool(m.stabilityPool),
            IPriceFeed(m.priceFeed),
            reviewer,
            10e18, // bond per report: 10 MUSD
            500e18, // largest refund per payment: 500 MUSD
            30 days, // cover window
            30 days // reporters can take bonds back if a case is unresolved this long
        );
        SellarSafe safe = new SellarSafe(
            IERC20(m.musd),
            shield,
            ITroveManager(m.troveManager),
            IPriceFeed(m.priceFeed),
            25, // 0.25% cover fee
            1 days // owner has a day to approve a hold
        );
        shield.setSafe(address(safe));
        // Testnet only: a faucet that puts 25 test MUSD into a new user's safe, once per address.
        address faucet = block.chainid == 31611 ? address(new SellarFaucet(IERC20(m.musd), safe, 25e18)) : address(0);
        vm.stopBroadcast();

        console.log("SellarShield", address(shield));
        console.log("SellarSafe", address(safe));
        console.log("SellarFaucet", faucet);
    }
}
