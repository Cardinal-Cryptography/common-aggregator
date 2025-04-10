// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {CommonAggregator, IERC20Metadata, IERC4626} from "../contracts/CommonAggregator.sol";
import {CommonManagement} from "../contracts/CommonManagement.sol";
import {CommonFactory} from "../contracts/CommonFactory.sol";
import "forge-std/console.sol";

/// @notice Deploy the CommonAggregator contract (implementation and upgradeable proxy).
/// Use when deploying the contract for the first time.
contract DeployAggregatorScript is Script {
    function run() public {
        IERC20Metadata asset = IERC20Metadata(vm.envAddress("ASSET_ADDRESS"));
        address[] memory vaultAddresses = vm.envAddress("VAULTS", ",");

        IERC4626[] memory vaults = new IERC4626[](vaultAddresses.length);
        for (uint256 i = 0; i < vaultAddresses.length; i++) {
            vaults[i] = IERC4626(vaultAddresses[i]);
        }
        address owner = msg.sender;

        vm.startBroadcast();

        CommonFactory factory = new CommonFactory();

        (CommonAggregator aggregator, CommonManagement management) = factory.deployAggregator(owner, asset, vaults);

        console.log("Deployed CommonManagement contract to:", address(management));
        console.log("Deployed CommonAggregator contract to:", address(aggregator));

        vm.stopBroadcast();
    }
}
