// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {GenieMarkets} from "../src/GenieMarkets.sol";

contract DeployGenieMarkets is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        // Monad Testnet Configuration
        address entropy = 0x36825bf3Fbdf5a29E2d5148bfe7Dcf7B5639e320;
        address defaultProvider = 0x6CC14824Ea2918f5De5C2f75A9Da968ad4BD6344;
        
        // Use a mock USDC or a known ERC20 on Monad Testnet.
        // Replace this with the actual Mock USDC address deployed on Monad testnet.
        address usdc = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;

        uint32 openDuration = 21 hours;
        uint32 closeDuration = 3 hours;

        vm.startBroadcast(deployerPrivateKey);

        GenieMarkets markets = new GenieMarkets(
            entropy, defaultProvider, usdc, openDuration, closeDuration
        );

        vm.stopBroadcast();

        console2.log("GenieMarkets deployed to:", address(markets));
    }
}
