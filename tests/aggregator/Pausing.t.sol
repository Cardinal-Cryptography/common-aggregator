// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC4626, CommonAggregator, ICommonAggregator} from "contracts/CommonAggregator.sol";
import {CommonManagement, ICommonManagement} from "contracts/CommonManagement.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ERC4626Mock} from "tests/mock/ERC4626Mock.sol";
import {ERC20Mock} from "tests/mock/ERC20Mock.sol";
import {setUpAggregator} from "tests/utils.sol";

contract PausingTest is Test {
    address owner = address(0x123);
    address manager = address(0x231);
    address guardian = address(0x312);
    address alice = address(0x456);
    address bob = address(0x789);
    ERC20Mock asset = new ERC20Mock();
    CommonAggregator aggregator;
    CommonManagement management;

    function setUp() public {
        IERC4626[] memory vaults = new IERC4626[](2);
        vaults[0] = new ERC4626Mock(address(asset));
        vaults[1] = new ERC4626Mock(address(asset));

        (aggregator, management) = setUpAggregator(owner, asset, vaults);
        _grantRoles();
    }

    function testOwnerCanPauseUnpauseGlobal() public {
        vm.prank(owner);
        management.pauseUserInteractions();
        vm.prank(owner);
        management.unpauseUserInteractions();
    }

    function testManagerCanPauseUnpauseGlobal() public {
        vm.prank(manager);
        management.pauseUserInteractions();
        vm.prank(manager);
        management.unpauseUserInteractions();
    }

    function testGuardianCanPauseUnpauseGlobal() public {
        vm.prank(guardian);
        management.pauseUserInteractions();
        vm.prank(guardian);
        management.unpauseUserInteractions();
    }

    function testRegularUserCantPauseUnpauseGlobal() public {
        vm.prank(alice);
        vm.expectRevert(ICommonManagement.CallerNotGuardianOrWithHigherRole.selector);

        management.pauseUserInteractions();

        // actually pause, so that unpausing is a correct action
        vm.prank(owner);
        management.pauseUserInteractions();

        vm.prank(alice);
        vm.expectRevert(ICommonManagement.CallerNotGuardianOrWithHigherRole.selector);
        management.unpauseUserInteractions();
    }

    function testUnpausingFailsWhenNotPaused() public {
        vm.prank(owner);
        vm.expectRevert(PausableUpgradeable.ExpectedPause.selector);
        management.unpauseUserInteractions();
    }

    function testPausingFailsWhenPaused() public {
        vm.prank(owner);
        management.pauseUserInteractions();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(owner);
        management.pauseUserInteractions();
    }

    function testMaxDepositIsZeroWhenPaused() public {
        assertGt(aggregator.maxDeposit(alice), 0);

        vm.prank(owner);
        management.pauseUserInteractions();

        assertEq(aggregator.maxDeposit(alice), 0);
    }

    function testMaxMintIsZeroWhenPaused() public {
        assertGt(aggregator.maxMint(alice), 0);

        vm.prank(owner);
        management.pauseUserInteractions();

        assertEq(aggregator.maxMint(alice), 0);
    }

    function testMaxWithdrawIsZeroWhenPaused() public {
        asset.mint(alice, 1000);
        vm.prank(alice);
        asset.approve(address(aggregator), 1000);
        vm.prank(alice);
        aggregator.deposit(1000, alice);

        assertEq(aggregator.maxWithdraw(alice), 1000);

        vm.prank(owner);
        management.pauseUserInteractions();

        assertEq(aggregator.maxWithdraw(alice), 0);
    }

    function testMaxRedeemIsZeroWhenPaused() public {
        asset.mint(alice, 1000);
        vm.prank(alice);
        asset.approve(address(aggregator), 1000);
        vm.prank(alice);
        uint256 shares = aggregator.deposit(1000, alice);

        assertGt(shares, 0);
        assertEq(aggregator.maxRedeem(alice), shares);

        vm.prank(owner);
        management.pauseUserInteractions();

        assertEq(aggregator.maxRedeem(alice), 0);
    }

    function testMaxEmergencyRedeemDoesNotChangeWhenPaused() public {
        asset.mint(alice, 1000);
        vm.prank(alice);
        asset.approve(address(aggregator), 1000);
        vm.prank(alice);
        uint256 shares = aggregator.deposit(1000, alice);

        assertGt(shares, 0);
        assertEq(aggregator.maxEmergencyRedeem(alice), shares);

        vm.prank(owner);
        management.pauseUserInteractions();

        assertEq(aggregator.maxEmergencyRedeem(alice), shares);
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
        management.pauseUserInteractions();

        // deposit fails when paused
        vm.prank(alice);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        aggregator.deposit(500, alice);

        // unpause
        vm.prank(owner);
        management.unpauseUserInteractions();

        // deposit succeeds again
        vm.prank(alice);
        aggregator.deposit(500, alice);
    }

    function testMintGetsPaused() public {
        asset.mint(alice, 1000);
        vm.prank(alice);
        asset.approve(address(aggregator), 1000);
        uint256 shares = aggregator.convertToShares(1000);

        // first mint works
        vm.prank(alice);
        aggregator.mint(shares / 2, bob);

        // pause
        vm.prank(owner);
        management.pauseUserInteractions();

        // mint fails when paused
        vm.prank(alice);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        aggregator.mint(shares / 2, bob);

        // unpause
        vm.prank(owner);
        management.unpauseUserInteractions();

        // mint succeeds again
        vm.prank(alice);
        aggregator.mint(shares / 2, bob);
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
        management.pauseUserInteractions();

        // withdraw fails when paused
        vm.prank(alice);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        aggregator.withdraw(500, alice, alice);

        // unpause
        vm.prank(owner);
        management.unpauseUserInteractions();

        // withdraw succeeds again
        vm.prank(alice);
        aggregator.withdraw(500, alice, alice);
    }

    function testRedeemGetsPaused() public {
        asset.mint(alice, 1000);
        vm.prank(alice);
        asset.approve(address(aggregator), 1000);
        vm.prank(alice);
        uint256 shares = aggregator.deposit(1000, alice);

        // first redeem works
        vm.prank(alice);
        aggregator.redeem(shares / 2, alice, alice);

        // pause
        vm.prank(owner);
        management.pauseUserInteractions();

        // redeem fails when paused
        vm.prank(alice);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        aggregator.redeem(shares / 2, alice, alice);

        // unpause
        vm.prank(owner);
        management.unpauseUserInteractions();

        // redeem succeeds again
        vm.prank(alice);
        aggregator.redeem(shares / 2, alice, alice);
    }

    function testEmergencyRedeemDoesNotGetPaused() public {
        asset.mint(alice, 1000);
        vm.prank(alice);
        asset.approve(address(aggregator), 1000);
        vm.prank(alice);
        uint256 shares = aggregator.deposit(1000, alice);

        // first emergency redeem works
        vm.prank(alice);
        aggregator.emergencyRedeem(shares / 2, alice, alice);

        // pause
        vm.prank(owner);
        management.pauseUserInteractions();

        // emergency redeem still works when paused
        vm.prank(alice);
        aggregator.emergencyRedeem(shares / 2, alice, alice);
    }

    function testCantUnpauseWhenPendingVaultForceRemoval() public {
        IERC4626 vault0 = aggregator.getVaults()[0];
        IERC4626 vault1 = aggregator.getVaults()[1];
        vm.prank(owner);
        management.submitForceRemoveVault(vault0);
        vm.prank(owner);
        management.submitForceRemoveVault(vault1);

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(ICommonManagement.PendingVaultForceRemovals.selector, 2));
        management.unpauseUserInteractions();

        vm.prank(guardian);
        management.cancelForceRemoveVault(vault0);

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(ICommonManagement.PendingVaultForceRemovals.selector, 1));
        management.unpauseUserInteractions();

        vm.warp(30 days);
        vm.prank(owner);
        management.forceRemoveVault(vault1);

        vm.prank(guardian);
        management.unpauseUserInteractions();

        assertEq(aggregator.paused(), false);
    }

    function _grantRoles() private {
        vm.prank(owner);
        management.grantRole(ICommonManagement.Roles.Manager, manager);
        vm.prank(owner);
        management.grantRole(ICommonManagement.Roles.Guardian, guardian);
    }
}
