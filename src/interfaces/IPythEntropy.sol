// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IEntropyConsumer {
    function entropyCallback(
        uint64 sequenceNumber,
        address provider,
        bytes32 randomNumber
    ) external;
}

interface IEntropy {
    function requestWithCallback(
        address provider,
        bytes32 userRandomNumber
    ) external payable returns (uint64 sequenceNumber);

    function getFee(address provider) external view returns (uint256 feeAmount);

    function getDefaultProvider() external view returns (address provider);
}
