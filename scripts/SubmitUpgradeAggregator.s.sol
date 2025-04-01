// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {CommonAggregator} from "contracts/CommonAggregator.sol";
import {Upgrades, Options} from "@openzeppelin/foundry-upgrades/src/Upgrades.sol";
import "forge-std/console.sol";

/// @notice Submit the upgrade of the CommonAggregator contract. Validates the upgrade,
/// deploys the new implementation contract, and submits the pending upgrade to the CommonAggregator contract.
/// After time lock passes, the upgrade can be finalized via FinalizeUpgradeAggregatorScript.s.sol.
/// @dev Requires FOUNDRY_PROFILE=full
contract SubmitUpgradeAggregatorScript is Script {
    function run() public {
        string memory contractName = vm.envString("UPGRADED_CONTRACT_NAME");
        CommonAggregator commonAggregator = CommonAggregator(vm.envAddress("COMMON_AGGREGATOR"));

        Options memory options;
        Upgrades.validateUpgrade(contractName, options);

        console.log("Upgrade validation successful");

        vm.startBroadcast();

        address implementation = Upgrades.deployImplementation(contractName, options);
        console.log("Deployed implementation contract to:", implementation);

        commonAggregator.submitUpgrade(implementation);

        console.log("Update submitted successfully");

        vm.stopBroadcast();
    }
}
