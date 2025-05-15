// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {CommonAggregator} from "contracts/CommonAggregator.sol";
import {CommonManagement} from "contracts/CommonManagement.sol";
import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "tests/mock/ERC20Mock.sol";
import {ERC4626Mock} from "tests/mock/ERC4626Mock.sol";
import {setUpAggregator} from "tests/utils.sol";

contract CommonAggregatorTest is Test {
    uint256 internal constant STARTING_TIMESTAMP = 100_000_000;

    CommonAggregator internal commonAggregator;
    CommonManagement internal commonManagement;
    address internal owner = address(0x123);
    ERC20Mock internal asset = new ERC20Mock();
    IERC4626[] internal vaults = new IERC4626[](1);

    address internal alice = address(0x456);
    address internal bob = address(0x678);
    address internal protocolFeeReceiver = address(1);

    function setUp() public {
        vaults[0] = new ERC4626Mock(address(asset));
        (commonAggregator, commonManagement) = setUpAggregator(owner, asset, protocolFeeReceiver, vaults);
    }

    function testRoleGranting() public {
        assertFalse(commonManagement.hasRole(CommonManagement.Roles.Manager, alice));
        vm.prank(owner);
        commonManagement.grantRole(CommonManagement.Roles.Manager, alice);
        assertTrue(commonManagement.hasRole(CommonManagement.Roles.Manager, alice));

        assertFalse(commonManagement.hasRole(CommonManagement.Roles.Guardian, alice));
        vm.prank(owner);
        commonManagement.grantRole(CommonManagement.Roles.Guardian, alice);
        assertTrue(commonManagement.hasRole(CommonManagement.Roles.Guardian, alice));

        assertFalse(commonManagement.hasRole(CommonManagement.Roles.Rebalancer, alice));
        vm.prank(owner);
        commonManagement.grantRole(CommonManagement.Roles.Rebalancer, alice);
        assertTrue(commonManagement.hasRole(CommonManagement.Roles.Rebalancer, alice));
    }

    function testRoleRevoking() public {
        vm.startPrank(owner);
        commonManagement.grantRole(CommonManagement.Roles.Manager, bob);
        commonManagement.grantRole(CommonManagement.Roles.Guardian, bob);
        commonManagement.grantRole(CommonManagement.Roles.Rebalancer, bob);
        vm.stopPrank();

        assertTrue(commonManagement.hasRole(CommonManagement.Roles.Manager, bob));
        vm.prank(owner);
        commonManagement.revokeRole(CommonManagement.Roles.Manager, bob);
        assertFalse(commonManagement.hasRole(CommonManagement.Roles.Manager, bob));

        assertTrue(commonManagement.hasRole(CommonManagement.Roles.Guardian, bob));
        vm.prank(owner);
        commonManagement.revokeRole(CommonManagement.Roles.Guardian, bob);
        assertFalse(commonManagement.hasRole(CommonManagement.Roles.Guardian, bob));

        assertTrue(commonManagement.hasRole(CommonManagement.Roles.Rebalancer, bob));
        vm.prank(owner);
        commonManagement.revokeRole(CommonManagement.Roles.Rebalancer, bob);
        assertFalse(commonManagement.hasRole(CommonManagement.Roles.Rebalancer, bob));
    }
}
