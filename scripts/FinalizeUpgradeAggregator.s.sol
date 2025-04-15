// SPDX-License-Identifier: UNKNOWN
// solhint-disable no-console
pragma solidity ^0.8.28;

import {console} from "forge-std/console.sol";
import {Script} from "forge-std/Script.sol";
import {CommonManagement} from "./../contracts/CommonManagement.sol";

/// @notice Finalize the upgrade of the CommonAggregator contract. The contract should be submitted
/// via SubmitUpgradeAggregatorScript.s.sol before running this script, and the time lock should pass.
contract FinalizeUpgradeAggregatorScript is Script {
    function run() public {
        address commonManagement = vm.envAddress("COMMON_MANAGEMENT");
        address newImplementation = vm.envAddress("NEW_IMPLEMENTATION");
        bytes memory callData = "";

        vm.startBroadcast();

        CommonManagement(commonManagement).upgradeAggregator(newImplementation, callData);
        console.log("Upgrade finalized successfully");

        vm.stopBroadcast();
    }
}
