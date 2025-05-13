// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {CommonAggregatorTestnetAsset} from "contracts/testnet/CommonAggregatorTestnetAsset.sol";
import {Script, console} from "forge-std/Script.sol";

contract DeployTestnetAsset is Script {
    function run() public {
        vm.startBroadcast();

        address caller;
        address origin;

        (, caller, origin) = vm.readCallers();

        CommonAggregatorTestnetAsset asset = new CommonAggregatorTestnetAsset(caller);

        string memory addressStr = Strings.toChecksumHexString(address(asset));

        console.log("Testnet asset deployed to: ", addressStr);

        vm.setEnv("TESTNET_VAULT_ASSET_ADDRESS", addressStr);

        vm.stopBroadcast();
    }
}
