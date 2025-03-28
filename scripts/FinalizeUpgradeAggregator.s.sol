// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "forge-std/console.sol";

/// @notice Finalize the upgrade of the CommonAggregator contract. The contract should be submitted
/// via SubmitUpgradeAggregatorScript.s.sol before running this script, and the time lock should pass.
contract FinalizeUpgradeAggregatorScript is Script {
    function run() public {
        address commonAggregator = vm.envAddress("COMMON_AGGREGATOR");
        address newImplementation = vm.envAddress("NEW_IMPLEMENTATION");
        bytes memory callData = "";

        vm.startBroadcast();

        UUPSUpgradeable(commonAggregator).upgradeToAndCall(newImplementation, callData);

        console.log("Upgrade finalized successfully");

        vm.stopBroadcast();
    }
}
