// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {ICommonManagement} from "../contracts/interfaces/ICommonManagement.sol";
import {Script} from "forge-std/Script.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "forge-std/console.sol";

/// @notice Finalize the upgrade of the CommonAggregator contract. The contract should be submitted
/// via SubmitUpgradeAggregatorScript.s.sol before running this script, and the time lock should pass.
contract FinalizeUpgradeAggregatorScript is Script {
    function run() public {
        address commonManagement = vm.envAddress("COMMON_MANAGEMENT");
        address newImplementation = vm.envAddress("NEW_IMPLEMENTATION");
        bytes memory callData = "";

        vm.startBroadcast();

        ICommonManagement(commonManagement).upgradeAggregator(newImplementation, callData);

        console.log("Upgrade finalized successfully");

        vm.stopBroadcast();
    }
}
