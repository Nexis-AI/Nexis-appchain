// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IAgentsRegistry {
    struct InferenceCommitment {
        uint256 agentId;
        bytes32 inputHash;
        bytes32 outputHash;
        bytes32 modelHash;
        uint256 taskId;
        address reporter;
        string proofURI;
        uint64 timestamp;
    }

    struct VerifierAttestation {
        address verifier;
        bool success;
        string uri;
        uint64 timestamp;
    }

    function agentOwner(uint256 agentId) external view returns (address);

    function isAgentRegistered(uint256 agentId) external view returns (bool);

    function stakeBalances(uint256 agentId, address asset)
        external
        view
        returns (uint256 total, uint256 locked, uint256 available);

    function lockStake(uint256 agentId, address asset, uint256 amount) external;

    function unlockStake(uint256 agentId, address asset, uint256 amount) external;

    function slashStake(uint256 agentId, address asset, uint256 amount) external;

    function hasDelegatedPermission(uint256 agentId, address operator, bytes32 permission) external view returns (bool);

    function getInference(bytes32 inferenceId)
        external
        view
        returns (InferenceCommitment memory commitment, VerifierAttestation memory attestation);

    function PERMISSION_INFERENCE() external pure returns (bytes32);

    function PERMISSION_WITHDRAW() external pure returns (bytes32);
}
