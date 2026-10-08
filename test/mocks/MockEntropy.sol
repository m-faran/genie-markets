// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IEntropy, IEntropyConsumer} from "../../src/interfaces/IPythEntropy.sol";

contract MockEntropy is IEntropy {
    uint64 public sequenceNumber;
    uint256 public fee = 0.01 ether;
    address public defaultProvider = address(0x123);

    mapping(uint64 => address) public requestors;
    mapping(uint64 => address) public providers;

    function requestWithCallback(address provider, bytes32 userRandomNumber) external payable returns (uint64) {
        require(msg.value >= fee, "Insufficient fee");

        sequenceNumber++;
        requestors[sequenceNumber] = msg.sender;
        providers[sequenceNumber] = provider;

        return sequenceNumber;
    }

    function fulfillRequest(uint64 reqSeqNumber, bytes32 randomNumber) external {
        address requestor = requestors[reqSeqNumber];
        address provider = providers[reqSeqNumber];

        IEntropyConsumer(requestor).entropyCallback(reqSeqNumber, provider, randomNumber);
    }

    function getFee(address provider) external view returns (uint256) {
        return fee;
    }

    function getDefaultProvider() external view returns (address) {
        return defaultProvider;
    }

    function setFee(uint256 _fee) external {
        fee = _fee;
    }
}
