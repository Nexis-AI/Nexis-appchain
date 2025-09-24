// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ITreasury {
    function handleSlash(uint256 agentId, address asset, uint256 amount) external payable;

    function handleEarlyExitPenalty(uint256 agentId, address asset, uint256 amount) external payable;

    function recordRewardDeposit(address asset, uint256 amount) external payable;

    function distributeReward(
        uint256 agentId,
        address asset,
        uint256 amount,
        address recipient,
        string calldata reason
    ) external;
}
