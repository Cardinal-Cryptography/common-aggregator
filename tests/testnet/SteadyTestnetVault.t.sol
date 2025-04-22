// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {MintableERC20, SteadyTestnetVault} from "../../contracts/testnet/SteadyTestnetVault.sol";
import {ERC20Mock} from "../mock/ERC20Mock.sol";

contract SteadyTestnetVaultTest is Test {
    ERC20Mock public token;
    SteadyTestnetVault public vault;

    function setUp() public {
        token = new ERC20Mock();
        vault = new SteadyTestnetVault(
            MintableERC20(address(token)),
            "Steady Testnet Vault",
            "stv",
            600 // 6% APY
        );
    }

    function testDeposit() public {
        address user = address(0x123);
        token.mint(user, 1000 * 10 ** 18);
        vm.startPrank(user);
        token.approve(address(vault), 1000 * 10 ** 18);
        vault.deposit(1000 * 10 ** 18, user);
        vm.stopPrank();

        assertEq(vault.totalAssets(), 1000 * 10 ** 18);
        assertEq(token.balanceOf(user), 0);
    }

    function testApy() public {
        address user = address(0x123);
        token.mint(user, 1000 * 10 ** 18);

        vm.startPrank(user);
        token.approve(address(vault), 1000 * 10 ** 18);
        vault.deposit(1000 * 10 ** 18, user);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);

        uint256 expectedAssets = (1000 * 10 ** 18) + ((1000 * 10 ** 18) * 6 / 100);
        assertEq(vault.totalAssets(), expectedAssets);
        assertEq(vault.maxWithdraw(user), expectedAssets - 1);

        vm.prank(user);
        vault.withdraw(expectedAssets - 1, user, user);
        assertEq(token.balanceOf(user), expectedAssets - 1);
    }

    function testFuzz_pricePerShare(uint64[20] calldata timeOffsets) public {
        vm.warp(1);
        address user = address(0x123);
        token.mint(user, 1000 * 10 ** 18);

        vm.startPrank(user);
        token.approve(address(vault), 1000 * 10 ** 18);
        vault.deposit(1000 * 10 ** 18, user);
        vm.stopPrank();

        assertEq(vault.totalAssets(), 1000 * 10 ** 18);

        uint256 currentTime = 1;
        for (uint256 i = 0; i < timeOffsets.length; i++) {
            currentTime = currentTime + timeOffsets[i];
            vm.warp(currentTime);

            uint256 expectedAssets = (1000 * 10 ** 18) + ((1000 * 10 ** 18) * 6 * (currentTime - 1) / (100 * 365 days));
            assertEq(expectedAssets, vault.totalAssets(), "totalAssets");
            assertEq((1000 * 10 ** 24 + 10 ** 6) / (expectedAssets + 1), vault.convertToShares(1), "asset to shares");
        }
    }
}
