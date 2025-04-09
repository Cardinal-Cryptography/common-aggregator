// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {CommonAggregator} from "contracts/CommonAggregator.sol";
import {CommonManagement} from "contracts/CommonManagement.sol";
import {ICommonManagement} from "contracts/interfaces/ICommonManagement.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC4626Mock} from "tests/mock/ERC4626Mock.sol";
import {ERC20Mock} from "tests/mock/ERC20Mock.sol";
import {setUpAggregator} from "tests/utils.sol";

contract CommonAggregatorTest is Test {
    uint256 constant STARTING_TIMESTAMP = 100_000_000;

    CommonAggregator commonAggregator;
    CommonManagement commonManagement;
    address owner = address(0x123);
    ERC20Mock asset = new ERC20Mock();
    IERC4626[] vaults = new IERC4626[](1);

    address alice = address(0x456);
    address bob = address(0x678);

    function setUp() public {
        vaults[0] = new ERC4626Mock(address(asset));
        (commonAggregator, commonManagement) = setUpAggregator(owner, asset, vaults);
    }

    function testRoleGranting() public {
        assertFalse(commonManagement.hasRole(ICommonManagement.Roles.Manager, alice));
        vm.prank(owner);
        commonManagement.grantRole(ICommonManagement.Roles.Manager, alice);
        assertTrue(commonManagement.hasRole(ICommonManagement.Roles.Manager, alice));

        assertFalse(commonManagement.hasRole(ICommonManagement.Roles.Guardian, alice));
        vm.prank(owner);
        commonManagement.grantRole(ICommonManagement.Roles.Guardian, alice);
        assertTrue(commonManagement.hasRole(ICommonManagement.Roles.Guardian, alice));

        assertFalse(commonManagement.hasRole(ICommonManagement.Roles.Rebalancer, alice));
        vm.prank(owner);
        commonManagement.grantRole(ICommonManagement.Roles.Rebalancer, alice);
        assertTrue(commonManagement.hasRole(ICommonManagement.Roles.Rebalancer, alice));
    }

    function testRoleRevoking() public {
        vm.startPrank(owner);
        commonManagement.grantRole(ICommonManagement.Roles.Manager, bob);
        commonManagement.grantRole(ICommonManagement.Roles.Guardian, bob);
        commonManagement.grantRole(ICommonManagement.Roles.Rebalancer, bob);
        vm.stopPrank();

        assertTrue(commonManagement.hasRole(ICommonManagement.Roles.Manager, bob));
        vm.prank(owner);
        commonManagement.revokeRole(ICommonManagement.Roles.Manager, bob);
        assertFalse(commonManagement.hasRole(ICommonManagement.Roles.Manager, bob));

        assertTrue(commonManagement.hasRole(ICommonManagement.Roles.Guardian, bob));
        vm.prank(owner);
        commonManagement.revokeRole(ICommonManagement.Roles.Guardian, bob);
        assertFalse(commonManagement.hasRole(ICommonManagement.Roles.Guardian, bob));

        assertTrue(commonManagement.hasRole(ICommonManagement.Roles.Rebalancer, bob));
        vm.prank(owner);
        commonManagement.revokeRole(ICommonManagement.Roles.Rebalancer, bob);
        assertFalse(commonManagement.hasRole(ICommonManagement.Roles.Rebalancer, bob));
    }
}
