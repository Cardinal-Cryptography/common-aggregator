// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {RandomWalkTestnetVault, MintableERC20} from "../../contracts/testnet/RandomWalkTestnetVault.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

contract DeployRandomWalkTestnetVaults is Script {
    function run() public {
        address token = vm.envAddress("TESTNET_VAULT_ASSET_ADDRESS");
        vm.startBroadcast();

        string memory tokenName = IERC20Metadata(token).name();
        string memory tokenSymbol = IERC20Metadata(token).symbol();

        RandomWalkTestnetVault vaultSlow = new RandomWalkTestnetVault({
            _asset: MintableERC20(token),
            _name: string.concat("Random Walk Testnet Vault Slow ", tokenName),
            _symbol: string.concat("rwtvs", tokenSymbol),
            _startingAprBps: 600,
            _minAprBps: 200,
            _maxAprBps: 700,
            _maxAprChangeBps: 8,
            _timeSegmentDuration: 4 hours
        });

        RandomWalkTestnetVault vaultMid = new RandomWalkTestnetVault({
            _asset: MintableERC20(token),
            _name: string.concat("Random Walk Testnet Vault Mid ", tokenName),
            _symbol: string.concat("rwtvm", tokenSymbol),
            _startingAprBps: 600,
            _minAprBps: 100,
            _maxAprBps: 1000,
            _maxAprChangeBps: 25,
            _timeSegmentDuration: 4 hours
        });

        RandomWalkTestnetVault vaultFast = new RandomWalkTestnetVault({
            _asset: MintableERC20(token),
            _name: string.concat("Random Walk Testnet Vault Fast ", tokenName),
            _symbol: string.concat("rwtvf", tokenSymbol),
            _startingAprBps: 600,
            _minAprBps: -100,
            _maxAprBps: 1200,
            _maxAprChangeBps: 50,
            _timeSegmentDuration: 4 hours
        });

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
