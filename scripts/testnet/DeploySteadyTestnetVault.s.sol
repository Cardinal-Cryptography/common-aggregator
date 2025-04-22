// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {SteadyTestnetVault, MintableERC20} from "../../contracts/testnet/SteadyTestnetVault.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

contract DeploySteadyTestnetVault is Script {
    function run() public {
        address token = vm.envAddress("TESTNET_VAULT_ASSET_ADDRESS");
        vm.startBroadcast();

        string memory tokenName = IERC20Metadata(token).name();
        string memory tokenSymbol = IERC20Metadata(token).symbol();

        SteadyTestnetVault vault = new SteadyTestnetVault(
            MintableERC20(token),
            string.concat("Steady Testnet Vault ", tokenName),
            string.concat("stv", tokenSymbol),
            500 // 5% APY
        );

        console.log(string.concat(tokenName, " Vault deployed to: "), address(vault));

        MintableERC20(token).approve(address(vault), type(uint256).max);

        vm.stopBroadcast();
    }
}
