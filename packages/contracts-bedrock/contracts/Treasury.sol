// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAgentsRegistry} from "./interfaces/IAgentsRegistry.sol";

contract Treasury is Initializable, AccessControlUpgradeable, ReentrancyGuardUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    uint16 internal constant BPS_DENOMINATOR = 10_000;
    address internal constant ETH_ASSET = address(0);

    bytes32 public constant REWARDS_ROLE = keccak256("REWARDS_ROLE");
    bytes32 public constant WITHDRAW_ROLE = keccak256("WITHDRAW_ROLE");
    bytes32 public constant INFLOW_ROLE = keccak256("INFLOW_ROLE");

    struct DistributionConfig {
        uint16 treasuryBps;
        uint16 insuranceBps;
        uint16 rewardsBps;
    }

    struct PoolBalances {
        uint256 treasury;
        uint256 insurance;
        uint256 rewards;
    }

    DistributionConfig public distribution;
    IAgentsRegistry public agents;

    mapping(address => PoolBalances) private _pools;

    event DistributionUpdated(uint16 treasuryBps, uint16 insuranceBps, uint16 rewardsBps);
    event SlashHandled(
        uint256 indexed agentId,
        address indexed asset,
        uint256 amount,
        uint256 treasuryShare,
        uint256 insuranceShare,
        uint256 rewardsShare
    );
    event EarlyExitHandled(
        uint256 indexed agentId,
        address indexed asset,
        uint256 amount,
        uint256 treasuryShare,
        uint256 insuranceShare,
        uint256 rewardsShare
    );
    event RewardsDeposited(address indexed source, address indexed asset, uint256 amount);
    event RewardPaid(
        uint256 indexed agentId,
        address indexed asset,
        address indexed recipient,
        uint256 amount,
        string reason
    );
    event PoolWithdrawn(bytes32 indexed pool, address indexed asset, address indexed to, uint256 amount);

    error InvalidBps();
    error InvalidAddress();
    error InsufficientRewards(address asset, uint256 requested, uint256 available);
    error AgentNotKnown(uint256 agentId);

    constructor() {
        _disableInitializers();
    }

    function initialize(address admin, address agentsRegistry) external initializer {
        if (admin == address(0) || agentsRegistry == address(0)) revert InvalidAddress();

        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _setRoleAdmin(REWARDS_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(WITHDRAW_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(INFLOW_ROLE, DEFAULT_ADMIN_ROLE);

        agents = IAgentsRegistry(agentsRegistry);
        distribution = DistributionConfig({treasuryBps: 4_000, insuranceBps: 3_000, rewardsBps: 3_000});
        emit DistributionUpdated(4_000, 3_000, 3_000);

        _grantRole(INFLOW_ROLE, admin);
        _grantRole(REWARDS_ROLE, admin);
        _grantRole(WITHDRAW_ROLE, admin);
    }

    function setDistribution(uint16 treasuryBps, uint16 insuranceBps, uint16 rewardsBps)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (treasuryBps + insuranceBps + rewardsBps != BPS_DENOMINATOR) revert InvalidBps();
        distribution = DistributionConfig(treasuryBps, insuranceBps, rewardsBps);
        emit DistributionUpdated(treasuryBps, insuranceBps, rewardsBps);
    }

    function setAgents(address newAgents) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newAgents == address(0)) revert InvalidAddress();
        agents = IAgentsRegistry(newAgents);
    }

    function handleSlash(uint256 agentId, address asset, uint256 amount)
        external
        payable
        onlyRole(INFLOW_ROLE)
    {
        _handleInflow(agentId, asset, amount, msg.value, true);
    }

    function handleEarlyExitPenalty(uint256 agentId, address asset, uint256 amount)
        external
        payable
        onlyRole(INFLOW_ROLE)
    {
        _handleInflow(agentId, asset, amount, msg.value, false);
    }

    function recordRewardDeposit(address asset, uint256 amount) external payable {
        if (asset == ETH_ASSET) {
            require(msg.value == amount, "MISMATCH_VALUE");
        }
        if (asset != ETH_ASSET) {
            // tokens must have been transferred prior to this call
            require(msg.value == 0, "TOKEN_NO_VALUE");
        }
        _pools[asset].rewards += amount;
        emit RewardsDeposited(msg.sender, asset, amount);
    }

    function distributeReward(
        uint256 agentId,
        address asset,
        uint256 amount,
        address recipient,
        string calldata reason
    ) external nonReentrant onlyRole(REWARDS_ROLE) {
        if (!agents.isAgentRegistered(agentId)) revert AgentNotKnown(agentId);
        PoolBalances storage pool = _pools[asset];
        if (pool.rewards < amount) revert InsufficientRewards(asset, amount, pool.rewards);
        pool.rewards -= amount;

        address target = recipient == address(0) ? agents.agentOwner(agentId) : recipient;
        if (asset == ETH_ASSET) {
            (bool success, ) = payable(target).call{value: amount}("");
            require(success, "ETH_TRANSFER_FAILED");
        } else {
            IERC20(asset).safeTransfer(target, amount);
        }

        emit RewardPaid(agentId, asset, target, amount, reason);
    }

    function withdrawTreasury(address asset, uint256 amount, address to)
        external
        nonReentrant
        onlyRole(WITHDRAW_ROLE)
    {
        _withdraw(bytes32("TREASURY"), _pools[asset].treasury, amount, asset, to);
        _pools[asset].treasury -= amount;
    }

    function withdrawInsurance(address asset, uint256 amount, address to)
        external
        nonReentrant
        onlyRole(WITHDRAW_ROLE)
    {
        _withdraw(bytes32("INSURANCE"), _pools[asset].insurance, amount, asset, to);
        _pools[asset].insurance -= amount;
    }

    function rewardsBalance(address asset) external view returns (uint256) {
        return _pools[asset].rewards;
    }

    function poolBalances(address asset) external view returns (PoolBalances memory) {
        return _pools[asset];
    }

    function _handleInflow(
        uint256 agentId,
        address asset,
        uint256 amount,
        uint256 msgValue,
        bool isSlash
    ) internal {
        require(amount > 0, "ZERO_AMOUNT");
        if (asset == ETH_ASSET) {
            require(msgValue == amount, "MISMATCH_VALUE");
        } else {
            require(msgValue == 0, "TOKEN_NO_VALUE");
        }

        DistributionConfig memory dist = distribution;
        uint256 treasuryShare = (amount * dist.treasuryBps) / BPS_DENOMINATOR;
        uint256 insuranceShare = (amount * dist.insuranceBps) / BPS_DENOMINATOR;
        uint256 rewardsShare = amount - treasuryShare - insuranceShare;

        PoolBalances storage pool = _pools[asset];
        pool.treasury += treasuryShare;
        pool.insurance += insuranceShare;
        pool.rewards += rewardsShare;

        if (isSlash) {
            emit SlashHandled(agentId, asset, amount, treasuryShare, insuranceShare, rewardsShare);
        } else {
            emit EarlyExitHandled(agentId, asset, amount, treasuryShare, insuranceShare, rewardsShare);
        }
    }

    function _withdraw(
        bytes32 pool,
        uint256 currentBalance,
        uint256 amount,
        address asset,
        address to
    ) internal {
        require(to != address(0), "INVALID_TO");
        require(amount <= currentBalance, "INSUFFICIENT_BAL");
        if (asset == ETH_ASSET) {
            (bool success, ) = payable(to).call{value: amount}("");
            require(success, "ETH_TRANSFER_FAILED");
        } else {
            IERC20(asset).safeTransfer(to, amount);
        }
        emit PoolWithdrawn(pool, asset, to, amount);
    }

    function _authorizeUpgrade(address newImplementation) internal view override onlyRole(DEFAULT_ADMIN_ROLE) {
        newImplementation;
    }
}
