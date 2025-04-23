// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {DeployTestnetAsset} from "scripts/testnet/DeployTestnetAsset.s.sol";
import {DeploySteadyTestnetVault} from "scripts/testnet/DeploySteadyTestnetVault.s.sol";
import {DeployRandomWalkTestnetVaults} from "scripts/testnet/DeployRandomWalkTestnetVaults.s.sol";
import {CommonAggregatorTestnetAsset} from "contracts/testnet/CommonAggregatorTestnetAsset.sol";
import {DeployAggregatorScript} from "scripts/DeployAggregator.s.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Script, console} from "forge-std/Script.sol";

contract SetupDevnet is Script {
    function run() public {
        console.log("Setting up a devnet environment...");
        new DeployTestnetAsset().run();
        new DeploySteadyTestnetVault().run();
        new DeployRandomWalkTestnetVaults().run();

        address assetAddr = vm.envAddress("TESTNET_VAULT_ASSET_ADDRESS");
        CommonAggregatorTestnetAsset asset = CommonAggregatorTestnetAsset(assetAddr);

        address steady = vm.envAddress("TESTNET_STEADY_VAULT_ADDRESS");
        address slow = vm.envAddress("TESTNET_SLOW_VAULT_ADDRESS");
        address mid = vm.envAddress("TESTNET_MID_VAULT_ADDRESS");
        address fast = vm.envAddress("TESTNET_FAST_VAULT_ADDRESS");

        console.log("Giving minting rights to vaults.");

        // Assuming that the current signer is the owner of the asset
        vm.startBroadcast();

        asset.addMintPermission(steady);
        asset.addMintPermission(slow);
        asset.addMintPermission(mid);
        asset.addMintPermission(fast);

        vm.stopBroadcast();

        vm.setEnv("ASSET_ADDRESS", Strings.toChecksumHexString(assetAddr));

        // `DeployAggregatorScript` uses comma-separated format for `VAULTS` env var
        string memory vaults;
        vaults = string.concat(Strings.toChecksumHexString(steady), ",");
        vaults = string.concat(vaults, Strings.toChecksumHexString(slow));
        vaults = string.concat(vaults, ",");
        vaults = string.concat(vaults, Strings.toChecksumHexString(mid));
        vaults = string.concat(vaults, ",");
        vaults = string.concat(vaults, Strings.toChecksumHexString(fast));

        vm.setEnv("VAULTS", vaults);

        new DeployAggregatorScript().run();
    }
}
