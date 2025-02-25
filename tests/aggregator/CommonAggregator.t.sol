// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {CommonAggregator} from "contracts/CommonAggregator.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC4626Mock} from "tests/mock/ERC4626Mock.sol";
import {ERC20Mock} from "tests/mock/ERC20Mock.sol";

contract CommonAggregatorTest is Test {
    uint256 constant STARTING_TIMESTAMP = 100;

    CommonAggregator commonAggregator;
    address owner = address(0x123);
    ERC20Mock asset = new ERC20Mock();
    ERC4626Mock[] vaults = new ERC4626Mock[](2);

    function setUp() public {
        vm.warp(STARTING_TIMESTAMP);
        CommonAggregator implementation = new CommonAggregator();
        vaults[0] = new ERC4626Mock(address(asset));
        vaults[1] = new ERC4626Mock(address(asset));

        bytes memory initializeData = abi.encodeWithSelector(CommonAggregator.initialize.selector, owner, asset, vaults);

        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initializeData);
        commonAggregator = CommonAggregator(address(proxy));
    }

    function testRoleGranting() public {
        assertTrue(commonAggregator.hasRole(commonAggregator.DEFAULT_ADMIN_ROLE(), owner));
        assertTrue(commonAggregator.hasRole(commonAggregator.OWNER(), owner));

        address otherAccount = address(0x456);
        assertFalse(commonAggregator.hasRole(commonAggregator.OWNER(), otherAccount));
        assertFalse(commonAggregator.hasRole(commonAggregator.MANAGER(), otherAccount));

        vm.prank(owner);
        commonAggregator.grantRole(keccak256("MANAGER"), otherAccount);
        assertTrue(commonAggregator.hasRole(commonAggregator.MANAGER(), otherAccount));
    }

    // Reporting

    function testDepositUpdatesTotalAssets() public {
        assertEq(commonAggregator.totalAssets(), 0);

        address user = address(0x456);
        asset.mint(user, 1000);

        vm.prank(user);
        asset.approve(address(commonAggregator), 1000);
        vm.prank(user);
        commonAggregator.deposit(1000, user);

        assertEq(commonAggregator.totalAssets(), 1000);
    }

    function testMaxWithdraw() public {
        address alice = address(0x456);
        asset.mint(alice, 1000);

        vm.prank(alice);
        asset.approve(address(commonAggregator), 1000);

        vm.prank(alice);
        commonAggregator.deposit(100, alice);
        assertEq(commonAggregator.maxWithdraw(alice), 100);

        vm.prank(alice);
        commonAggregator.deposit(900, alice);
        assertEq(commonAggregator.maxWithdraw(alice), 1000);
    }

    function testMaxWithdrawOnAirdrop() public {
        address alice = address(0x456);
        address bob = address(0x678);
        asset.mint(alice, 1000);
        asset.mint(bob, 500);

        vm.prank(alice);
        asset.approve(address(commonAggregator), 1000);
        vm.prank(alice);
        commonAggregator.deposit(1000, alice);

        vm.prank(bob);
        asset.approve(address(commonAggregator), 500);
        vm.prank(bob);
        commonAggregator.deposit(500, bob);

        // Initial amounts
        assertEq(commonAggregator.maxWithdraw(alice), 1000);
        assertEq(commonAggregator.maxWithdraw(bob), 500);
        assertEq(commonAggregator.totalAssets(), 1500);

        asset.mint(address(commonAggregator), 150);

        // Rewards are buffered
        assertEq(commonAggregator.maxWithdraw(alice), 1000);
        assertEq(commonAggregator.maxWithdraw(bob), 500);
        assertEq(commonAggregator.totalAssets(), 1500);

        commonAggregator.updateHoldingsState();

        vm.warp(STARTING_TIMESTAMP + 2 days);

        // after 10% of buffering time
        assertEq(commonAggregator.maxWithdraw(alice), 1009);
        assertEq(commonAggregator.maxWithdraw(bob), 504);

        vm.warp(STARTING_TIMESTAMP + 20 days);

        assertEq(commonAggregator.maxWithdraw(alice), 1099);
        assertEq(commonAggregator.maxWithdraw(bob), 549);
    }
}
