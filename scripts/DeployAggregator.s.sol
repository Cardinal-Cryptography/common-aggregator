// SPDX-License-Identifier: GPL-2.0-or-later
// solhint-disable no-console
pragma solidity ^0.8.28;

import {Upgrades, Options} from "@openzeppelin/foundry-upgrades/src/Upgrades.sol";
import {console} from "forge-std/console.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Script} from "forge-std/Script.sol";
import {CommonAggregator, IERC20Metadata, IERC4626} from "../contracts/CommonAggregator.sol";
import {CommonAggregatorDeployer} from "../contracts/CommonAggregatorDeployer.sol";
import {CommonManagement} from "../contracts/CommonManagement.sol";

/// @notice Deploy the CommonAggregator contract (implementation and upgradeable proxy).
/// Use when deploying the contract for the first time.
/// @dev Requires FOUNDRY_PROFILE=full
contract DeployAggregatorScript is Script {
    function run() public {
        IERC20Metadata asset = IERC20Metadata(vm.envAddress("ASSET_ADDRESS"));
        address[] memory vaultAddresses = vm.envAddress("VAULTS", ",");

        IERC4626[] memory vaults = new IERC4626[](vaultAddresses.length);
        for (uint256 i = 0; i < vaultAddresses.length; ++i) {
            vaults[i] = IERC4626(vaultAddresses[i]);
        }
        address owner = msg.sender;

        Options memory options;
        Upgrades.validateImplementation("CommonAggregator.sol", options);
        Upgrades.validateImplementation("CommonManagement.sol", options);

        vm.startBroadcast();

        CommonAggregatorDeployer factory = new CommonAggregatorDeployer();
        address aggregatorImplementation = address(new CommonAggregator());
        address managementImplementation = address(new CommonManagement());

        (address aggregator, address management) =
            factory.deployAggregator(aggregatorImplementation, managementImplementation, owner, asset, vaults);

        console.log("Deployed CommonManagement contract to:", management);
        console.log("Deployed CommonAggregator contract to:", aggregator);

        vm.stopBroadcast();

        vm.setEnv("MANAGEMENT_ADDRESS", Strings.toChecksumHexString(management));
        vm.setEnv("AGGREGATOR_ADDRESS", Strings.toChecksumHexString(aggregator));
    }
}
