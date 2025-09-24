// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "forge-std/StdJson.sol";

contract AgentsFaultProofConfigTest is Test {
    using stdJson for string;

    string internal constant CONFIG_PATH = "deploy-config/AgentsL3.json";
    string internal json;

    function setUp() public {
        json = vm.readFile(CONFIG_PATH);
    }

    function testConfigEnablesFaultProofs() public view {
        bool enabled = json.readBool("$.useFaultProofs");
        assertTrue(enabled, "Fault proofs must be enabled for the AI L3");
    }

    function testConfigDefinesDisputeGameTiming() public view {
        uint256 maxClock = uint256(json.readUint("$.faultGameMaxClockDuration"));
        uint256 withdrawalDelay = uint256(json.readUint("$.faultGameWithdrawalDelay"));
        assertGt(maxClock, 0, "max clock duration must be positive");
        assertGt(withdrawalDelay, 0, "withdrawal delay must be positive");
    }

    function testConfigAnchorsToBaseSepolia() public view {
        uint256 l1ChainId = uint256(json.readUint("$.l1ChainID"));
        assertEq(l1ChainId, 84532, "L1 must be Base Sepolia");
    }

    function testAbsolutePrestateIsNonZero() public view {
        bytes32 prestate = json.readBytes32("$.faultGameAbsolutePrestate");
        assertTrue(prestate != bytes32(0), "prestate cannot be zero");
    }
}
