// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {CommonAggregator, ICommonAggregator} from "contracts/CommonAggregator.sol";
import {CommonManagement} from "contracts/CommonManagement.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ERC4626Mock} from "tests/mock/ERC4626Mock.sol";
import {ERC20Mock} from "tests/mock/ERC20Mock.sol";
import {MAX_BPS} from "contracts/Math.sol";
import {setUpAggregator} from "tests/utils.sol";

contract CommonAggregatorTest is Test {
    uint256 constant STARTING_TIMESTAMP = 100_000_000;

    CommonAggregator commonAggregator;
    CommonManagement commonManagement;
    address owner = address(0x123);
    address rebalancer = address(0x321);

    ERC20Mock asset = new ERC20Mock();
    ERC4626Mock[] vaults = new ERC4626Mock[](2);

    address alice = address(0x456);

    function setUp() public {
        vm.warp(STARTING_TIMESTAMP);
        vaults[0] = new ERC4626Mock(address(asset));
        vaults[1] = new ERC4626Mock(address(asset));
        IERC4626[] memory ierc4626Vaults = new IERC4626[](2);
        ierc4626Vaults[0] = vaults[0];
        ierc4626Vaults[1] = vaults[1];

        (commonAggregator, commonManagement) = setUpAggregator(owner, asset, ierc4626Vaults);
        vm.prank(owner);
        commonManagement.grantRole(CommonManagement.Roles.Rebalancer, rebalancer);
    }

    function testPushFunds() public {
        uint256 amount = 100;
        asset.mint(alice, amount);

        vm.prank(alice);
        asset.approve(address(commonAggregator), amount);
        vm.prank(alice);
        commonAggregator.deposit(amount, alice);

        vm.prank(rebalancer);
        commonManagement.pushFunds(amount, vaults[0]);
        assertEq(asset.balanceOf(address(vaults[0])), amount);
    }

    function testPushFundsObeyLimit() public {
        uint256 amount = 100;
        uint256 maxToPush = 50;

        asset.mint(alice, amount);

        vm.prank(alice);
        asset.approve(address(commonAggregator), amount);
        vm.prank(alice);
        commonAggregator.deposit(amount, alice);
        vm.prank(owner);
        commonManagement.setLimit(vaults[0], MAX_BPS / 2);

        vm.expectRevert(abi.encodeWithSelector(ICommonAggregator.AllocationLimitExceeded.selector, vaults[0]));
        vm.prank(rebalancer);
        commonManagement.pushFunds(maxToPush + 1, vaults[0]);
        vm.prank(rebalancer);
        commonManagement.pushFunds(maxToPush, vaults[0]);
        vm.expectRevert(abi.encodeWithSelector(ICommonAggregator.AllocationLimitExceeded.selector, vaults[0]));
        vm.prank(rebalancer);
        commonManagement.pushFunds(1, vaults[0]);
        assertEq(asset.balanceOf(address(vaults[0])), maxToPush);
    }

    function testPushFundsObeyOnlyLimitForTarget() public {
        uint256 amount = 100;
        asset.mint(alice, amount);
        vm.prank(alice);
        asset.approve(address(commonAggregator), amount);
        vm.prank(alice);
        commonAggregator.deposit(amount, alice);

        vm.prank(rebalancer);
        commonManagement.pushFunds(50, vaults[0]);
        vm.prank(owner);
        commonManagement.setLimit(vaults[0], 0);

        vm.prank(rebalancer);
        commonManagement.pushFunds(50, vaults[1]);
    }

    function testPullFunds() public {
        uint256 assets = 110;
        uint256 shares = 100;
        asset.mint(address(vaults[0]), assets);
        vaults[0].mint(address(commonAggregator), shares);

        vm.prank(owner);
        commonManagement.setLimit(vaults[0], 0);
        vm.prank(rebalancer);
        commonManagement.pullFunds(60, vaults[0]);
        assertEq(asset.balanceOf(address(commonAggregator)), 60);
        assertEq(asset.balanceOf(address(vaults[0])), 50);
    }

    function testPullFundsByShares() public {
        uint256 assets = 1100;
        uint256 shares = 1000;
        asset.mint(address(vaults[0]), assets);
        vaults[0].mint(address(commonAggregator), shares);

        vm.prank(owner);
        commonManagement.setLimit(vaults[0], 0);
        vm.prank(rebalancer);
        commonManagement.pullFundsByShares(shares / 2, vaults[0]);
        assertEq(asset.balanceOf(address(commonAggregator)), 549);
        assertEq(asset.balanceOf(address(vaults[0])), 551);
    }

    function testZeroFunds() public {
        vm.prank(rebalancer);
        commonManagement.pushFunds(0, vaults[0]);
        vm.prank(rebalancer);
        commonManagement.pullFunds(0, vaults[0]);
        vm.prank(rebalancer);
        commonManagement.pullFundsByShares(0, vaults[0]);
        vm.expectRevert();
        vm.prank(rebalancer);
        commonManagement.pushFunds(1, vaults[0]);
        vm.expectRevert();
        vm.prank(rebalancer);
        commonManagement.pullFunds(1, vaults[0]);
        vm.expectRevert();
        vm.prank(rebalancer);
        commonManagement.pullFundsByShares(1, vaults[0]);

        uint256 amount = 100;
        asset.mint(alice, amount);
        vm.prank(alice);
        asset.approve(address(commonAggregator), amount);
        vm.prank(alice);
        commonAggregator.deposit(amount, alice);

        vm.prank(rebalancer);
        commonManagement.pushFunds(0, vaults[0]);
        vm.prank(rebalancer);
        commonManagement.pullFunds(0, vaults[0]);
        vm.prank(rebalancer);
        commonManagement.pullFundsByShares(0, vaults[0]);
        vm.expectRevert();
        vm.prank(rebalancer);
        commonManagement.pullFunds(1, vaults[0]);
        vm.expectRevert();
        vm.prank(rebalancer);
        commonManagement.pullFundsByShares(1, vaults[0]);

        vm.prank(rebalancer);
        commonManagement.pushFunds(amount, vaults[0]);

        vm.prank(rebalancer);
        commonManagement.pushFunds(0, vaults[0]);
        vm.prank(rebalancer);
        commonManagement.pullFunds(0, vaults[0]);
        vm.prank(rebalancer);
        commonManagement.pullFundsByShares(0, vaults[0]);
    }

    function testVaultPresentOnTheListCheck() public {
        uint256 amount = 100;
        asset.mint(alice, amount);
        vm.prank(alice);
        asset.approve(address(commonAggregator), amount);
        vm.prank(alice);
        commonAggregator.deposit(amount, alice);
        vm.prank(rebalancer);
        commonManagement.pushFunds(amount - 1, vaults[0]);

        IERC4626[] memory notAddedAddresses = new IERC4626[](4);
        notAddedAddresses[0] = IERC4626(commonAggregator);
        notAddedAddresses[1] = IERC4626(new ERC4626Mock(address(asset)));
        notAddedAddresses[2] = IERC4626(address(0x0));
        notAddedAddresses[3] = IERC4626(address(0x1));

        for (uint256 i = 0; i < notAddedAddresses.length; i++) {
            IERC4626 a = notAddedAddresses[i];

            vm.expectRevert(abi.encodeWithSelector(ICommonAggregator.VaultNotOnTheList.selector, a));
            vm.prank(rebalancer);
            commonManagement.pushFunds(1, a);

            vm.expectRevert(abi.encodeWithSelector(ICommonAggregator.VaultNotOnTheList.selector, a));
            vm.prank(rebalancer);
            commonManagement.pullFunds(1, a);

            vm.expectRevert(abi.encodeWithSelector(ICommonAggregator.VaultNotOnTheList.selector, a));
            vm.prank(rebalancer);
            commonManagement.pullFundsByShares(1, a);

            vm.expectRevert(abi.encodeWithSelector(ICommonAggregator.VaultNotOnTheList.selector, a));
            vm.prank(owner);
            commonManagement.setLimit(a, 0);
        }
    }

    function testRebalanceAfterLoss() public {
        uint256 amount = 1000;
        asset.mint(alice, amount);
        vm.prank(alice);
        asset.approve(address(commonAggregator), amount);
        vm.prank(alice);
        commonAggregator.deposit(amount, alice);

        // Initial allocation
        vm.prank(rebalancer);
        commonManagement.pushFunds(600, vaults[0]);
        vm.prank(rebalancer);
        commonManagement.pushFunds(300, vaults[1]);
        assertEq(commonAggregator.totalAssets(), 1000);

        asset.burn(address(vaults[0]), 100);
        asset.mint(address(vaults[1]), 60);

        commonAggregator.updateHoldingsState();
        vm.warp(STARTING_TIMESTAMP + 20 days);
        commonAggregator.updateHoldingsState();

        assertEq(commonAggregator.totalAssets(), 959, "pre rebalance totalAssets");

        vm.prank(rebalancer);
        commonManagement.pullFunds(500, vaults[0]);
        vm.prank(rebalancer);
        commonManagement.pushFunds(500, vaults[1]);

        assertEq(commonAggregator.totalAssets(), 959, "post rebalance totalAssets");
        assertEq(asset.balanceOf(address(commonAggregator)), 100);
        assertEq(asset.balanceOf(address(vaults[1])), 860);
        assertEq(asset.balanceOf(address(vaults[0])), 0);
    }

    function testRolesPushPullFunds() public {
        address manager = address(0x111);
        vm.prank(owner);
        commonManagement.grantRole(CommonManagement.Roles.Manager, manager);

        uint256 amount = 100;
        asset.mint(alice, amount);
        vm.prank(alice);
        asset.approve(address(commonAggregator), amount);
        vm.prank(alice);
        commonAggregator.deposit(amount, alice);
        vm.prank(rebalancer);
        commonManagement.pushFunds(amount / 2, vaults[0]);

        vm.prank(manager);
        commonManagement.pushFunds(1, vaults[0]);
        vm.prank(owner);
        commonManagement.pushFunds(1, vaults[0]);
        vm.expectRevert(CommonManagement.CallerNotRebalancerOrWithHigherRole.selector);
        vm.prank(alice);
        commonManagement.pushFunds(1, vaults[0]);

        vm.prank(manager);
        commonManagement.pullFunds(1, vaults[0]);
        vm.prank(owner);
        commonManagement.pullFunds(1, vaults[0]);
        vm.expectRevert(CommonManagement.CallerNotRebalancerOrWithHigherRole.selector);
        vm.prank(alice);
        commonManagement.pullFunds(1, vaults[0]);

        vm.prank(manager);
        commonManagement.pullFundsByShares(1, vaults[0]);
        vm.prank(owner);
        commonManagement.pullFundsByShares(1, vaults[0]);
        vm.expectRevert(CommonManagement.CallerNotRebalancerOrWithHigherRole.selector);
        vm.prank(alice);
        commonManagement.pullFundsByShares(1, vaults[0]);
    }

    function testRolesSetLimit() public {
        address manager = address(0x111);
        vm.prank(owner);
        commonManagement.grantRole(CommonManagement.Roles.Manager, manager);
        bytes4 errorSelector = OwnableUpgradeable.OwnableUnauthorizedAccount.selector;

        address[] memory notAllowed = new address[](3);
        notAllowed[0] = alice;
        notAllowed[1] = rebalancer;
        notAllowed[2] = manager;

        for (uint256 i = 0; i < notAllowed.length; i++) {
            address a = notAllowed[i];
            vm.expectRevert(abi.encodeWithSelector(errorSelector, a));
            vm.prank(a);
            commonManagement.setLimit(vaults[0], 0);

            vm.expectRevert(abi.encodeWithSelector(errorSelector, a));
            vm.prank(a);
            commonManagement.setLimit(vaults[0], MAX_BPS);
        }
    }

    function testSetLimitMaxLimit() public {
        vm.expectRevert(ICommonAggregator.IncorrectMaxAllocationLimit.selector);
        vm.prank(owner);
        commonManagement.setLimit(vaults[0], MAX_BPS + 1);
    }
}
