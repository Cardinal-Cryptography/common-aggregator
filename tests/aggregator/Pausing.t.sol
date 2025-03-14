// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {CommonAggregator} from "contracts/CommonAggregator.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ERC4626Mock} from "tests/mock/ERC4626Mock.sol";
import {ERC20Mock} from "tests/mock/ERC20Mock.sol";

contract PausingTest is Test {
    address owner = address(0x123);
    address alice = address(0x456);
    address bob = address(0x789);
    ERC20Mock asset = new ERC20Mock();
    CommonAggregator aggregator;

    function setUp() public {
        CommonAggregator implementation = new CommonAggregator();
        ERC4626Mock[] memory vaults = new ERC4626Mock[](2);
        vaults[0] = new ERC4626Mock(address(asset));
        vaults[1] = new ERC4626Mock(address(asset));

        bytes memory initializeData = abi.encodeWithSelector(CommonAggregator.initialize.selector, owner, asset, vaults);

        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initializeData);
        aggregator = CommonAggregator(address(proxy));
    }

    function testOnlyOwnerCanPauseUnpauseGlobal() public {
        vm.prank(owner);
        aggregator.pauseUserInteractions();
        vm.prank(owner);
        aggregator.unpauseUserInteractions();

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, keccak256("OWNER"))
        );
        aggregator.pauseUserInteractions();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, keccak256("OWNER"))
        );
        aggregator.unpauseUserInteractions();
    }

    function testUnpausingFailsWhenNotPaused() public {
        vm.prank(owner);
        vm.expectRevert(PausableUpgradeable.ExpectedPause.selector);
        aggregator.unpauseUserInteractions();
    }

    function testPausingFailsWhenPaused() public {
        vm.prank(owner);
        aggregator.pauseUserInteractions();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(owner);
        aggregator.pauseUserInteractions();
    }

    function testDepositGetsPaused() public {
        asset.mint(alice, 1000);
        vm.prank(alice);
        asset.approve(address(aggregator), 1000);

        // first deposit works
        vm.prank(alice);
        aggregator.deposit(500, alice);

        // pause
        vm.prank(owner);
        aggregator.pauseUserInteractions();

        // deposit fails when paused
        vm.prank(alice);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        aggregator.deposit(100, alice);

        // unpause
        vm.prank(owner);
        aggregator.unpauseUserInteractions();

        // deposit succeeds again
        vm.prank(alice);
        aggregator.deposit(500, alice);
    }

    function testMintGetsPaused() public {
        asset.mint(alice, 1000);
        vm.prank(alice);
        asset.approve(address(aggregator), 1000);

        // first mint works
        vm.prank(alice);
        aggregator.mint(500 * 10000, bob);

        // pause
        vm.prank(owner);
        aggregator.pauseUserInteractions();

        // mint fails when paused
        vm.prank(alice);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        aggregator.mint(500 * 10000, bob);

        // unpause
        vm.prank(owner);
        aggregator.unpauseUserInteractions();

        // mint succeeds again
        vm.prank(alice);
        aggregator.mint(500 * 10000, bob);
    }

    function testWithdrawGetsPaused() public {
        asset.mint(alice, 1000);
        vm.prank(alice);
        asset.approve(address(aggregator), 1000);
        vm.prank(alice);
        aggregator.deposit(1000, alice);

        // first withdraw works
        vm.prank(alice);
        aggregator.withdraw(500, alice, alice);

        // pause
        vm.prank(owner);
        aggregator.pauseUserInteractions();

        // withdraw fails when paused
        vm.prank(alice);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        aggregator.withdraw(500, alice, alice);

        // unpause
        vm.prank(owner);
        aggregator.unpauseUserInteractions();

        // withdraw succeeds again
        vm.prank(alice);
        aggregator.withdraw(500, alice, alice);
    }

    function testRedeemGetsPaused() public {
        asset.mint(alice, 1000);
        vm.prank(alice);
        asset.approve(address(aggregator), 1000);
        vm.prank(alice);
        aggregator.deposit(1000, alice);

        // first withdraw works
        vm.prank(alice);
        aggregator.redeem(500 * 10000, alice, alice);

        // pause
        vm.prank(owner);
        aggregator.pauseUserInteractions();

        // withdraw fails when paused
        vm.prank(alice);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        aggregator.redeem(500 * 10000, alice, alice);

        // unpause
        vm.prank(owner);
        aggregator.unpauseUserInteractions();

        // withdraw succeeds again
        vm.prank(alice);
        aggregator.redeem(500 * 10000, alice, alice);
    }
}
