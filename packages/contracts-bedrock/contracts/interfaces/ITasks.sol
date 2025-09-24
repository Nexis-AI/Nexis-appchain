// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ITasks {
    function onInferenceVerified(
        uint256 agentId,
        uint256 taskId,
        bytes32 inferenceId,
        bool success
    ) external;
}
