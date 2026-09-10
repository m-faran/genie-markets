// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

/// @dev Minimal mock VRF coordinator that accepts requests and lets tests trigger fulfillment.
contract MockVRFCoordinator {
    uint256 private _requestId;

    function requestRandomWords(VRFV2PlusClient.RandomWordsRequest calldata) external returns (uint256) {
        return ++_requestId;
    }

    /// @dev Simulate VRF fulfillment by calling rawFulfillRandomWords on the consumer.
    function fulfillRandomWords(uint256 requestId, address consumer, uint256 rawNumber) external {
        uint256[] memory words = new uint256[](1);
        words[0] = rawNumber;
        // Call rawFulfillRandomWords — it checks msg.sender == coordinator
        (bool ok,) =
            consumer.call(abi.encodeWithSignature("rawFulfillRandomWords(uint256,uint256[])", requestId, words));
        require(ok, "VRF fulfillment failed");
    }

    function lastRequestId() external view returns (uint256) {
        return _requestId;
    }
}
