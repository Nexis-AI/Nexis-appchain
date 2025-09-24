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

contract Subscriptions is Initializable, AccessControlUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    struct Subscription {
        address payer;
        uint256 agentId;
        address asset;
        uint256 amountPerEpoch;
        uint64 epochDuration;
        uint64 nextCharge;
        uint256 balance;
        bool active;
        string metadataURI;
    }

    struct Stream {
        address payer;
        uint256 agentId;
        address asset;
        uint256 ratePerSecond;
        uint64 start;
        uint64 end;
        uint256 deposited;
        uint256 withdrawn;
        bool active;
        string integrationURI;
    }

    mapping(uint256 => Subscription) private _subscriptions;
    mapping(uint256 => Stream) private _streams;

    uint256 public subscriptionCount;
    uint256 public streamCount;

    IAgentsRegistry public agents;

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    address internal constant ETH_ASSET = address(0);

    event SubscriptionCreated(
        uint256 indexed subscriptionId,
        address indexed payer,
        uint256 indexed agentId,
        address asset,
        uint256 amountPerEpoch,
        uint64 epochDuration,
        string metadataURI
    );
    event SubscriptionFunded(uint256 indexed subscriptionId, uint256 amount, address indexed funder);
    event SubscriptionProcessed(uint256 indexed subscriptionId, address indexed recipient, uint256 amount, uint64 nextCharge);
    event SubscriptionCancelled(uint256 indexed subscriptionId, address indexed payer, uint256 refundedAmount);

    event StreamCreated(
        uint256 indexed streamId,
        address indexed payer,
        uint256 indexed agentId,
        address asset,
        uint256 ratePerSecond,
        uint64 start,
        uint64 end,
        string integrationURI
    );
    event StreamWithdrawn(uint256 indexed streamId, address indexed recipient, uint256 amount);
    event StreamCancelled(uint256 indexed streamId, address indexed payer, uint256 refundedAmount);

    error InvalidAddress();
    error InvalidParameters();
    error AuthorizationFailed();
    error SubscriptionInactive();
    error StreamInactive();

    constructor() {
        _disableInitializers();
    }

    function initialize(address admin, address agentsRegistry) external initializer {
        if (admin == address(0) || agentsRegistry == address(0)) revert InvalidAddress();

        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _setRoleAdmin(PAUSER_ROLE, DEFAULT_ADMIN_ROLE);
        _grantRole(PAUSER_ROLE, admin);

        agents = IAgentsRegistry(agentsRegistry);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function setAgents(address newAgents) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newAgents == address(0)) revert InvalidAddress();
        agents = IAgentsRegistry(newAgents);
    }

    function getSubscription(uint256 subscriptionId) external view returns (Subscription memory) {
        return _subscriptions[subscriptionId];
    }

    function getStream(uint256 streamId) external view returns (Stream memory) {
        return _streams[streamId];
    }

    function createSubscription(
        uint256 agentId,
        address asset,
        uint256 amountPerEpoch,
        uint64 epochDuration,
        uint8 prefundEpochs,
        string calldata metadataURI
    ) external payable whenNotPaused returns (uint256 subscriptionId) {
        if (!agents.isAgentRegistered(agentId)) revert AuthorizationFailed();
        if (amountPerEpoch == 0 || epochDuration == 0) revert InvalidParameters();

        uint256 prefundAmount = amountPerEpoch * prefundEpochs;
        if (asset == ETH_ASSET) {
            require(msg.value == prefundAmount, "INVALID_VALUE");
        } else {
            require(msg.value == 0, "TOKEN_VALUE");
            if (prefundAmount > 0) {
                IERC20(asset).safeTransferFrom(msg.sender, address(this), prefundAmount);
            }
        }

        subscriptionId = ++subscriptionCount;
        Subscription storage sub = _subscriptions[subscriptionId];
        sub.payer = msg.sender;
        sub.agentId = agentId;
        sub.asset = asset;
        sub.amountPerEpoch = amountPerEpoch;
        sub.epochDuration = epochDuration;
        sub.nextCharge = uint64(block.timestamp + epochDuration);
        sub.balance = prefundAmount;
        sub.active = true;
        sub.metadataURI = metadataURI;

        emit SubscriptionCreated(subscriptionId, msg.sender, agentId, asset, amountPerEpoch, epochDuration, metadataURI);

        if (prefundAmount > 0) {
            emit SubscriptionFunded(subscriptionId, prefundAmount, msg.sender);
        }
    }

    function fundSubscription(uint256 subscriptionId, uint8 epochs) external payable whenNotPaused {
        Subscription storage sub = _subscriptions[subscriptionId];
        if (!sub.active) revert SubscriptionInactive();
        uint256 amount = sub.amountPerEpoch * epochs;
        if (sub.asset == ETH_ASSET) {
            require(msg.value == amount, "INVALID_VALUE");
        } else {
            require(msg.value == 0, "TOKEN_VALUE");
            if (amount > 0) {
                IERC20(sub.asset).safeTransferFrom(msg.sender, address(this), amount);
            }
        }
        sub.balance += amount;
        emit SubscriptionFunded(subscriptionId, amount, msg.sender);
    }

    function processSubscription(uint256 subscriptionId) external whenNotPaused {
        Subscription storage sub = _subscriptions[subscriptionId];
        if (!sub.active) revert SubscriptionInactive();
        if (block.timestamp < sub.nextCharge) revert InvalidParameters();
        if (sub.balance < sub.amountPerEpoch) revert InvalidParameters();

        sub.balance -= sub.amountPerEpoch;
        sub.nextCharge += sub.epochDuration;

        address recipient = agents.agentOwner(sub.agentId);
        _transfer(sub.asset, recipient, sub.amountPerEpoch);

        emit SubscriptionProcessed(subscriptionId, recipient, sub.amountPerEpoch, sub.nextCharge);
    }

    function cancelSubscription(uint256 subscriptionId) external nonReentrant {
        Subscription storage sub = _subscriptions[subscriptionId];
        if (!sub.active) revert SubscriptionInactive();
        if (msg.sender != sub.payer && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) revert AuthorizationFailed();

        sub.active = false;
        uint256 refund = sub.balance;
        sub.balance = 0;
        _transfer(sub.asset, sub.payer, refund);
        emit SubscriptionCancelled(subscriptionId, sub.payer, refund);
    }

    function createStream(
        uint256 agentId,
        address asset,
        uint256 totalAmount,
        uint64 start,
        uint64 end,
        string calldata integrationURI
    ) external payable whenNotPaused returns (uint256 streamId) {
        if (!agents.isAgentRegistered(agentId)) revert AuthorizationFailed();
        if (totalAmount == 0 || end <= start) revert InvalidParameters();

        if (asset == ETH_ASSET) {
            require(msg.value == totalAmount, "INVALID_VALUE");
        } else {
            require(msg.value == 0, "TOKEN_VALUE");
            IERC20(asset).safeTransferFrom(msg.sender, address(this), totalAmount);
        }

        uint256 duration = end - start;
        require(totalAmount % duration == 0, "INVALID_RATE");

        streamId = ++streamCount;
        Stream storage stream = _streams[streamId];
        stream.payer = msg.sender;
        stream.agentId = agentId;
        stream.asset = asset;
        stream.ratePerSecond = totalAmount / duration;
        stream.start = start;
        stream.end = end;
        stream.deposited = totalAmount;
        stream.active = true;
        stream.integrationURI = integrationURI;

        emit StreamCreated(streamId, msg.sender, agentId, asset, stream.ratePerSecond, start, end, integrationURI);
    }

    function withdrawFromStream(uint256 streamId) external nonReentrant whenNotPaused {
        Stream storage stream = _streams[streamId];
        if (!stream.active) revert StreamInactive();

        address recipient = agents.agentOwner(stream.agentId);
        if (msg.sender != recipient) revert AuthorizationFailed();

        uint256 withdrawable = _withdrawableAmount(stream);
        if (withdrawable == 0) revert InvalidParameters();

        stream.withdrawn += withdrawable;
        _transfer(stream.asset, recipient, withdrawable);

        emit StreamWithdrawn(streamId, recipient, withdrawable);

        if (stream.withdrawn == stream.deposited) {
            stream.active = false;
        }
    }

    function cancelStream(uint256 streamId) external nonReentrant {
        Stream storage stream = _streams[streamId];
        if (!stream.active) revert StreamInactive();
        if (msg.sender != stream.payer && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) revert AuthorizationFailed();

        uint256 withdrawable = _withdrawableAmount(stream);
        if (withdrawable > 0) {
            stream.withdrawn += withdrawable;
            address recipient = agents.agentOwner(stream.agentId);
            _transfer(stream.asset, recipient, withdrawable);
            emit StreamWithdrawn(streamId, recipient, withdrawable);
        }

        uint256 refund = stream.deposited - stream.withdrawn;
        stream.active = false;
        stream.deposited = stream.withdrawn;
        _transfer(stream.asset, stream.payer, refund);

        emit StreamCancelled(streamId, stream.payer, refund);
    }

    function _withdrawableAmount(Stream storage stream) internal view returns (uint256) {
        if (!stream.active) return stream.deposited - stream.withdrawn;
        if (block.timestamp <= stream.start) return 0;
        uint64 effectiveTime = block.timestamp >= stream.end ? stream.end : uint64(block.timestamp);
        uint256 elapsed = effectiveTime - stream.start;
        uint256 maxClaimable = stream.ratePerSecond * elapsed;
        if (maxClaimable > stream.deposited) {
            maxClaimable = stream.deposited;
        }
        if (maxClaimable <= stream.withdrawn) return 0;
        return maxClaimable - stream.withdrawn;
    }

    function _transfer(address asset, address to, uint256 amount) internal {
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
