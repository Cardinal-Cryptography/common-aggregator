// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {CommonAggregator, ICommonAggregator} from "contracts/CommonAggregator.sol";
import {CommonManagement, ICommonManagement} from "contracts/CommonManagement.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC4626Mock} from "tests/mock/ERC4626Mock.sol";
import {ERC20Mock} from "tests/mock/ERC20Mock.sol";
import {MAX_BPS} from "contracts/Math.sol";

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
        CommonAggregator aggregatorImplementation = new CommonAggregator();
        CommonManagement managementImplementation = new CommonManagement();
        vaults[0] = new ERC4626Mock(address(asset));
        vaults[1] = new ERC4626Mock(address(asset));
        IERC4626[] memory ierc4626Vaults = new IERC4626[](2);
        ierc4626Vaults[0] = vaults[0];
        ierc4626Vaults[1] = vaults[1];

        ERC1967Proxy aggregatorProxy = new ERC1967Proxy(address(aggregatorImplementation), "");
        ERC1967Proxy managementProxy = new ERC1967Proxy(address(managementImplementation), "");
        commonAggregator = CommonAggregator(address(aggregatorProxy));
        commonManagement = CommonManagement(address(managementProxy));
        commonAggregator.initialize(commonManagement, asset, ierc4626Vaults);
        commonManagement.initialize(owner, commonAggregator);
        vm.prank(owner);
        commonManagement.grantRole(keccak256("REBALANCER"), rebalancer);
    }

    function testPushFunds() public {
        uint256 amount = 100;
        asset.mint(alice, amount);

        vm.prank(alice);
        asset.approve(address(commonAggregator), amount);
        vm.prank(alice);
        commonAggregator.deposit(amount, alice);

        vm.prank(rebalancer);
        commonAggregator.pushFunds(amount, vaults[0]);
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
        commonAggregator.setLimit(vaults[0], MAX_BPS / 2);

        vm.expectRevert(abi.encodeWithSelector(ICommonAggregator.AllocationLimitExceeded.selector, vaults[0]));
        vm.prank(rebalancer);
        commonAggregator.pushFunds(maxToPush + 1, vaults[0]);
        vm.prank(rebalancer);
        commonAggregator.pushFunds(maxToPush, vaults[0]);
        vm.expectRevert(abi.encodeWithSelector(ICommonAggregator.AllocationLimitExceeded.selector, vaults[0]));
        vm.prank(rebalancer);
        commonAggregator.pushFunds(1, vaults[0]);
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
        commonAggregator.pushFunds(50, vaults[0]);
        vm.prank(owner);
        commonAggregator.setLimit(vaults[0], 0);

        vm.prank(rebalancer);
        commonAggregator.pushFunds(50, vaults[1]);
    }

    function testPullFunds() public {
        uint256 assets = 110;
        uint256 shares = 100;
        asset.mint(address(vaults[0]), assets);
        vaults[0].mint(address(commonAggregator), shares);

        vm.prank(owner);
        commonAggregator.setLimit(vaults[0], 0);
        vm.prank(rebalancer);
        commonAggregator.pullFunds(60, vaults[0]);
        assertEq(asset.balanceOf(address(commonAggregator)), 60);
        assertEq(asset.balanceOf(address(vaults[0])), 50);
    }

    function testPullFundsByShares() public {
        uint256 assets = 1100;
        uint256 shares = 1000;
        asset.mint(address(vaults[0]), assets);
        vaults[0].mint(address(commonAggregator), shares);

        vm.prank(owner);
        commonAggregator.setLimit(vaults[0], 0);
        vm.prank(rebalancer);
        commonAggregator.pullFundsByShares(shares / 2, vaults[0]);
        assertEq(asset.balanceOf(address(commonAggregator)), 549);
        assertEq(asset.balanceOf(address(vaults[0])), 551);
    }

    function testZeroFunds() public {
        vm.prank(rebalancer);
        commonAggregator.pushFunds(0, vaults[0]);
        vm.prank(rebalancer);
        commonAggregator.pullFunds(0, vaults[0]);
        vm.prank(rebalancer);
        commonAggregator.pullFundsByShares(0, vaults[0]);
        vm.expectRevert();
        vm.prank(rebalancer);
        commonAggregator.pushFunds(1, vaults[0]);
        vm.expectRevert();
        vm.prank(rebalancer);
        commonAggregator.pullFunds(1, vaults[0]);
        vm.expectRevert();
        vm.prank(rebalancer);
        commonAggregator.pullFundsByShares(1, vaults[0]);

        uint256 amount = 100;
        asset.mint(alice, amount);
        vm.prank(alice);
        asset.approve(address(commonAggregator), amount);
        vm.prank(alice);
        commonAggregator.deposit(amount, alice);

        vm.prank(rebalancer);
        commonAggregator.pushFunds(0, vaults[0]);
        vm.prank(rebalancer);
        commonAggregator.pullFunds(0, vaults[0]);
        vm.prank(rebalancer);
        commonAggregator.pullFundsByShares(0, vaults[0]);
        vm.expectRevert();
        vm.prank(rebalancer);
        commonAggregator.pullFunds(1, vaults[0]);
        vm.expectRevert();
        vm.prank(rebalancer);
        commonAggregator.pullFundsByShares(1, vaults[0]);

        vm.prank(rebalancer);
        commonAggregator.pushFunds(amount, vaults[0]);

        vm.prank(rebalancer);
        commonAggregator.pushFunds(0, vaults[0]);
        vm.prank(rebalancer);
        commonAggregator.pullFunds(0, vaults[0]);
        vm.prank(rebalancer);
        commonAggregator.pullFundsByShares(0, vaults[0]);
    }

    function testVaultPresentOnTheListCheck() public {
        uint256 amount = 100;
        asset.mint(alice, amount);
        vm.prank(alice);
        asset.approve(address(commonAggregator), amount);
        vm.prank(alice);
        commonAggregator.deposit(amount, alice);
        vm.prank(rebalancer);
        commonAggregator.pushFunds(amount - 1, vaults[0]);

        IERC4626[] memory notAddedAddresses = new IERC4626[](4);
        notAddedAddresses[0] = IERC4626(commonAggregator);
        notAddedAddresses[1] = IERC4626(new ERC4626Mock(address(asset)));
        notAddedAddresses[2] = IERC4626(address(0x0));
        notAddedAddresses[3] = IERC4626(address(0x1));

        for (uint256 i = 0; i < notAddedAddresses.length; i++) {
            IERC4626 a = notAddedAddresses[i];

            vm.expectRevert(abi.encodeWithSelector(ICommonAggregator.VaultNotOnTheList.selector, a));
            vm.prank(rebalancer);
            commonAggregator.pushFunds(1, a);

            vm.expectRevert(abi.encodeWithSelector(ICommonAggregator.VaultNotOnTheList.selector, a));
            vm.prank(rebalancer);
            commonAggregator.pullFunds(1, a);

            vm.expectRevert(abi.encodeWithSelector(ICommonAggregator.VaultNotOnTheList.selector, a));
            vm.prank(rebalancer);
            commonAggregator.pullFundsByShares(1, a);

            vm.expectRevert(abi.encodeWithSelector(ICommonAggregator.VaultNotOnTheList.selector, a));
            vm.prank(owner);
            commonAggregator.setLimit(a, 0);
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
        commonAggregator.pushFunds(600, vaults[0]);
        vm.prank(rebalancer);
        commonAggregator.pushFunds(300, vaults[1]);
        assertEq(commonAggregator.totalAssets(), 1000);

        asset.burn(address(vaults[0]), 100);
        asset.mint(address(vaults[1]), 60);

        commonAggregator.updateHoldingsState();
        vm.warp(STARTING_TIMESTAMP + 20 days);
        commonAggregator.updateHoldingsState();

        assertEq(commonAggregator.totalAssets(), 959, "pre rebalance totalAssets");

        vm.prank(rebalancer);
        commonAggregator.pullFunds(500, vaults[0]);
        vm.prank(rebalancer);
        commonAggregator.pushFunds(500, vaults[1]);

        assertEq(commonAggregator.totalAssets(), 959, "post rebalance totalAssets");
        assertEq(asset.balanceOf(address(commonAggregator)), 100);
        assertEq(asset.balanceOf(address(vaults[1])), 860);
        assertEq(asset.balanceOf(address(vaults[0])), 0);
    }

    function testRolesPushPullFunds() public {
        address manager = address(0x111);
        vm.prank(owner);
        commonManagement.grantRole(keccak256("MANAGER"), manager);

        uint256 amount = 100;
        asset.mint(alice, amount);
        vm.prank(alice);
        asset.approve(address(commonAggregator), amount);
        vm.prank(alice);
        commonAggregator.deposit(amount, alice);
        vm.prank(rebalancer);
        commonAggregator.pushFunds(amount / 2, vaults[0]);

        vm.prank(manager);
        commonAggregator.pushFunds(1, vaults[0]);
        vm.prank(owner);
        commonAggregator.pushFunds(1, vaults[0]);
        vm.expectRevert(ICommonManagement.CallerNotRebalancerOrWithHigherRole.selector);
        vm.prank(alice);
        commonAggregator.pushFunds(1, vaults[0]);

        vm.prank(manager);
        commonAggregator.pullFunds(1, vaults[0]);
        vm.prank(owner);
        commonAggregator.pullFunds(1, vaults[0]);
        vm.expectRevert(ICommonManagement.CallerNotRebalancerOrWithHigherRole.selector);
        vm.prank(alice);
        commonAggregator.pullFunds(1, vaults[0]);

        vm.prank(manager);
        commonAggregator.pullFundsByShares(1, vaults[0]);
        vm.prank(owner);
        commonAggregator.pullFundsByShares(1, vaults[0]);
        vm.expectRevert(ICommonManagement.CallerNotRebalancerOrWithHigherRole.selector);
        vm.prank(alice);
        commonAggregator.pullFundsByShares(1, vaults[0]);
    }

    function testRolesSetLimit() public {
        address manager = address(0x111);
        vm.prank(owner);
        commonManagement.grantRole(keccak256("MANAGER"), manager);
        bytes4 errorSelector = IAccessControl.AccessControlUnauthorizedAccount.selector;

        address[] memory notAllowed = new address[](3);
        notAllowed[0] = alice;
        notAllowed[1] = rebalancer;
        notAllowed[2] = manager;

        for (uint256 i = 0; i < notAllowed.length; i++) {
            address a = notAllowed[i];
            vm.expectRevert(abi.encodeWithSelector(errorSelector, a, keccak256("OWNER")));
            vm.prank(a);
            commonAggregator.setLimit(vaults[0], 0);

            vm.expectRevert(abi.encodeWithSelector(errorSelector, a, keccak256("OWNER")));
            vm.prank(a);
            commonAggregator.setLimit(vaults[0], MAX_BPS);
        }
    }

    function testSetLimitMaxLimit() public {
        vm.expectRevert(ICommonAggregator.IncorrectMaxAllocationLimit.selector);
        vm.prank(owner);
        commonAggregator.setLimit(vaults[0], MAX_BPS + 1);
    }
}
