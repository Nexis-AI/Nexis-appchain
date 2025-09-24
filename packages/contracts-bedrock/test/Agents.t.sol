// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Test.sol";

import { Agents } from "contracts/Agents.sol";
import { Tasks } from "contracts/Tasks.sol";
import { Treasury } from "contracts/Treasury.sol";
import { Subscriptions } from "contracts/Subscriptions.sol";
import { IAgentsRegistry } from "contracts/interfaces/IAgentsRegistry.sol";
import { ERC1967Proxy } from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract TestToken {
    string public constant name = "Mock";
    string public constant symbol = "MOCK";
    uint8 public constant decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "ERC20: allowance");
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "ERC20: balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}

contract AgentsIntegrationTest is Test {
    Agents internal agents;
    Tasks internal tasks;
    Treasury internal treasury;
    Subscriptions internal subscriptions;
    TestToken internal token;

    uint256 internal constant AGENT_ID = 1;
    string internal constant METADATA = "ipfs://metadata.json";
    string internal constant SERVICE_URI = "https://agents.nexis/service/1";

    function setUp() public {
        token = new TestToken();

        Treasury treasuryImpl = new Treasury();
        bytes memory treasuryInit = abi.encodeWithSelector(Treasury.initialize.selector, address(this), address(this));
        treasury = Treasury(address(new ERC1967Proxy(address(treasuryImpl), treasuryInit)));

        Agents agentsImpl = new Agents();
        bytes memory agentsInit = abi.encodeWithSelector(Agents.initialize.selector, address(this), address(treasury));
        address agentsProxy = address(new ERC1967Proxy(address(agentsImpl), agentsInit));
        agents = Agents(payable(agentsProxy));

        treasury.setAgents(address(agents));
        treasury.grantRole(treasury.INFLOW_ROLE(), address(agents));

        Tasks tasksImpl = new Tasks();
        bytes memory tasksInit =
            abi.encodeWithSelector(Tasks.initialize.selector, address(this), address(agents), address(treasury));
        tasks = Tasks(address(new ERC1967Proxy(address(tasksImpl), tasksInit)));

        Subscriptions subsImpl = new Subscriptions();
        bytes memory subsInit =
            abi.encodeWithSelector(Subscriptions.initialize.selector, address(this), address(agents));
        subscriptions = Subscriptions(address(new ERC1967Proxy(address(subsImpl), subsInit)));

        agents.setTasksContract(address(tasks));
        agents.grantRole(agents.TASK_MODULE_ROLE(), address(tasks));
        agents.grantRole(agents.SLASHER_ROLE(), address(tasks));
        agents.grantRole(agents.VERIFIER_ROLE(), address(this));
        agents.setEarlyExitPenalty(address(0), 500);

        agents.register(AGENT_ID, METADATA, SERVICE_URI);
    }

    function _stakeToken(uint256 amount) internal {
        token.mint(address(this), amount);
        token.approve(address(agents), amount);
        agents.stakeERC20(AGENT_ID, address(token), amount);
    }

    function testStakeAndUnstakeERC20() public {
        _stakeToken(200 ether);
        assertEq(agents.stakedBalance(AGENT_ID, address(token)), 200 ether);

        agents.requestWithdrawal(AGENT_ID, address(token), 80 ether);
        vm.warp(block.timestamp + 8 days);
        (uint256 released, uint256 penalty) = agents.claimWithdrawals(AGENT_ID, address(token), 0, address(this), false);
        assertEq(released, 80 ether);
        assertEq(penalty, 0);
        assertEq(token.balanceOf(address(this)), 80 ether);
        assertEq(agents.stakedBalance(AGENT_ID, address(token)), 120 ether);
    }

    function testCancelWithdrawalRestoresStake() public {
        _stakeToken(50 ether);
        agents.requestWithdrawal(AGENT_ID, address(token), 20 ether);
        agents.cancelWithdrawal(AGENT_ID, address(token), 0);
        assertEq(agents.stakedBalance(AGENT_ID, address(token)), 50 ether);
        vm.expectRevert();
        agents.claimWithdrawals(AGENT_ID, address(token), 0, address(this), false);
    }

    function testEarlyWithdrawalPenaltyRoutesToTreasury() public {
        vm.deal(address(this), 10 ether);
        agents.stakeETH{ value: 5 ether }(AGENT_ID);
        agents.requestWithdrawal(AGENT_ID, address(0), 2 ether);
        (uint256 released, uint256 penalty) = agents.claimWithdrawals(AGENT_ID, address(0), 1, address(this), true);
        assertEq(released, 1900000000000000000); // 1.9 ether
        assertEq(penalty, 100000000000000000); // 0.1 ether (5% of 2 ether)

        Treasury.PoolBalances memory ethPools = treasury.poolBalances(address(0));
        assertEq(ethPools.treasury, 40000000000000000); // 40% of penalty
        assertEq(ethPools.insurance, 30000000000000000);
        assertEq(ethPools.rewards, 30000000000000000);
    }

    function testDelegationMetadataAndWithdraw() public {
        address delegate = address(0xBEEF);
        agents.setDelegate(AGENT_ID, delegate, agents.PERMISSION_METADATA(), true);
        agents.setDelegate(AGENT_ID, delegate, agents.PERMISSION_WITHDRAW(), true);

        vm.prank(delegate);
        agents.updateMetadata(AGENT_ID, "ipfs://delegate.json");
        assertEq(agents.agentMetadata(AGENT_ID), "ipfs://delegate.json");

        _stakeToken(30 ether);
        vm.prank(delegate);
        agents.requestWithdrawal(AGENT_ID, address(token), 10 ether);
        vm.warp(block.timestamp + 8 days);
        vm.prank(delegate);
        (uint256 released,) = agents.claimWithdrawals(AGENT_ID, address(token), 0, delegate, false);
        assertEq(released, 10 ether);
        assertEq(token.balanceOf(delegate), 10 ether);
    }

    function testInferenceAttestationAndReputation() public {
        bytes32 inputHash = keccak256(abi.encodePacked("input"));
        bytes32 outputHash = keccak256(abi.encodePacked("output"));
        bytes32 modelHash = keccak256(abi.encodePacked("model:v1"));
        bytes32 inferenceId = agents.recordInference(AGENT_ID, inputHash, outputHash, modelHash, 0, "ipfs://proof");

        Agents.ReputationDelta[] memory deltas = new Agents.ReputationDelta[](1);
        deltas[0] = Agents.ReputationDelta({ dimension: keccak256("reliability"), delta: 5, reason: "verified" });

        agents.attestInference(inferenceId, true, "ipfs://attestation", deltas);

        (Agents.InferenceCommitment memory commitment, Agents.VerifierAttestation memory attestation)
        = agents.getInference(inferenceId);
        assertEq(commitment.agentId, AGENT_ID);
        assertEq(commitment.modelHash, modelHash);
        assertTrue(attestation.success);
        assertEq(attestation.verifier, address(this));
        assertEq(attestation.uri, "ipfs://attestation");
        assertEq(agents.getReputation(AGENT_ID, keccak256("reliability")), 5);
    }

    function testTaskLifecycleHappyPath() public {
        _stakeToken(200 ether);

        address jobCreator = address(0xCAFE);
        token.mint(jobCreator, 150 ether);
        vm.startPrank(jobCreator);
        token.approve(address(tasks), 100 ether);
        uint256 taskId =
            tasks.postTask(address(token), 60 ether, 40 ether, 1 days, 2 days, "ipfs://job", "ipfs://input");
        vm.stopPrank();

        tasks.claimTask(taskId, AGENT_ID);

        bytes32 inferenceId = agents.recordInference(
            AGENT_ID, keccak256("job-input"), keccak256("job-output"), keccak256("model:v2"), taskId, "ipfs://proof-job"
        );
        tasks.submitWork(taskId, inferenceId);

        Agents.ReputationDelta[] memory deltas = new Agents.ReputationDelta[](1);
        deltas[0] = Agents.ReputationDelta({ dimension: keccak256("accuracy"), delta: 7, reason: "task-complete" });
        agents.attestInference(inferenceId, true, "uri", deltas);

        assertEq(token.balanceOf(address(this)), 60 ether);
        assertEq(agents.lockedBalance(AGENT_ID, address(token)), 0);
    }

    function testClaimTaskRequiresStake() public {
        address jobCreator = address(0xD00D);
        token.mint(jobCreator, 20 ether);
        vm.startPrank(jobCreator);
        token.approve(address(tasks), 10 ether);
        uint256 taskId = tasks.postTask(address(token), 8 ether, 0, 0, 1 days, "ipfs://no-bond", "ipfs://input");
        vm.stopPrank();

        vm.expectRevert(Tasks.InsufficientStake.selector);
        tasks.claimTask(taskId, AGENT_ID);
    }

    function testTaskDisputeAndSlash() public {
        _stakeToken(100 ether);

        address jobCreator = address(0xFEE1);
        token.mint(jobCreator, 100 ether);
        vm.startPrank(jobCreator);
        token.approve(address(tasks), 50 ether);
        uint256 taskId = tasks.postTask(address(token), 40 ether, 30 ether, 0, 1 days, "ipfs://job2", "ipfs://input2");
        vm.stopPrank();

        tasks.claimTask(taskId, AGENT_ID);
        bytes32 inferenceId = agents.recordInference(
            AGENT_ID, keccak256("bad-input"), keccak256("bad-output"), keccak256("model:v3"), taskId, "ipfs://proof-bad"
        );
        tasks.submitWork(taskId, inferenceId);

        Agents.ReputationDelta[] memory deltas = new Agents.ReputationDelta[](1);
        deltas[0] = Agents.ReputationDelta({ dimension: keccak256("trustworthiness"), delta: -5, reason: "disputed" });
        agents.attestInference(inferenceId, false, "uri", deltas);

        vm.prank(address(this));
        tasks.resolveDispute(taskId, true, false, "slash and reroute");

        Treasury.PoolBalances memory pools = treasury.poolBalances(address(token));
        assertEq(pools.rewards, 40 ether);
        assertEq(agents.stakedBalance(AGENT_ID, address(token)), 70 ether);
    }

    function testSubscriptionLifecycle() public {
        address payer = address(0xAAAA);
        vm.deal(payer, 10 ether);

        vm.prank(payer);
        uint256 subId =
            subscriptions.createSubscription{ value: 4 ether }(AGENT_ID, address(0), 2 ether, 3 days, 2, "recurring");

        vm.warp(block.timestamp + 3 days + 1);
        uint256 balanceBefore = address(this).balance;
        subscriptions.processSubscription(subId);
        assertEq(address(this).balance, balanceBefore + 2 ether);

        vm.prank(payer);
        subscriptions.cancelSubscription(subId);
        assertEq(payer.balance, 10 ether - 4 ether + 2 ether);
    }

    function testStreamWithdrawAndCancel() public {
        uint256 total = 100 ether;
        _stakeToken(50 ether);

        address payer = address(0xBBBB);
        token.mint(payer, total);
        vm.startPrank(payer);
        token.approve(address(subscriptions), total);
        uint64 start = uint64(block.timestamp + 1);
        uint64 end = start + 100;
        uint256 streamId = subscriptions.createStream(AGENT_ID, address(token), total, start, end, "sablier");
        vm.stopPrank();

        vm.warp(start + 50);
        subscriptions.withdrawFromStream(streamId);
        assertEq(token.balanceOf(address(this)), 50 ether);

        vm.prank(payer);
        subscriptions.cancelStream(streamId);
        assertEq(token.balanceOf(payer), 50 ether);
    }

    function testGovernanceRewardDistribution() public {
        token.mint(address(this), 100 ether);
        token.transfer(address(treasury), 80 ether);
        treasury.recordRewardDeposit(address(token), 80 ether);

        vm.prank(address(this));
        treasury.distributeReward(AGENT_ID, address(token), 30 ether, address(0), "retroactive");
        assertEq(token.balanceOf(address(this)), 30 ether);
    }

    function testPauseAndUnpause() public {
        agents.pause();
        vm.expectRevert("Pausable: paused");
        agents.stakeETH{ value: 1 ether }(AGENT_ID);
        agents.unpause();
        agents.stakeETH{ value: 1 ether }(AGENT_ID);
        assertEq(agents.stakedBalance(AGENT_ID, address(0)), 1 ether);
    }

    function testUpgradeAuthorization() public {
        Agents newImpl = new Agents();
        vm.expectRevert();
        vm.prank(address(0xBEEF));
        agents.upgradeTo(address(newImpl));

        vm.prank(address(this));
        agents.upgradeTo(address(newImpl));
    }
}
