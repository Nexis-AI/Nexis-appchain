// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ITreasury} from "./interfaces/ITreasury.sol";
import {ITasks} from "./interfaces/ITasks.sol";

/**
 * @title Agents
 * @notice Registry and economic coordination layer for Nexis AI agents with staking, delegation,
 *         proof-of-inference, and treasury integrations. Implemented as an upgradeable (UUPS) module.
 */
contract Agents is Initializable, AccessControlUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Roles & permissions
    // -------------------------------------------------------------------------

    bytes32 public constant SLASHER_ROLE = keccak256("SLASHER_ROLE");
    bytes32 public constant REPUTATION_ROLE = keccak256("REPUTATION_ROLE");
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    bytes32 public constant CONTRIBUTION_ROLE = keccak256("CONTRIBUTION_ROLE");
    bytes32 public constant VERIFIER_ROLE = keccak256("VERIFIER_ROLE");
    bytes32 public constant TASK_MODULE_ROLE = keccak256("TASK_MODULE_ROLE");

    bytes32 public constant PERMISSION_METADATA = keccak256("PERMISSION_METADATA");
    bytes32 public constant PERMISSION_INFERENCE = keccak256("PERMISSION_INFERENCE");
    bytes32 public constant PERMISSION_WITHDRAW = keccak256("PERMISSION_WITHDRAW");

    bytes32 internal constant DIM_RELIABILITY = keccak256("reliability");
    bytes32 internal constant DIM_ACCURACY = keccak256("accuracy");
    bytes32 internal constant DIM_PERFORMANCE = keccak256("performance");
    bytes32 internal constant DIM_TRUSTWORTHINESS = keccak256("trustworthiness");

    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    uint16 internal constant BPS_DENOMINATOR = 10_000;
    address internal constant ETH_ASSET = address(0);

    struct PendingWithdrawal {
        uint256 amount;
        uint64 releaseTime;
    }

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

    struct AgentSummary {
        uint256 agentId;
        address owner;
        string metadata;
        string serviceURI;
        uint256 totalStake;
        uint256 lockedStake;
        int256 weightedReputation;
    }

    struct AggregatedStats {
        uint256 totalAgents;
        address[] assets;
        uint256[] totalStakedPerAsset;
    }

    struct StakeView {
        uint256 total;
        uint256 locked;
        uint256 available;
    }

    struct ReputationDelta {
        bytes32 dimension;
        int256 delta;
        string reason;
    }

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------

    mapping(uint256 => string) private _serviceURI;
    mapping(uint256 => address) public agentOwner;
    mapping(uint256 => string) public agentMetadata;
    mapping(uint256 => uint256) public contributionCount;

    mapping(uint256 => mapping(address => uint256)) private _staked;
    mapping(uint256 => mapping(address => uint256)) private _lockedStake;
    mapping(uint256 => mapping(address => PendingWithdrawal[])) private _withdrawalQueue;
    mapping(uint256 => mapping(address => uint256)) private _withdrawalHead;

    mapping(address => uint64) public unbondingPeriod;
    mapping(address => uint16) public earlyExitPenaltyBps;

    mapping(uint256 => mapping(bytes32 => int256)) private _reputationScores;
    mapping(bytes32 => uint256) public reputationWeights;
    bytes32[] private _reputationDimensions;

    mapping(uint256 => mapping(bytes32 => mapping(address => bool))) private _delegations;

    mapping(uint256 => uint256) private _agentInferenceNonce;
    mapping(bytes32 => InferenceCommitment) private _inferenceById;
    mapping(bytes32 => VerifierAttestation) private _attestations;
    mapping(uint256 => bytes32[]) private _agentInferenceIds;

    uint256[] private _agentIndex;
    mapping(uint256 => uint256) private _agentIndexLookup; // id => index+1

    mapping(address => uint256) private _totalStakedPerAsset;
    mapping(address => bool) private _trackedAsset;
    address[] private _trackedAssets;

    ITreasury public treasury;
    ITasks public tasksContract;
    address public proofVerifier;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event AgentRegistered(address indexed owner, uint256 indexed agentId, string metadata, string serviceURI);
    event AgentMetadataUpdated(uint256 indexed agentId, string metadata);
    event AgentServiceURIUpdated(uint256 indexed agentId, string serviceURI);
    event AgentOwnershipTransferred(uint256 indexed agentId, address indexed previousOwner, address indexed newOwner);

    event StakeIncreased(
        uint256 indexed agentId,
        address indexed asset,
        address indexed staker,
        uint256 amount,
        uint256 totalStaked
    );
    event StakeLocked(uint256 indexed agentId, address indexed asset, uint256 amount, uint256 newLockedBalance);
    event StakeUnlocked(uint256 indexed agentId, address indexed asset, uint256 amount, uint256 newLockedBalance);
    event UnbondingInitiated(uint256 indexed agentId, address indexed asset, uint256 amount, uint64 releaseTime);
    event WithdrawalCancelled(uint256 indexed agentId, address indexed asset, uint256 amount);
    event WithdrawalExecuted(uint256 indexed agentId, address indexed asset, uint256 amount, address indexed receiver);
    event EarlyWithdrawal(uint256 indexed agentId, address indexed asset, uint256 amount, uint256 penalty, address receiver);
    event StakeSlashed(uint256 indexed agentId, address indexed asset, uint256 amount);

    event UnbondingPeriodUpdated(address indexed asset, uint64 period);
    event EarlyExitPenaltyUpdated(address indexed asset, uint16 bps);
    event TreasuryUpdated(address indexed newTreasury);
    event TasksContractUpdated(address indexed newTasksContract);
    event ProofVerifierUpdated(address indexed verifier);

    event InferenceRecorded(
        uint256 indexed agentId,
        bytes32 indexed inferenceId,
        bytes32 indexed inputHash,
        bytes32 outputHash,
        bytes32 modelHash,
        uint256 taskId,
        address reporter,
        string proofURI
    );
    event InferenceAttested(
        bytes32 indexed inferenceId,
        uint256 indexed agentId,
        uint256 indexed taskId,
        address verifier,
        bool success,
        string uri
    );

    event ReputationAdjusted(uint256 indexed agentId, bytes32 indexed dimension, int256 newScore, string reason);
    event ReputationWeightUpdated(bytes32 indexed dimension, uint256 weight);
    event DelegateUpdated(uint256 indexed agentId, address indexed delegate, bytes32 indexed permission, bool enabled);
    event ContributionLogged(
        uint256 indexed agentId,
        uint256 indexed contributionId,
        address indexed contributor,
        string evidenceURI,
        string metadata
    );

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error AgentAlreadyRegistered(uint256 agentId, address currentOwner);
    error AgentNotRegistered(uint256 agentId);
    error NotAgentOwner(uint256 agentId, address expectedOwner, address actualCaller);
    error ZeroAmount();
    error AmountTooLarge(uint256 requested, uint256 available);
    error NothingToWithdraw(uint256 agentId, address asset);
    error UnauthorizedContribution(uint256 agentId, address caller);
    error UnauthorizedDelegate(address delegate);
    error InvalidPermission(bytes32 permission);
    error InvalidPagination();
    error UnknownInference(bytes32 inferenceId);
    error TreasuryRequired();

    // -------------------------------------------------------------------------
    // Modifiers & internals
    // -------------------------------------------------------------------------

    modifier onlyAgentOwner(uint256 agentId) {
        address owner = agentOwner[agentId];
        if (owner == address(0)) revert AgentNotRegistered(agentId);
        if (owner != msg.sender) revert NotAgentOwner(agentId, owner, msg.sender);
        _;
    }

    modifier onlyOwnerOrDelegate(uint256 agentId, bytes32 permission) {
        if (!_isAuthorized(agentId, permission, msg.sender)) {
            revert UnauthorizedDelegate(msg.sender);
        }
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(address admin, address treasury_) external initializer {
        if (treasury_ == address(0)) revert TreasuryRequired();

        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _setRoleAdmin(SLASHER_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(REPUTATION_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(ORACLE_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(CONTRIBUTION_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(VERIFIER_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(TASK_MODULE_ROLE, DEFAULT_ADMIN_ROLE);

        treasury = ITreasury(treasury_);

        // default seven day unbonding period for ETH
        unbondingPeriod[ETH_ASSET] = 7 days;

        // set initial reputation dimensions and weights (equal weighting)
        _reputationDimensions = [DIM_RELIABILITY, DIM_ACCURACY, DIM_PERFORMANCE, DIM_TRUSTWORTHINESS];
        uint256 equalWeight = BPS_DENOMINATOR / _reputationDimensions.length;
        for (uint256 i; i < _reputationDimensions.length; i++) {
            reputationWeights[_reputationDimensions[i]] = equalWeight;
            emit ReputationWeightUpdated(_reputationDimensions[i], equalWeight);
        }
    }

    // -------------------------------------------------------------------------
    // Admin
    // -------------------------------------------------------------------------

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function setTreasury(address newTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newTreasury == address(0)) revert TreasuryRequired();
        treasury = ITreasury(newTreasury);
        emit TreasuryUpdated(newTreasury);
    }

    function setTasksContract(address newTasksContract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        tasksContract = ITasks(newTasksContract);
        emit TasksContractUpdated(newTasksContract);
    }

    function setProofVerifier(address verifier) external onlyRole(DEFAULT_ADMIN_ROLE) {
        proofVerifier = verifier;
        emit ProofVerifierUpdated(verifier);
    }

    function setEarlyExitPenalty(address asset, uint16 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(bps <= BPS_DENOMINATOR, "INVALID_BPS");
        earlyExitPenaltyBps[asset] = bps;
        emit EarlyExitPenaltyUpdated(asset, bps);
    }

    function setUnbondingPeriod(address asset, uint64 period) external onlyRole(DEFAULT_ADMIN_ROLE) {
        unbondingPeriod[asset] = period;
        emit UnbondingPeriodUpdated(asset, period);
    }

    function updateReputationWeight(bytes32 dimension, uint256 weight) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(weight <= BPS_DENOMINATOR, "INVALID_WEIGHT");
        reputationWeights[dimension] = weight;
        bool exists;
        for (uint256 i; i < _reputationDimensions.length; i++) {
            if (_reputationDimensions[i] == dimension) {
                exists = true;
                break;
            }
        }
        if (!exists) {
            _reputationDimensions.push(dimension);
        }
        emit ReputationWeightUpdated(dimension, weight);
    }

    // -------------------------------------------------------------------------
    // Agent registration & metadata
    // -------------------------------------------------------------------------

    function register(uint256 agentId, string calldata metadata, string calldata serviceURI) external whenNotPaused {
        if (agentOwner[agentId] != address(0)) {
            revert AgentAlreadyRegistered(agentId, agentOwner[agentId]);
        }

        agentOwner[agentId] = msg.sender;
        agentMetadata[agentId] = metadata;
        _serviceURI[agentId] = serviceURI;

        _agentIndexLookup[agentId] = _agentIndex.length + 1;
        _agentIndex.push(agentId);

        emit AgentRegistered(msg.sender, agentId, metadata, serviceURI);
    }

    function updateMetadata(uint256 agentId, string calldata metadata)
        external
        onlyOwnerOrDelegate(agentId, PERMISSION_METADATA)
    {
        agentMetadata[agentId] = metadata;
        emit AgentMetadataUpdated(agentId, metadata);
    }

    function updateServiceURI(uint256 agentId, string calldata serviceURI)
        external
        onlyOwnerOrDelegate(agentId, PERMISSION_METADATA)
    {
        _serviceURI[agentId] = serviceURI;
        emit AgentServiceURIUpdated(agentId, serviceURI);
    }

    function transferAgentOwnership(uint256 agentId, address newOwner) external onlyAgentOwner(agentId) {
        require(newOwner != address(0), "INVALID_OWNER");
        address previousOwner = agentOwner[agentId];
        agentOwner[agentId] = newOwner;
        emit AgentOwnershipTransferred(agentId, previousOwner, newOwner);
    }

    function agentServiceURI(uint256 agentId) external view returns (string memory) {
        return _serviceURI[agentId];
    }

    function isAgentRegistered(uint256 agentId) public view returns (bool) {
        return agentOwner[agentId] != address(0);
    }

    // -------------------------------------------------------------------------
    // Delegation
    // -------------------------------------------------------------------------

    function setDelegate(
        uint256 agentId,
        address delegate,
        bytes32 permission,
        bool enabled
    ) external onlyAgentOwner(agentId) {
        if (permission != PERMISSION_METADATA && permission != PERMISSION_INFERENCE && permission != PERMISSION_WITHDRAW) {
            revert InvalidPermission(permission);
        }
        _delegations[agentId][permission][delegate] = enabled;
        emit DelegateUpdated(agentId, delegate, permission, enabled);
    }

    function hasDelegatedPermission(uint256 agentId, address operator, bytes32 permission) public view returns (bool) {
        return _delegations[agentId][permission][operator];
    }

    function _isAuthorized(uint256 agentId, bytes32 permission, address operator) internal view returns (bool) {
        address owner = agentOwner[agentId];
        if (owner == address(0)) revert AgentNotRegistered(agentId);
        if (operator == owner) return true;
        if (hasDelegatedPermission(agentId, operator, permission)) return true;
        if (permission == PERMISSION_INFERENCE && hasRole(ORACLE_ROLE, operator)) return true;
        return false;
    }

    // -------------------------------------------------------------------------
    // Staking
    // -------------------------------------------------------------------------

    function stakeERC20(uint256 agentId, address token, uint256 amount) external nonReentrant whenNotPaused {
        _requireAgentExists(agentId);
        if (amount == 0) revert ZeroAmount();

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        _increaseStake(agentId, token, amount);

        emit StakeIncreased(agentId, token, msg.sender, amount, _staked[agentId][token]);
    }

    function stakeETH(uint256 agentId) external payable nonReentrant whenNotPaused {
        _requireAgentExists(agentId);
        if (msg.value == 0) revert ZeroAmount();

        _increaseStake(agentId, ETH_ASSET, msg.value);

        emit StakeIncreased(agentId, ETH_ASSET, msg.sender, msg.value, _staked[agentId][ETH_ASSET]);
    }

    function _increaseStake(uint256 agentId, address asset, uint256 amount) internal {
        _staked[agentId][asset] += amount;
        _totalStakedPerAsset[asset] += amount;
        if (!_trackedAsset[asset]) {
            _trackedAsset[asset] = true;
            _trackedAssets.push(asset);
        }
    }

    function requestWithdrawal(uint256 agentId, address asset, uint256 amount)
        external
        whenNotPaused
        onlyOwnerOrDelegate(agentId, PERMISSION_WITHDRAW)
    {
        if (amount == 0) revert ZeroAmount();
        uint256 currentStake = _staked[agentId][asset];
        if (currentStake == 0) revert AmountTooLarge(amount, 0);
        uint256 locked = _lockedStake[agentId][asset];
        uint256 available = currentStake - locked;
        if (amount > available) revert AmountTooLarge(amount, available);

        _staked[agentId][asset] = currentStake - amount;
        _totalStakedPerAsset[asset] -= amount;

        uint64 releaseTime = uint64(block.timestamp + unbondingPeriod[asset]);
        _withdrawalQueue[agentId][asset].push(PendingWithdrawal({amount: amount, releaseTime: releaseTime}));

        emit UnbondingInitiated(agentId, asset, amount, releaseTime);
    }

    function cancelWithdrawal(
        uint256 agentId,
        address asset,
        uint256 queueIndex
    ) external whenNotPaused onlyOwnerOrDelegate(agentId, PERMISSION_WITHDRAW) {
        PendingWithdrawal[] storage queue = _withdrawalQueue[agentId][asset];
        uint256 head = _withdrawalHead[agentId][asset];
        uint256 actualIndex = head + queueIndex;
        if (actualIndex >= queue.length) revert InvalidPagination();
        uint256 amount = queue[actualIndex].amount;
        if (amount == 0) revert NothingToWithdraw(agentId, asset);

        queue[actualIndex].amount = 0;
        _staked[agentId][asset] += amount;
        _totalStakedPerAsset[asset] += amount;

        emit WithdrawalCancelled(agentId, asset, amount);
    }

    function claimWithdrawals(
        uint256 agentId,
        address asset,
        uint256 maxEntries,
        address receiver,
        bool forceEarly
    )
        external
        nonReentrant
        whenNotPaused
        onlyOwnerOrDelegate(agentId, PERMISSION_WITHDRAW)
        returns (uint256 releasedAmount, uint256 penaltyAmount)
    {
        PendingWithdrawal[] storage queue = _withdrawalQueue[agentId][asset];
        uint256 queueLength = queue.length;
        if (queueLength == 0) revert NothingToWithdraw(agentId, asset);

        uint256 cursor = _withdrawalHead[agentId][asset];
        uint256 processed;
        uint256 limit = maxEntries == 0 ? type(uint256).max : maxEntries;
        uint256 penaltyBps = earlyExitPenaltyBps[asset];

        while (cursor < queueLength && processed < limit) {
            PendingWithdrawal storage entry = queue[cursor];
            uint256 amount = entry.amount;

            if (amount == 0) {
                unchecked {
                    cursor++;
                    processed++;
                }
                continue;
            }

            uint256 releaseTime = entry.releaseTime;
            if (releaseTime > block.timestamp && !forceEarly) {
                break;
            }

            entry.amount = 0;
            unchecked {
                cursor++;
                processed++;
            }

            if (forceEarly && releaseTime > block.timestamp) {
                uint256 penalty = (amount * penaltyBps) / BPS_DENOMINATOR;
                penaltyAmount += penalty;
                releasedAmount += amount - penalty;
            } else {
                releasedAmount += amount;
            }
        }

        if (releasedAmount == 0 && penaltyAmount == 0) {
            revert NothingToWithdraw(agentId, asset);
        }

        if (cursor == queueLength) {
            delete _withdrawalQueue[agentId][asset];
            delete _withdrawalHead[agentId][asset];
        } else {
            _withdrawalHead[agentId][asset] = cursor;
        }

        address payoutReceiver = receiver == address(0) ? agentOwner[agentId] : receiver;
        if (releasedAmount > 0) {
            _transferAsset(asset, payoutReceiver, releasedAmount);
            if (forceEarly) {
                emit EarlyWithdrawal(agentId, asset, releasedAmount + penaltyAmount, penaltyAmount, payoutReceiver);
            } else {
                emit WithdrawalExecuted(agentId, asset, releasedAmount, payoutReceiver);
            }
        }

        if (penaltyAmount > 0) {
            if (asset == ETH_ASSET) {
                treasury.handleEarlyExitPenalty{value: penaltyAmount}(agentId, asset, penaltyAmount);
            } else {
                IERC20(asset).safeTransfer(address(treasury), penaltyAmount);
                treasury.handleEarlyExitPenalty(agentId, asset, penaltyAmount);
            }
        }
    }

    function stakedBalance(uint256 agentId, address asset) external view returns (uint256) {
        return _staked[agentId][asset];
    }

    function lockedBalance(uint256 agentId, address asset) external view returns (uint256) {
        return _lockedStake[agentId][asset];
    }

    function stakeBalances(uint256 agentId, address asset) public view returns (StakeView memory) {
        uint256 totalStake = _staked[agentId][asset];
        uint256 locked = _lockedStake[agentId][asset];
        return StakeView({total: totalStake, locked: locked, available: totalStake - locked});
    }

    function pendingWithdrawalCount(uint256 agentId, address asset) external view returns (uint256) {
        PendingWithdrawal[] storage queue = _withdrawalQueue[agentId][asset];
        return queue.length - _withdrawalHead[agentId][asset];
    }

    function pendingWithdrawalAt(
        uint256 agentId,
        address asset,
        uint256 index
    ) external view returns (PendingWithdrawal memory) {
        PendingWithdrawal[] storage queue = _withdrawalQueue[agentId][asset];
        uint256 head = _withdrawalHead[agentId][asset];
        uint256 actualIndex = head + index;
        require(actualIndex < queue.length, "INDEX_OUT_OF_BOUNDS");
        return queue[actualIndex];
    }

    function lockStake(uint256 agentId, address asset, uint256 amount) external onlyRole(TASK_MODULE_ROLE) {
        _requireAgentExists(agentId);
        if (amount == 0) revert ZeroAmount();
        StakeView memory balances = stakeBalances(agentId, asset);
        if (amount > balances.available) revert AmountTooLarge(amount, balances.available);
        _lockedStake[agentId][asset] = balances.locked + amount;
        emit StakeLocked(agentId, asset, amount, _lockedStake[agentId][asset]);
    }

    function unlockStake(uint256 agentId, address asset, uint256 amount) external onlyRole(TASK_MODULE_ROLE) {
        _requireAgentExists(agentId);
        if (amount == 0) revert ZeroAmount();
        uint256 locked = _lockedStake[agentId][asset];
        if (amount > locked) revert AmountTooLarge(amount, locked);
        _lockedStake[agentId][asset] = locked - amount;
        emit StakeUnlocked(agentId, asset, amount, _lockedStake[agentId][asset]);
    }

    // -------------------------------------------------------------------------
    // Slashing
    // -------------------------------------------------------------------------

    function slashStake(uint256 agentId, address asset, uint256 amount) external nonReentrant onlyRole(SLASHER_ROLE) {
        _requireAgentExists(agentId);
        if (amount == 0) revert ZeroAmount();
        uint256 available = _staked[agentId][asset];
        if (amount > available) revert AmountTooLarge(amount, available);

        _staked[agentId][asset] = available - amount;
        if (_totalStakedPerAsset[asset] >= amount) {
            _totalStakedPerAsset[asset] -= amount;
        }

        uint256 locked = _lockedStake[agentId][asset];
        if (locked > 0) {
            uint256 reduction = amount > locked ? locked : amount;
            _lockedStake[agentId][asset] = locked - reduction;
        }

        if (asset == ETH_ASSET) {
            treasury.handleSlash{value: amount}(agentId, asset, amount);
        } else {
            IERC20(asset).safeTransfer(address(treasury), amount);
            treasury.handleSlash(agentId, asset, amount);
        }

        emit StakeSlashed(agentId, asset, amount);
    }

    // -------------------------------------------------------------------------
    // Inference logging & verification
    // -------------------------------------------------------------------------

    function recordInference(
        uint256 agentId,
        bytes32 inputHash,
        bytes32 outputHash,
        bytes32 modelHash,
        uint256 taskId,
        string calldata proofURI
    ) external whenNotPaused returns (bytes32 inferenceId) {
        if (!_isAuthorized(agentId, PERMISSION_INFERENCE, msg.sender)) {
            revert UnauthorizedDelegate(msg.sender);
        }

        uint256 nonce = ++_agentInferenceNonce[agentId];
        inferenceId = keccak256(abi.encode(agentId, nonce, inputHash, outputHash));
        _inferenceById[inferenceId] = InferenceCommitment({
            agentId: agentId,
            inputHash: inputHash,
            outputHash: outputHash,
            modelHash: modelHash,
            taskId: taskId,
            reporter: msg.sender,
            proofURI: proofURI,
            timestamp: uint64(block.timestamp)
        });
        _agentInferenceIds[agentId].push(inferenceId);

        emit InferenceRecorded(agentId, inferenceId, inputHash, outputHash, modelHash, taskId, msg.sender, proofURI);

        if (proofVerifier != address(0)) {
            (bool success, ) = proofVerifier.call(
                abi.encodeWithSignature(
                    "onInferenceRecorded(uint256,bytes32,bytes32,bytes32,bytes32,uint256,string)",
                    agentId,
                    inferenceId,
                    inputHash,
                    outputHash,
                    modelHash,
                    taskId,
                    proofURI
                )
            );
            success; // silence compiler warning if verifier reverts
        }
    }

    function attestInference(
        bytes32 inferenceId,
        bool success,
        string calldata uri,
        ReputationDelta[] calldata deltas
    ) external onlyRole(VERIFIER_ROLE) {
        InferenceCommitment storage commitment = _inferenceById[inferenceId];
        if (commitment.agentId == 0) revert UnknownInference(inferenceId);

        _attestations[inferenceId] = VerifierAttestation({
            verifier: msg.sender,
            success: success,
            uri: uri,
            timestamp: uint64(block.timestamp)
        });

        for (uint256 i; i < deltas.length; i++) {
            _adjustReputation(commitment.agentId, deltas[i].dimension, deltas[i].delta, deltas[i].reason);
        }

        emit InferenceAttested(
            inferenceId,
            commitment.agentId,
            commitment.taskId,
            msg.sender,
            success,
            uri
        );

        if (address(tasksContract) != address(0) && commitment.taskId != 0) {
            tasksContract.onInferenceVerified(commitment.agentId, commitment.taskId, inferenceId, success);
        }
    }

    function getInference(bytes32 inferenceId)
        external
        view
        returns (InferenceCommitment memory commitment, VerifierAttestation memory attestation)
    {
        commitment = _inferenceById[inferenceId];
        if (commitment.agentId == 0) revert UnknownInference(inferenceId);
        attestation = _attestations[inferenceId];
    }

    function listInferenceIds(uint256 agentId) external view returns (bytes32[] memory) {
        return _agentInferenceIds[agentId];
    }

    // -------------------------------------------------------------------------
    // Payments
    // -------------------------------------------------------------------------

    function payAgentETH(uint256 agentId) external payable nonReentrant whenNotPaused {
        _requireAgentExists(agentId);
        if (msg.value == 0) revert ZeroAmount();
        address recipient = agentOwner[agentId];
        (bool success, ) = payable(recipient).call{value: msg.value}("");
        require(success, "ETH_TRANSFER_FAILED");
    }

    function payAgentToken(uint256 agentId, address token, uint256 amount) external nonReentrant whenNotPaused {
        _requireAgentExists(agentId);
        if (amount == 0) revert ZeroAmount();
        address recipient = agentOwner[agentId];
        IERC20(token).safeTransferFrom(msg.sender, recipient, amount);
    }

    // -------------------------------------------------------------------------
    // Reputation management
    // -------------------------------------------------------------------------

    function adjustReputation(
        uint256 agentId,
        bytes32 dimension,
        int256 delta,
        string calldata reason
    ) external onlyRole(REPUTATION_ROLE) {
        _adjustReputation(agentId, dimension, delta, reason);
    }

    function _adjustReputation(
        uint256 agentId,
        bytes32 dimension,
        int256 delta,
        string memory reason
    ) internal {
        _requireAgentExists(agentId);
        int256 current = _reputationScores[agentId][dimension];
        int256 updated = current + delta;
        _reputationScores[agentId][dimension] = updated;
        emit ReputationAdjusted(agentId, dimension, updated, reason);
    }

    function getReputation(uint256 agentId, bytes32 dimension) external view returns (int256) {
        return _reputationScores[agentId][dimension];
    }

    function reputationDimensions() external view returns (bytes32[] memory) {
        return _reputationDimensions;
    }

    function aggregatedReputation(uint256 agentId) public view returns (int256 weighted) {
        uint256 totalWeight;
        for (uint256 i; i < _reputationDimensions.length; i++) {
            bytes32 dimension = _reputationDimensions[i];
            uint256 weight = reputationWeights[dimension];
            if (weight == 0) continue;
            totalWeight += weight;
            weighted += _reputationScores[agentId][dimension] * int256(uint256(weight));
        }
        if (totalWeight == 0) return 0;
        return weighted / int256(uint256(totalWeight));
    }

    function agentReputation(uint256 agentId) external view returns (int256) {
        return aggregatedReputation(agentId);
    }

    // -------------------------------------------------------------------------
    // Contribution logging
    // -------------------------------------------------------------------------

    function logContribution(uint256 agentId, string calldata evidenceURI, string calldata metadata)
        external
    {
        _requireAgentExists(agentId);
        if (
            msg.sender != agentOwner[agentId]
                && !hasRole(CONTRIBUTION_ROLE, msg.sender)
                && !hasRole(REPUTATION_ROLE, msg.sender)
        ) {
            revert UnauthorizedContribution(agentId, msg.sender);
        }

        uint256 contributionId = ++contributionCount[agentId];
        emit ContributionLogged(agentId, contributionId, msg.sender, evidenceURI, metadata);
    }

    // -------------------------------------------------------------------------
    // Discovery helpers
    // -------------------------------------------------------------------------

    function listAgents(uint256 offset, uint256 limit) external view returns (AgentSummary[] memory) {
        uint256 totalAgents = _agentIndex.length;
        if (offset > totalAgents) revert InvalidPagination();
        uint256 end = limit == 0 || offset + limit > totalAgents ? totalAgents : offset + limit;
        AgentSummary[] memory results = new AgentSummary[](end - offset);
        uint256 cursor;
        for (uint256 i = offset; i < end; i++) {
            uint256 agentId = _agentIndex[i];
            uint256 totalStake;
            uint256 lockedStake;
            for (uint256 j; j < _trackedAssets.length; j++) {
                address asset = _trackedAssets[j];
                uint256 stakeForAsset = _staked[agentId][asset];
                if (stakeForAsset == 0) continue;
                totalStake += stakeForAsset;
                lockedStake += _lockedStake[agentId][asset];
            }
            results[cursor] = AgentSummary({
                agentId: agentId,
                owner: agentOwner[agentId],
                metadata: agentMetadata[agentId],
                serviceURI: _serviceURI[agentId],
                totalStake: totalStake,
                lockedStake: lockedStake,
                weightedReputation: aggregatedReputation(agentId)
            });
            cursor++;
        }
        return results;
    }

    function aggregatedStats() external view returns (AggregatedStats memory stats) {
        stats.totalAgents = _agentIndex.length;
        stats.assets = _trackedAssets;
        stats.totalStakedPerAsset = new uint256[](stats.assets.length);
        for (uint256 i; i < stats.assets.length; i++) {
            stats.totalStakedPerAsset[i] = _totalStakedPerAsset[stats.assets[i]];
        }
    }

    function totalStakedForAsset(address asset) external view returns (uint256) {
        return _totalStakedPerAsset[asset];
    }

    function trackedAssets() external view returns (address[] memory) {
        return _trackedAssets;
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    function _requireAgentExists(uint256 agentId) internal view {
        if (agentOwner[agentId] == address(0)) {
            revert AgentNotRegistered(agentId);
        }
    }

    function _transferAsset(address asset, address recipient, uint256 amount) internal {
        if (asset == ETH_ASSET) {
            (bool success, ) = payable(recipient).call{value: amount}("");
            require(success, "ETH_TRANSFER_FAILED");
        } else {
            IERC20(asset).safeTransfer(recipient, amount);
        }
    }

    // -------------------------------------------------------------------------
    // Upgrade authorization & interface support
    // -------------------------------------------------------------------------

    function _authorizeUpgrade(address newImplementation) internal view override onlyRole(DEFAULT_ADMIN_ROLE) {
        newImplementation; // silence unused warning
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(AccessControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    // -------------------------------------------------------------------------
    // Receive fallback for ETH refunds
    // -------------------------------------------------------------------------

    receive() external payable {}

    uint256[45] private __gap;
}
