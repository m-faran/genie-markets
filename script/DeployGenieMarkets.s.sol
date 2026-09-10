// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {GenieMarkets} from "../src/GenieMarkets.sol";

contract DeployGenieMarkets is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        uint256 subscriptionId = vm.envUint("VRF_SUB_ID");

        // Ethereum Sepolia Configuration
        address vrfCoordinator = 0x9DdfaCa8183c41ad55329BdeeD9F6A8d53168B1B;
        bytes32 keyHash = 0x787d74caea10b2b357790d5b5247c2f63d1d91572a9846f780606e4d953677ae;
        address usdc = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
        
        uint32 callbackGasLimit = 500_000;
        uint32 openDuration = 21 hours;
        uint32 closeDuration = 3 hours;

        vm.startBroadcast(deployerPrivateKey);

        GenieMarkets markets = new GenieMarkets(
            vrfCoordinator,
            subscriptionId,
            keyHash,
            callbackGasLimit,
            usdc,
            openDuration,
            closeDuration
        );

        vm.stopBroadcast();

        console2.log("GenieMarkets deployed to:", address(markets));
    }
}
