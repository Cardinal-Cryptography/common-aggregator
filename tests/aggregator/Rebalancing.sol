// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {CommonAggregator} from "contracts/CommonAggregator.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC4626Mock} from "tests/mock/ERC4626Mock.sol";
import {ERC20Mock} from "tests/mock/ERC20Mock.sol";
import {MAX_BPS} from "contracts/Math.sol";

contract CommonAggregatorTest is Test {
    uint256 constant STARTING_TIMESTAMP = 100_000_000;

    CommonAggregator commonAggregator;
    address owner = address(0x123);
    address rebalancer = address(0x321);

    ERC20Mock asset = new ERC20Mock();
    ERC4626Mock[] vaults = new ERC4626Mock[](2);

    address alice = address(0x456);

    function setUp() public {
        vm.warp(STARTING_TIMESTAMP);
        CommonAggregator implementation = new CommonAggregator();
        vaults[0] = new ERC4626Mock(address(asset));
        vaults[1] = new ERC4626Mock(address(asset));

        bytes memory initializeData = abi.encodeWithSelector(CommonAggregator.initialize.selector, owner, asset, vaults);

        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initializeData);
        commonAggregator = CommonAggregator(address(proxy));
        vm.prank(owner);
        commonAggregator.grantRole(keccak256("REBALANCER"), rebalancer);
    }

    function testPushFunds() public {
        uint256 amount = 100;
        asset.mint(alice, amount);

        vm.prank(alice);
        asset.approve(address(commonAggregator), amount);
        vm.prank(alice);
        commonAggregator.deposit(amount, alice);

        vm.prank(rebalancer);
        commonAggregator.pushFunds(amount, address(vaults[0]));
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
        commonAggregator.setLimit(address(vaults[0]), MAX_BPS / 2);

        vm.expectRevert();
        vm.prank(rebalancer);
        commonAggregator.pushFunds(maxToPush + 1, address(vaults[0]));
        vm.prank(rebalancer);
        commonAggregator.pushFunds(maxToPush, address(vaults[0]));
        vm.expectRevert();
        vm.prank(rebalancer);
        commonAggregator.pushFunds(1, address(vaults[0]));
        assertEq(asset.balanceOf(address(vaults[0])), maxToPush);
    }

    function testPullFunds() public {
        uint256 assets = 110;
        uint256 shares = 100;
        asset.mint(address(vaults[0]), assets);
        vaults[0].mint(address(commonAggregator), shares);

        vm.prank(owner);
        commonAggregator.setLimit(address(vaults[0]), 0);
        vm.prank(rebalancer);
        commonAggregator.pullFunds(60, address(vaults[0]));
        assertEq(asset.balanceOf(address(commonAggregator)), 60);
        assertEq(asset.balanceOf(address(vaults[0])), 50);
    }

    function testPullFundsByShares() public {
        uint256 assets = 1100;
        uint256 shares = 1000;
        asset.mint(address(vaults[0]), assets);
        vaults[0].mint(address(commonAggregator), shares);

        vm.prank(owner);
        commonAggregator.setLimit(address(vaults[0]), 0);
        vm.prank(rebalancer);
        commonAggregator.pullFundsByShares(shares / 2, address(vaults[0]));
        assertEq(asset.balanceOf(address(commonAggregator)), 549);
        assertEq(asset.balanceOf(address(vaults[0])), 551);
    }

    function testVaultPresentOnTheListCheck() public {
        uint256 amount = 100;
        asset.mint(alice, amount);
        vm.prank(alice);
        asset.approve(address(commonAggregator), amount);
        vm.prank(alice);
        commonAggregator.deposit(amount, alice);
        vm.prank(rebalancer);
        commonAggregator.pushFunds(amount - 1, address(vaults[0]));

        address[] memory notAddedAddresses = new address[](4);
        notAddedAddresses[0] = address(commonAggregator);
        notAddedAddresses[1] = address(new ERC4626Mock(address(asset)));
        notAddedAddresses[2] = address(0x0);
        notAddedAddresses[3] = address(0x1);

        for (uint256 i = 0; i < notAddedAddresses.length; i++) {
            address a = notAddedAddresses[i];

            vm.expectRevert();
            vm.prank(rebalancer);
            commonAggregator.pushFunds(1, a);

            vm.expectRevert();
            vm.prank(rebalancer);
            commonAggregator.pullFunds(1, a);

            vm.expectRevert();
            vm.prank(rebalancer);
            commonAggregator.pullFundsByShares(1, a);

            vm.expectRevert();
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
        commonAggregator.pushFunds(600, address(vaults[0]));
        vm.prank(rebalancer);
        commonAggregator.pushFunds(300, address(vaults[1]));
        assertEq(commonAggregator.totalAssets(), 1000);

        asset.burn(address(vaults[0]), 100);
        asset.mint(address(vaults[1]), 60);

        commonAggregator.updateHoldingsState();
        vm.warp(STARTING_TIMESTAMP + 20 days);
        commonAggregator.updateHoldingsState();

        assertEq(commonAggregator.totalAssets(), 959, "pre rebalance totalAssets");

        vm.prank(rebalancer);
        commonAggregator.pullFunds(500, address(vaults[0]));
        vm.prank(rebalancer);
        commonAggregator.pushFunds(500, address(vaults[1]));

        assertEq(commonAggregator.totalAssets(), 959, "post rebalance totalAssets");
        assertEq(asset.balanceOf(address(commonAggregator)), 100);
        assertEq(asset.balanceOf(address(vaults[1])), 860);
        assertEq(asset.balanceOf(address(vaults[0])), 0);
    }

    function testRoles() public {
        uint256 amount = 100;
        asset.mint(alice, amount);
        vm.prank(alice);
        asset.approve(address(commonAggregator), amount);
        vm.prank(alice);
        commonAggregator.deposit(amount, alice);
        vm.prank(rebalancer);
        commonAggregator.pushFunds(amount / 2, address(vaults[0]));

        vm.prank(owner);
        commonAggregator.pushFunds(1, address(vaults[0]));
        vm.expectRevert();
        vm.prank(alice);
        commonAggregator.pushFunds(1, address(vaults[0]));

        vm.prank(owner);
        commonAggregator.pullFunds(1, address(vaults[0]));
        vm.expectRevert();
        vm.prank(alice);
        commonAggregator.pullFunds(1, address(vaults[0]));

        vm.prank(owner);
        commonAggregator.pullFundsByShares(1, address(vaults[0]));
        vm.expectRevert();
        vm.prank(alice);
        commonAggregator.pullFundsByShares(1, address(vaults[0]));

        vm.expectRevert();
        vm.prank(alice);
        commonAggregator.setLimit(address(vaults[0]), 0);
        vm.expectRevert();
        vm.prank(alice);
        commonAggregator.setLimit(address(vaults[0]), MAX_BPS);

        vm.expectRevert();
        vm.prank(rebalancer);
        commonAggregator.setLimit(address(vaults[0]), 0);
        vm.expectRevert();
        vm.prank(rebalancer);
        commonAggregator.setLimit(address(vaults[0]), MAX_BPS);
    }

    function testSetLimitMaxLimit() public {
        vm.expectRevert();
        vm.prank(owner);
        commonAggregator.setLimit(address(vaults[0]), MAX_BPS + 1);
    }
}
