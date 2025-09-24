// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAgentsRegistry} from "./interfaces/IAgentsRegistry.sol";
import {ITreasury} from "./interfaces/ITreasury.sol";

contract Tasks is Initializable, AccessControlUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    enum TaskStatus {
        Open,
        Claimed,
        Submitted,
        Completed,
        Disputed,
        Cancelled
    }

    struct Task {
        address creator;
        address asset;
        uint256 reward;
        uint256 bond;
        uint256 agentId;
        address claimant;
        uint64 createdAt;
        uint64 claimDeadline;
        uint64 completionDeadline;
        TaskStatus status;
        string metadataURI;
        string inputURI;
        bytes32 inferenceId;
        bool paidOut;
    }

    uint256 public taskCount;
    mapping(uint256 => Task) private _tasks;

    IAgentsRegistry public agents;
    ITreasury public treasury;

    bytes32 public constant DISPUTE_ROLE = keccak256("DISPUTE_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    event TaskCreated(
        uint256 indexed taskId,
        address indexed creator,
        address indexed asset,
        uint256 reward,
        uint256 bond,
        uint64 claimDeadline,
        uint64 completionDeadline,
        string metadataURI
    );
    event TaskCancelled(uint256 indexed taskId, address indexed creator);
    event TaskClaimed(uint256 indexed taskId, uint256 indexed agentId, address indexed claimant, uint256 bond);
    event TaskSubmitted(uint256 indexed taskId, bytes32 inferenceId, address indexed submitter);
    event TaskCompleted(uint256 indexed taskId, uint256 indexed agentId, address indexed recipient, uint256 reward);
    event TaskDisputed(uint256 indexed taskId, uint256 indexed agentId, bytes32 inferenceId);
    event TaskResolved(
        uint256 indexed taskId,
        uint256 indexed agentId,
        bool slashed,
        bool rewardRefunded,
        string reason
    );

    error InvalidAddress();
    error InvalidAmount();
    error InvalidStatus();
    error AuthorizationFailed();
    error DeadlineExpired();
    error NotAgentsContract();
    error AlreadySubmitted();
    error InsufficientStake();

    address internal constant ETH_ASSET = address(0);

    constructor() {
        _disableInitializers();
    }

    function initialize(address admin, address agentsRegistry, address treasuryAddress) external initializer {
        if (admin == address(0) || agentsRegistry == address(0) || treasuryAddress == address(0)) revert InvalidAddress();

        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _setRoleAdmin(DISPUTE_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(PAUSER_ROLE, DEFAULT_ADMIN_ROLE);
        _grantRole(DISPUTE_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);

        agents = IAgentsRegistry(agentsRegistry);
        treasury = ITreasury(treasuryAddress);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function setTreasury(address newTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newTreasury == address(0)) revert InvalidAddress();
        treasury = ITreasury(newTreasury);
    }

    function getTask(uint256 taskId) external view returns (Task memory) {
        return _tasks[taskId];
    }

    function postTask(
        address asset,
        uint256 reward,
        uint256 bond,
        uint64 claimWindow,
        uint64 completionWindow,
        string calldata metadataURI,
        string calldata inputURI
    ) external payable whenNotPaused returns (uint256 taskId) {
        if (reward == 0) revert InvalidAmount();

        if (asset == ETH_ASSET) {
            require(msg.value == reward, "INVALID_VALUE");
        } else {
            require(msg.value == 0, "TOKEN_VALUE");
            IERC20(asset).safeTransferFrom(msg.sender, address(this), reward);
        }

        taskId = ++taskCount;
        Task storage task = _tasks[taskId];
        task.creator = msg.sender;
        task.asset = asset;
        task.reward = reward;
        task.bond = bond;
        task.createdAt = uint64(block.timestamp);
        task.claimDeadline = claimWindow == 0 ? 0 : uint64(block.timestamp) + claimWindow;
        task.completionDeadline = completionWindow == 0 ? 0 : uint64(block.timestamp) + completionWindow;
        task.status = TaskStatus.Open;
        task.metadataURI = metadataURI;
        task.inputURI = inputURI;

        emit TaskCreated(taskId, msg.sender, asset, reward, bond, task.claimDeadline, task.completionDeadline, metadataURI);
    }

    function cancelTask(uint256 taskId) external nonReentrant {
        Task storage task = _tasks[taskId];
        if (task.status != TaskStatus.Open) revert InvalidStatus();
        if (msg.sender != task.creator && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) revert AuthorizationFailed();

        task.status = TaskStatus.Cancelled;
        _payout(task.asset, task.creator, task.reward);
        task.reward = 0;
        task.paidOut = true;

        emit TaskCancelled(taskId, task.creator);
    }

    function claimTask(uint256 taskId, uint256 agentId) external whenNotPaused {
        Task storage task = _tasks[taskId];
        if (task.status != TaskStatus.Open) revert InvalidStatus();
        if (task.claimDeadline != 0 && block.timestamp > task.claimDeadline) revert DeadlineExpired();
        if (!agents.isAgentRegistered(agentId)) revert AuthorizationFailed();

        address owner = agents.agentOwner(agentId);
        bytes32 withdrawPermission = agents.PERMISSION_WITHDRAW();
        if (msg.sender != owner && !agents.hasDelegatedPermission(agentId, msg.sender, withdrawPermission)) {
            revert AuthorizationFailed();
        }

        (uint256 totalStake, , uint256 available) = agents.stakeBalances(agentId, task.asset);
        if (totalStake == 0) revert InsufficientStake();
        if (task.bond > 0) {
            if (available < task.bond) revert InvalidAmount();
            agents.lockStake(agentId, task.asset, task.bond);
        }

        task.status = TaskStatus.Claimed;
        task.agentId = agentId;
        task.claimant = msg.sender;
        task.claimDeadline = 0; // prevent reuse

        if (task.completionDeadline != 0) {
            uint64 allowance = task.completionDeadline - task.createdAt;
            task.completionDeadline = uint64(block.timestamp) + allowance;
        }

        emit TaskClaimed(taskId, agentId, msg.sender, task.bond);
    }

    function submitWork(uint256 taskId, bytes32 inferenceId) external whenNotPaused {
        Task storage task = _tasks[taskId];
        if (task.status != TaskStatus.Claimed) revert InvalidStatus();
        if (task.completionDeadline != 0 && block.timestamp > task.completionDeadline) revert DeadlineExpired();
        if (task.inferenceId != bytes32(0)) revert AlreadySubmitted();

        address owner = agents.agentOwner(task.agentId);
        bytes32 inferencePerm = agents.PERMISSION_INFERENCE();
        if (msg.sender != owner && !agents.hasDelegatedPermission(task.agentId, msg.sender, inferencePerm)) {
            revert AuthorizationFailed();
        }

        (IAgentsRegistry.InferenceCommitment memory commitment, ) = agents.getInference(inferenceId);
        if (commitment.agentId != task.agentId || commitment.taskId != taskId) revert AuthorizationFailed();

        task.inferenceId = inferenceId;
        task.status = TaskStatus.Submitted;

        emit TaskSubmitted(taskId, inferenceId, msg.sender);
    }

    function onInferenceVerified(
        uint256 agentId,
        uint256 taskId,
        bytes32 inferenceId,
        bool success
    ) external {
        if (msg.sender != address(agents)) revert NotAgentsContract();
        Task storage task = _tasks[taskId];
        if (task.agentId != agentId || task.inferenceId != inferenceId) revert InvalidStatus();
        if (task.status != TaskStatus.Submitted) revert InvalidStatus();

        if (success) {
            if (task.bond > 0) {
                agents.unlockStake(agentId, task.asset, task.bond);
                task.bond = 0;
            }
            task.status = TaskStatus.Completed;
            if (!task.paidOut && task.reward > 0) {
                address recipient = agents.agentOwner(agentId);
                _payout(task.asset, recipient, task.reward);
                task.paidOut = true;
                emit TaskCompleted(taskId, agentId, recipient, task.reward);
                task.reward = 0;
            }
        } else {
            task.status = TaskStatus.Disputed;
            emit TaskDisputed(taskId, agentId, inferenceId);
        }
    }

    function resolveDispute(
        uint256 taskId,
        bool slashBond,
        bool refundCreator,
        string calldata reason
    ) external onlyRole(DISPUTE_ROLE) {
        Task storage task = _tasks[taskId];
        if (task.status != TaskStatus.Disputed) revert InvalidStatus();

        if (task.bond > 0) {
            if (slashBond) {
                agents.slashStake(task.agentId, task.asset, task.bond);
            } else {
                agents.unlockStake(task.agentId, task.asset, task.bond);
            }
            task.bond = 0;
        }

        if (task.reward > 0) {
            if (refundCreator) {
                _payout(task.asset, task.creator, task.reward);
            } else {
                if (task.asset == ETH_ASSET) {
                    treasury.recordRewardDeposit{value: task.reward}(task.asset, task.reward);
                } else {
                    IERC20(task.asset).safeTransfer(address(treasury), task.reward);
                    treasury.recordRewardDeposit(task.asset, task.reward);
                }
            }
            task.reward = 0;
            task.paidOut = true;
        }

        task.status = TaskStatus.Completed;
        emit TaskResolved(taskId, task.agentId, slashBond, refundCreator, reason);
    }

    function _payout(address asset, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (asset == ETH_ASSET) {
            (bool success, ) = payable(to).call{value: amount}("");
            require(success, "ETH_TRANSFER_FAILED");
        } else {
            IERC20(asset).safeTransfer(to, amount);
        }
    }

    function _authorizeUpgrade(address newImplementation) internal view override onlyRole(DEFAULT_ADMIN_ROLE) {
        newImplementation;
    }
}
