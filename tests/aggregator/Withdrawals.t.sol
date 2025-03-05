// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ICommonAggregator} from "contracts/interfaces/ICommonAggregator.sol";
import {CommonAggregator} from "contracts/CommonAggregator.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC4626Mock} from "tests/mock/ERC4626Mock.sol";
import {ERC20Mock} from "tests/mock/ERC20Mock.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract CommonAggregatorTest is Test {
    using Math for uint256;

    uint256 constant STARTING_TIMESTAMP = 100_000_000;
    uint256 constant VAULT_COUNT = 3;
    uint256 constant INITIAL_DEPOSIT = 10000;

    CommonAggregator commonAggregator;
    address owner = address(0x123);

    ERC20Mock asset = new ERC20Mock();
    ERC4626Mock[] vaults = new ERC4626Mock[](VAULT_COUNT);

    address alice = address(0x456);
    address bob = address(0x654);

    function setUp() public {
        vm.warp(STARTING_TIMESTAMP);
        CommonAggregator implementation = new CommonAggregator();

        for (uint256 i = 0; i < VAULT_COUNT; ++i) {
            vaults[i] = new ERC4626Mock(address(asset));
        }

        bytes memory initializeData = abi.encodeWithSelector(CommonAggregator.initialize.selector, owner, asset, vaults);

        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initializeData);
        commonAggregator = CommonAggregator(address(proxy));
    }

    function testSimpleWithdraw() public {
        _prepareDistribution([uint256(10), 20, 30], 5);

        uint256 bobShares = commonAggregator.convertToShares(13);
        vm.prank(alice);
        commonAggregator.transfer(bob, bobShares);

        vm.prank(bob);
        commonAggregator.approve(address(commonAggregator), bobShares);
        vm.prank(bob);
        commonAggregator.withdraw(13, bob, bob);

        assertEq(asset.balanceOf(bob), 13);

        assertEq(_vaultsAllocation(vaults[0]), 10 - 2);
        assertEq(_vaultsAllocation(vaults[1]), 20 - 4);
        assertEq(_vaultsAllocation(vaults[2]), 30 - 6);
        assertEq(asset.balanceOf(address(commonAggregator)), 5 - 1);
    }

    function testWithdrawRoundingErrors() public {
        _prepareDistribution([uint256(10), 20, 50], 5);

        uint256 bobShares = commonAggregator.convertToShares(12);
        vm.prank(alice);
        commonAggregator.transfer(bob, bobShares);

        vm.prank(bob);
        commonAggregator.approve(address(commonAggregator), bobShares);
        vm.prank(bob);
        commonAggregator.withdraw(12, bob, bob);

        assertEq(asset.balanceOf(bob), 12);

        assertEq(_vaultsAllocation(vaults[0]), 10 - 1);
        // 2 instead of 3 because of OZ rounding
        assertEq(_vaultsAllocation(vaults[1]), 20 - 2);
        assertEq(_vaultsAllocation(vaults[2]), 50 - 7);
        // Two should come from idle to fix rounding errors
        assertEq(asset.balanceOf(address(commonAggregator)), 5 - 2);
    }

    function testWithdrawRoundingErrors2() public {
        _prepareDistribution([uint256(10), 20, 50], 1);

        uint256 bobShares = commonAggregator.convertToShares(12);
        vm.prank(alice);
        commonAggregator.transfer(bob, bobShares);

        vm.prank(bob);
        commonAggregator.approve(address(commonAggregator), bobShares);
        vm.prank(bob);
        commonAggregator.withdraw(12, bob, bob);

        assertEq(asset.balanceOf(bob), 12);

        // One additional asset from the first vault as there isn't enough in idle
        // to cover for all rounding errors.
        assertEq(_vaultsAllocation(vaults[0]), 10 - 2);
        // 2 instead of 3 because of OZ rounding
        assertEq(_vaultsAllocation(vaults[1]), 20 - 2);
        assertEq(_vaultsAllocation(vaults[2]), 50 - 7);
        // One should come from idle to fix rounding errors (partially)
        assertEq(asset.balanceOf(address(commonAggregator)), 1 - 1);
    }

    function testZeroAssets() public {
        vm.expectRevert(ICommonAggregator.NotEnoughFunds.selector);
        vm.prank(address(commonAggregator));
        commonAggregator.pullFundsProportional(1);
    }

    function testWithdrawAll() public {
        _prepareDistribution([uint256(10), 20, 50], 30);
        uint256 bobShares = commonAggregator.convertToShares(100);
        vm.prank(alice);
        commonAggregator.transfer(bob, bobShares);

        vm.prank(bob);
        commonAggregator.approve(address(commonAggregator), bobShares);
        vm.prank(bob);
        commonAggregator.withdraw(100, bob, bob);

        assertEq(asset.balanceOf(bob), 100);
    }

    function testNotEnoughAssets() public {}

    function testCustomVaultWithdrawLimits() public {}

    function testTryDirectCall() public {}

    function testSimpleRedeem() public {}

    function _vaultsAllocation(IERC4626 vault) internal view returns (uint256) {
        uint256 sharesInAggregator = vault.balanceOf(address(commonAggregator));
        return vault.convertToAssets(sharesInAggregator);
    }

    function _prepareDistribution(uint256[VAULT_COUNT] memory vaultFunds, uint256 idle) internal {
        uint256 initialDeposit = idle;
        for (uint256 i = 0; i < vaultFunds.length; ++i) {
            initialDeposit += vaultFunds[i];
        }

        asset.mint(alice, initialDeposit);

        vm.prank(alice);
        asset.approve(address(commonAggregator), initialDeposit);
        vm.prank(alice);
        commonAggregator.deposit(initialDeposit, alice);

        for (uint256 i = 0; i < VAULT_COUNT; ++i) {
            vm.prank(owner);
            commonAggregator.pushFunds(vaultFunds[i], vaults[i]);
        }
    }
}
