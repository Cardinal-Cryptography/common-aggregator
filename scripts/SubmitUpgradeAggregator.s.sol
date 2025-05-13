// SPDX-License-Identifier: GPL-2.0-or-later
// solhint-disable no-console
pragma solidity ^0.8.28;

import {Upgrades, Options} from "@openzeppelin/foundry-upgrades/src/Upgrades.sol";
import {CommonManagement} from "contracts/CommonManagement.sol";
import {console} from "forge-std/console.sol";
import {Script} from "forge-std/Script.sol";

/// @notice Submit the upgrade of the CommonAggregator contract. Validates the upgrade,
/// deploys the new implementation contract, and submits the pending upgrade to the CommonAggregator contract.
/// After time lock passes, the upgrade can be finalized via FinalizeUpgradeAggregatorScript.s.sol.
/// @dev Requires FOUNDRY_PROFILE=full
contract SubmitUpgradeAggregatorScript is Script {
    function run() public {
        string memory contractName = vm.envString("UPGRADED_CONTRACT_NAME");
        CommonManagement commonManagement = CommonManagement(vm.envAddress("COMMON_MANAGEMENT"));

        Options memory options;
        Upgrades.validateUpgrade(contractName, options);

        console.log("Upgrade validation successful");

        vm.startBroadcast();

        address implementation = Upgrades.deployImplementation(contractName, options);
        console.log("Deployed implementation contract to:", implementation);

        commonManagement.submitUpgradeAggregator(implementation);

        console.log("Update submitted successfully");

        vm.stopBroadcast();
    }
}
