// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {RandomWalkTestnetVault, MintableERC20} from "../../contracts/testnet/RandomWalkTestnetVault.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

contract DeployRandomWalkTestnetVaults is Script {
    function run() public {
        address token = vm.envAddress("TESTNET_VAULT_TOKEN_ADDRESS");
        vm.startBroadcast();

        string memory tokenName = IERC20Metadata(token).name();
        string memory tokenSymbol = IERC20Metadata(token).symbol();

        RandomWalkTestnetVault vaultSlow = new RandomWalkTestnetVault(
            MintableERC20(token),
            string.concat("Random Walk Testnet Vault Slow ", tokenName),
            string.concat("rwtvs", tokenSymbol),
            600, // 6% APR start
            200, // 2% APR min
            700, // 7% APR max
            8, // 0.08 percentage points APR max change
            30 minutes // 30 minutes APR change interval
        );

        RandomWalkTestnetVault vaultMid = new RandomWalkTestnetVault(
            MintableERC20(token),
            string.concat("Random Walk Testnet Vault Mid", tokenName),
            string.concat("rwtvm", tokenSymbol),
            600, // 6% APY start
            100, // 1% APY min
            1000, // 10% APY max
            25, // 0.25 percentage points APY max change
            30 minutes // 30 minutes APR change interval
        );

        RandomWalkTestnetVault vaultFast = new RandomWalkTestnetVault(
            MintableERC20(token),
            string.concat("Random Walk Testnet Vault Fast", tokenName),
            string.concat("rwtvf", tokenSymbol),
            600, // 6% APY start
            -100, // -1% APY min
            1200, // 12% APY max
            50, // 0.5 percentage points APY max change
            30 minutes // 30 minutes APR change interval
        );

        console.log(string.concat(tokenName, " Slow Vault deployed to: "), address(vaultSlow));
        console.log(string.concat(tokenName, " Mid Vault deployed to: "), address(vaultMid));
        console.log(string.concat(tokenName, " Fast Vault deployed to: "), address(vaultFast));

        // Approve the vaults to spend the token (for initial deposit later)
        MintableERC20(token).approve(address(vaultSlow), type(uint256).max);
        MintableERC20(token).approve(address(vaultMid), type(uint256).max);
        MintableERC20(token).approve(address(vaultFast), type(uint256).max);

        vm.stopBroadcast();
    }
}
