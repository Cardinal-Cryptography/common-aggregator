// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {CommonAggregator, ICommonAggregator} from "contracts/CommonAggregator.sol";
import {CommonManagement} from "contracts/CommonManagement.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC4626Mock} from "tests/mock/ERC4626Mock.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20Mock} from "tests/mock/ERC20Mock.sol";
import {MAX_BPS} from "contracts/Math.sol";
import {setUpAggregator} from "tests/utils.sol";

contract VaultManagementTest is Test {
    uint256 constant STARTING_TIMESTAMP = 100_000_000;
    address owner = address(0x123);
    address manager = address(0x321);
    address guardian = address(0x432);
    address protocolFeeReceiver = address(1);

    ERC20Mock asset = new ERC20Mock();
    address alice = address(0x456);

    function setUp() public {
        vm.warp(STARTING_TIMESTAMP);
    }

    function testAddFirstVaultToEmptyAggregator() public {
        (CommonAggregator aggregator, CommonManagement management) = _noVaultAggregator();
        IERC4626 vault = new ERC4626Mock(address(asset));
        _testAddVault(aggregator, management, vault);
        assertEq(aggregator.getVaults().length, 1);
    }

    function testAddVault() public {
        (CommonAggregator aggregator, CommonManagement management) = _aggregatorWithThreeVaults();
        IERC4626 vault = new ERC4626Mock(address(asset));
        aggregator.ensureVaultCanBeAdded(vault);

        _testAddVault(aggregator, management, vault);

        aggregator.ensureVaultIsPresent(vault);
        assertEq(aggregator.getVaults().length, 4);
    }

    function _testAddVault(CommonAggregator aggregator, CommonManagement management, IERC4626 vault) private {
        vm.expectEmit(true, true, true, true, address(management), 1);
        emit CommonManagement.VaultAdditionSubmitted(address(vault), vm.getBlockTimestamp() + 3 days);
        vm.prank(manager);
        management.submitAddVault(vault);

        vm.warp(vm.getBlockTimestamp() + 3 days + 5 hours);

        vm.expectEmit(true, true, true, true, address(aggregator), 1);
        emit ICommonAggregator.VaultAdded(address(vault));
        vm.prank(manager);
        management.addVault(vault);

        assertGt(aggregator.getVaults().length, 0);
        assertEq(address(aggregator.getVaults()[aggregator.getVaults().length - 1]), address(vault));
        assertEq(aggregator.getMaxAllocationLimit(vault), 0);
    }

    function testCantAddVaultTooEarly() public {
        (, CommonManagement management) = _noVaultAggregator();
        IERC4626 vault = new ERC4626Mock(address(asset));

        vm.prank(manager);
        management.submitAddVault(vault);

        // Limits are inclusive, so it's still too early
        vm.warp(STARTING_TIMESTAMP + 3 days);

        bytes32 actionHash = keccak256(abi.encode(CommonManagement.TimelockTypes.ADD_VAULT, vault));
        vm.expectRevert(
            abi.encodeWithSelector(CommonManagement.ActionTimelocked.selector, actionHash, STARTING_TIMESTAMP + 3 days)
        );
        vm.prank(manager);
        management.addVault(vault);
    }

    function testCantSubmitAddExistingVault() public {
        (CommonAggregator aggregator, CommonManagement management) = _aggregatorWithThreeVaults();
        IERC4626 vault = aggregator.getVaults()[0];

        vm.expectRevert(abi.encodeWithSelector(ICommonAggregator.VaultAlreadyAdded.selector, vault));
        vm.prank(manager);
        management.submitAddVault(vault);
    }

    function testCantAddItself() public {
        (CommonAggregator aggregator, CommonManagement management) = _aggregatorWithThreeVaults();

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ICommonAggregator.VaultIsAggregator.selector));
        management.submitAddVault(IERC4626(address(aggregator)));
    }

    function testCantSubmitVaultWithDifferentAsset() public {
        (, CommonManagement management) = _aggregatorWithThreeVaults();
        IERC4626 vault = new ERC4626Mock(address(0x111));

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ICommonAggregator.IncorrectAsset.selector, asset, address(0x111)));
        management.submitAddVault(vault);
    }

    function testCantSubmitAddSameVaultTwice() public {
        (CommonAggregator aggregator, CommonManagement management) = _aggregatorWithThreeVaults();
        IERC4626 vault = new ERC4626Mock(address(asset));

        vm.prank(manager);
        management.submitAddVault(vault);

        vm.expectRevert(
            abi.encodeWithSelector(
                CommonManagement.ActionAlreadyRegistered.selector,
                keccak256(abi.encode(CommonManagement.TimelockTypes.ADD_VAULT, vault))
            )
        );
        vm.prank(manager);
        management.submitAddVault(vault);

        vm.expectRevert();
        vm.prank(manager);
        management.addVault(vault);

        vm.prank(manager);
        management.cancelAddVault(vault);

        vm.prank(manager);
        management.submitAddVault(vault);

        vm.warp(STARTING_TIMESTAMP + 4 days);
        vm.prank(manager);
        management.addVault(vault);

        assertEq(aggregator.getVaults().length, 4);
        assertEq(aggregator.getMaxAllocationLimit(vault), 0);
    }

    function testCancelAddVault() public {
        (, CommonManagement management) = _aggregatorWithThreeVaults();
        IERC4626 vault = new ERC4626Mock(address(asset));
        vm.prank(manager);
        management.submitAddVault(vault);

        vm.warp(STARTING_TIMESTAMP + 2 days);

        vm.expectEmit(true, true, true, true, address(management), 1);
        emit CommonManagement.VaultAdditionCancelled(address(vault));
        vm.prank(guardian);
        management.cancelAddVault(vault);

        vm.warp(STARTING_TIMESTAMP + 4 days);
        vm.expectRevert();
        vm.prank(manager);
        management.addVault(vault);
    }

    function testAddManyVaults() public {
        (CommonAggregator aggregator, CommonManagement management) = _aggregatorWithSixVault();
        IERC4626 vaultA = new ERC4626Mock(address(asset));
        IERC4626 vaultB = new ERC4626Mock(address(asset));
        IERC4626 vaultC = new ERC4626Mock(address(asset));

        vm.prank(manager);
        management.submitAddVault(vaultA);

        vm.warp(STARTING_TIMESTAMP + 1 days);

        vm.prank(manager);
        management.submitAddVault(vaultB);
        vm.prank(manager);
        management.submitAddVault(vaultC);

        vm.warp(STARTING_TIMESTAMP + 4 days + 1 seconds);

        vm.prank(manager);
        management.addVault(vaultB);

        vm.warp(STARTING_TIMESTAMP + 4 days + 2 seconds);

        vm.prank(manager);
        management.addVault(vaultA);

        assertEq(aggregator.getVaults().length, 8);
        assertEq(address(aggregator.getVaults()[6]), address(vaultB));
        assertEq(address(aggregator.getVaults()[7]), address(vaultA));

        vm.prank(manager);
        vm.expectRevert(ICommonAggregator.VaultLimitExceeded.selector);
        management.addVault(vaultC);
    }

    function testChangeLimitAfterAddingAndRemovingVault() public {
        (CommonAggregator aggregator, CommonManagement management) = _aggregatorWithThreeVaults();
        IERC4626 vault = new ERC4626Mock(address(asset));
        vm.prank(manager);
        management.submitAddVault(vault);

        vm.warp(STARTING_TIMESTAMP + 4 days);
        vm.prank(manager);
        management.addVault(vault);

        assertEq(aggregator.getMaxAllocationLimit(vault), 0);

        vm.prank(owner);
        management.setLimit(vault, MAX_BPS);

        assertEq(aggregator.getMaxAllocationLimit(vault), MAX_BPS);

        vm.prank(manager);
        management.removeVault(vault);

        // vault limit should be deleted
        assertEq(aggregator.getMaxAllocationLimit(vault), 0);
    }

    function testRemoveVault() public {
        (CommonAggregator aggregator, CommonManagement management) = _aggregatorWithThreeVaults();
        IERC4626[] memory initialVaults = aggregator.getVaults();

        vm.prank(manager);
        vm.expectEmit(true, true, true, true, address(aggregator), 1);
        emit ICommonAggregator.VaultRemoved(address(initialVaults[1]));
        management.removeVault(initialVaults[1]);

        assertEq(aggregator.getVaults().length, 2);
        assertEq(address(aggregator.getVaults()[0]), address(initialVaults[0]));
        assertEq(address(aggregator.getVaults()[1]), address(initialVaults[2]));

        vm.prank(manager);
        management.removeVault(initialVaults[2]);
        vm.prank(manager);
        management.removeVault(initialVaults[0]);
        assertEq(aggregator.getVaults().length, 0);
    }

    function testRemoveVaultRedeemsShares() public {
        (CommonAggregator aggregator, CommonManagement management) = _aggregatorWithThreeVaults();
        IERC4626[] memory initialVaults = aggregator.getVaults();
        ERC4626Mock toRemove = ERC4626Mock(address(initialVaults[1]));

        asset.mint(address(alice), 1000);

        vm.prank(alice);
        asset.approve(address(aggregator), 1000);
        vm.prank(alice);
        aggregator.deposit(1000, alice);

        vm.prank(manager);
        management.pushFunds(1000, toRemove);

        // Frontrunned donation
        asset.mint(address(toRemove), 400);
        toRemove.mint(address(aggregator), 400);

        vm.prank(manager);
        management.removeVault(toRemove);
        aggregator.updateHoldingsState();

        assertEq(aggregator.totalAssets(), 1400);
        assertEq(aggregator.balanceOf(alice), 1000 * 10 ** (aggregator.decimals() - asset.decimals()));
        assertEq(toRemove.balanceOf(address(aggregator)), 0);
    }

    function testRemoveVaultRedeemSharesWhenItCantRedeemAllOfThem() public {
        (CommonAggregator aggregator, CommonManagement management) = _aggregatorWithThreeVaults();
        IERC4626[] memory initialVaults = aggregator.getVaults();
        ERC4626Mock toRemove = ERC4626Mock(address(initialVaults[1]));

        asset.mint(address(alice), 1000);

        vm.prank(alice);
        asset.approve(address(aggregator), 1000);
        vm.prank(alice);
        aggregator.deposit(1000, alice);

        vm.prank(manager);
        management.pushFunds(1000, toRemove);

        toRemove.setWithdrawLimit(999);
        toRemove.setRedeemLimit(999);

        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxRedeem.selector, address(aggregator), 1000, 999)
        );
        management.removeVault(toRemove);
    }

    function testCantRemoveVaultWhenPendingForceRemoval() public {
        (CommonAggregator aggregator, CommonManagement management) = _aggregatorWithThreeVaults();
        IERC4626[] memory initialVaults = aggregator.getVaults();
        ERC4626Mock toRemove = ERC4626Mock(address(initialVaults[1]));

        vm.prank(manager);
        management.submitForceRemoveVault(toRemove);

        vm.expectRevert(abi.encodeWithSelector(CommonManagement.PendingVaultForceRemoval.selector, toRemove));
        vm.prank(manager);
        management.removeVault(toRemove);
    }

    function testForceRemoveVaultNotPaused() public {
        (CommonAggregator aggregator, CommonManagement management) = _aggregatorWithThreeVaults();
        _testSimpleForceRemoveMiddleVault(aggregator, management);
    }

    function testForceRemoveVaultPaused() public {
        (CommonAggregator aggregator, CommonManagement management) = _aggregatorWithThreeVaults();
        vm.prank(owner);
        management.pauseUserInteractions();

        _testSimpleForceRemoveMiddleVault(aggregator, management);
    }

    function _testSimpleForceRemoveMiddleVault(CommonAggregator aggregator, CommonManagement management) private {
        assertEq(aggregator.getVaults().length, 3, "Incorrect test usage");

        IERC4626[] memory initialVaults = aggregator.getVaults();
        ERC4626Mock toRemove = ERC4626Mock(address(initialVaults[1]));

        vm.prank(manager);
        vm.expectEmit(true, true, true, true, address(management), 1);
        emit CommonManagement.VaultForceRemovalSubmitted(address(toRemove), vm.getBlockTimestamp() + 3 days);
        management.submitForceRemoveVault(toRemove);

        assertEq(aggregator.paused(), true);

        vm.warp(STARTING_TIMESTAMP + 8 days);

        vm.prank(manager);
        vm.expectEmit(true, true, true, true, address(aggregator), 1);
        emit ICommonAggregator.VaultForceRemoved(address(toRemove));
        management.forceRemoveVault(toRemove);

        assertEq(aggregator.getVaults().length, 2);
        assertEq(address(aggregator.getVaults()[0]), address(initialVaults[0]));
        assertEq(address(aggregator.getVaults()[1]), address(initialVaults[2]));
    }

    function testCantForceRemoveVaultTooEarly() public {
        (CommonAggregator aggregator, CommonManagement management) = _aggregatorWithThreeVaults();
        IERC4626[] memory initialVaults = aggregator.getVaults();
        ERC4626Mock toRemove = ERC4626Mock(address(initialVaults[1]));

        vm.expectRevert(
            abi.encodeWithSelector(
                CommonManagement.ActionNotRegistered.selector,
                keccak256(abi.encode(CommonManagement.TimelockTypes.FORCE_REMOVE_VAULT, toRemove))
            )
        );
        vm.prank(manager);
        management.forceRemoveVault(toRemove);

        vm.prank(manager);
        management.submitForceRemoveVault(toRemove);

        // Limits are inclusive, so it's still too early
        vm.warp(STARTING_TIMESTAMP + 3 days);

        bytes32 actionHash = keccak256(abi.encode(CommonManagement.TimelockTypes.FORCE_REMOVE_VAULT, toRemove));
        vm.expectRevert(
            abi.encodeWithSelector(CommonManagement.ActionTimelocked.selector, actionHash, STARTING_TIMESTAMP + 3 days)
        );
        vm.prank(manager);
        management.forceRemoveVault(toRemove);
    }

    function submitForceRemoveSameVaultTwiceFails() public {
        (CommonAggregator aggregator, CommonManagement management) = _aggregatorWithThreeVaults();
        IERC4626[] memory initialVaults = aggregator.getVaults();
        ERC4626Mock toRemove = ERC4626Mock(address(initialVaults[1]));

        vm.prank(manager);
        management.submitForceRemoveVault(toRemove);

        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(
                CommonManagement.ActionAlreadyRegistered.selector,
                keccak256(abi.encode(CommonManagement.TimelockTypes.FORCE_REMOVE_VAULT, toRemove))
            )
        );
        management.submitForceRemoveVault(toRemove);
    }

    function submitForceRemoveOfNonExistentVaultFails() public {
        (, CommonManagement management) = _aggregatorWithThreeVaults();
        ERC4626Mock fakeVault = new ERC4626Mock(address(3));

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ICommonAggregator.VaultNotOnTheList.selector, fakeVault));
        management.submitForceRemoveVault(fakeVault);
    }

    function testCancelForceRemoveVault() public {
        (CommonAggregator aggregator, CommonManagement management) = _aggregatorWithThreeVaults();
        IERC4626[] memory initialVaults = aggregator.getVaults();
        ERC4626Mock toRemove = ERC4626Mock(address(initialVaults[1]));

        // Cancelling too early fails
        vm.expectRevert(
            abi.encodeWithSelector(
                CommonManagement.ActionNotRegistered.selector,
                keccak256(abi.encode(CommonManagement.TimelockTypes.FORCE_REMOVE_VAULT, toRemove))
            )
        );
        vm.prank(guardian);
        management.cancelForceRemoveVault(toRemove);

        // Successfull submission and cancellation
        vm.prank(manager);
        management.submitForceRemoveVault(toRemove);
        vm.warp(STARTING_TIMESTAMP + 4 days);
        vm.expectEmit(true, true, true, true, address(management), 1);
        emit CommonManagement.VaultForceRemovalCancelled(address(toRemove));
        vm.prank(guardian);
        management.cancelForceRemoveVault(toRemove);

        // Cancelling for the second time fails
        vm.expectRevert(
            abi.encodeWithSelector(
                CommonManagement.ActionNotRegistered.selector,
                keccak256(abi.encode(CommonManagement.TimelockTypes.FORCE_REMOVE_VAULT, toRemove))
            )
        );
        vm.prank(guardian);
        management.cancelForceRemoveVault(toRemove);

        // Force removal doesn't work after cancelling
        vm.warp(STARTING_TIMESTAMP + 8 days);
        bytes32 actionHash = keccak256(abi.encode(CommonManagement.TimelockTypes.FORCE_REMOVE_VAULT, toRemove));
        vm.expectRevert(abi.encodeWithSelector(CommonManagement.ActionNotRegistered.selector, actionHash));
        vm.prank(manager);
        management.forceRemoveVault(toRemove);
    }

    function testForceRemoveVaultRemovesAssetsWhenVaultIsBroken() public {
        (CommonAggregator aggregator, CommonManagement management) = _aggregatorWithThreeVaults();
        _firstDeposit(aggregator, 1000);
        _equalDistributionFromIdle(aggregator, management, true);
        assertEq(aggregator.totalAssets(), 1000);

        ERC4626Mock(address(aggregator.getVaults()[1])).setReverting(true);
        _testSimpleForceRemoveMiddleVault(aggregator, management);

        assertEq(aggregator.totalAssets(), 750);
    }

    function testForceRemoveVaultRedeemsSharesIfPossilbe() public {
        (CommonAggregator aggregator, CommonManagement management) = _aggregatorWithThreeVaults();
        _firstDeposit(aggregator, 1000);
        _equalDistributionFromIdle(aggregator, management, true);
        assertEq(aggregator.totalAssets(), 1000);

        ERC4626Mock(address(aggregator.getVaults()[1])).setRedeemLimit(200);
        _testSimpleForceRemoveMiddleVault(aggregator, management);

        assertEq(aggregator.totalAssets(), 950);
    }

    function testSubmitForceRemoveVaultDoesntRemoveAssetsYet() public {
        (CommonAggregator aggregator, CommonManagement management) = _aggregatorWithThreeVaults();
        _firstDeposit(aggregator, 1000);
        _equalDistributionFromIdle(aggregator, management, true);
        assertEq(aggregator.totalAssets(), 1000);

        IERC4626[] memory initialVaults = aggregator.getVaults();
        ERC4626Mock toRemove = ERC4626Mock(address(initialVaults[1]));

        toRemove.setReverting(true);

        vm.prank(manager);
        management.submitForceRemoveVault(toRemove);

        assertEq(aggregator.totalAssets(), 1000);
    }

    function testUserCanEmergencyRedeemWhenPendingForceRemoval() public {
        (CommonAggregator aggregator, CommonManagement management) = _aggregatorWithThreeVaults();
        _firstDeposit(aggregator, 1000);
        _equalDistributionFromIdle(aggregator, management, true);

        uint256 aliceShares = aggregator.totalSupply();

        assertEq(aggregator.totalAssets(), 1000);

        IERC4626[] memory initialVaults = aggregator.getVaults();
        ERC4626Mock toRemove = ERC4626Mock(address(initialVaults[1]));

        toRemove.setReverting(true);

        vm.prank(manager);
        management.submitForceRemoveVault(toRemove);

        // Normal redeem should fail
        vm.prank(alice);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        aggregator.redeem(aliceShares, alice, alice);

        vm.prank(alice);
        aggregator.emergencyRedeem(aliceShares, alice, alice);
        assertEq(aggregator.totalAssets(), 0);

        assertEq(asset.balanceOf(address(alice)), 250);
        assertEq(initialVaults[0].balanceOf(address(alice)), 250, "vault 0");
        assertEq(initialVaults[1].balanceOf(address(alice)), 250, "vault 1");
        assertEq(initialVaults[2].balanceOf(address(alice)), 250, "vault 2");
    }

    function testRolesSubmitAddVault() public {
        (, CommonManagement management) = _noVaultAggregator();
        IERC4626 vault = new ERC4626Mock(address(asset));

        vm.expectRevert(CommonManagement.CallerNotManagerNorOwner.selector);
        vm.prank(alice);
        management.submitAddVault(vault);

        vm.expectRevert(CommonManagement.CallerNotManagerNorOwner.selector);
        vm.prank(guardian);
        management.submitAddVault(vault);

        vm.prank(manager);
        management.submitAddVault(vault);

        IERC4626 vault2 = new ERC4626Mock(address(asset));
        vm.prank(owner);
        management.submitAddVault(vault2);
    }

    function testRolesCancelAddVault() public {
        (, CommonManagement management) = _noVaultAggregator();
        IERC4626 vault = new ERC4626Mock(address(asset));

        vm.prank(manager);
        management.submitAddVault(vault);

        vm.expectRevert(CommonManagement.CallerNotGuardianOrWithHigherRole.selector);
        vm.prank(alice);
        management.cancelAddVault(vault);

        vm.prank(guardian);
        management.cancelAddVault(vault);

        vm.prank(manager);
        management.submitAddVault(vault);
        vm.prank(manager);
        management.cancelAddVault(vault);

        vm.prank(manager);
        management.submitAddVault(vault);
        vm.prank(owner);
        management.cancelAddVault(vault);
    }

    function testRolesAddVault() public {
        (, CommonManagement management) = _noVaultAggregator();
        IERC4626 vault = new ERC4626Mock(address(asset));
        IERC4626 vault2 = new ERC4626Mock(address(asset));

        vm.prank(manager);
        management.submitAddVault(vault);
        vm.prank(manager);
        management.submitAddVault(vault2);

        vm.warp(STARTING_TIMESTAMP + 4 days);

        vm.expectRevert(CommonManagement.CallerNotManagerNorOwner.selector);
        vm.prank(alice);
        management.addVault(vault);

        vm.expectRevert(CommonManagement.CallerNotManagerNorOwner.selector);
        vm.prank(guardian);
        management.addVault(vault);

        vm.prank(manager);
        management.addVault(vault);

        vm.prank(owner);
        management.addVault(vault2);
    }

    function testRolesRemoveVault() public {
        (CommonAggregator aggregator, CommonManagement management) = _aggregatorWithThreeVaults();

        IERC4626 vaultToRemove = aggregator.getVaults()[0];
        vm.expectRevert(CommonManagement.CallerNotManagerNorOwner.selector);
        vm.prank(alice);
        management.removeVault(vaultToRemove);

        vm.expectRevert(CommonManagement.CallerNotManagerNorOwner.selector);
        vm.prank(guardian);
        management.removeVault(vaultToRemove);

        vm.prank(manager);
        management.removeVault(vaultToRemove);

        vaultToRemove = aggregator.getVaults()[0];
        vm.prank(owner);
        management.removeVault(vaultToRemove);
    }

    function testRolesSubmitForceRemoveVault() public {
        (CommonAggregator aggregator, CommonManagement management) = _aggregatorWithThreeVaults();

        IERC4626 vault0 = aggregator.getVaults()[0];
        IERC4626 vault1 = aggregator.getVaults()[1];

        vm.expectRevert(CommonManagement.CallerNotManagerNorOwner.selector);
        vm.prank(alice);
        management.submitForceRemoveVault(vault0);

        vm.expectRevert(CommonManagement.CallerNotManagerNorOwner.selector);
        vm.prank(guardian);
        management.submitForceRemoveVault(vault0);

        vm.prank(manager);
        management.submitForceRemoveVault(vault0);

        vm.prank(owner);
        management.submitForceRemoveVault(vault1);
    }

    function testRolesCancelForceRemoveVault() public {
        (CommonAggregator aggregator, CommonManagement management) = _aggregatorWithThreeVaults();

        IERC4626 vaultToRemove = aggregator.getVaults()[0];
        vm.prank(manager);
        management.submitForceRemoveVault(vaultToRemove);

        vm.expectRevert(CommonManagement.CallerNotGuardianOrWithHigherRole.selector);
        vm.prank(alice);
        management.cancelForceRemoveVault(vaultToRemove);

        vm.prank(guardian);
        management.cancelForceRemoveVault(vaultToRemove);

        vm.prank(manager);
        management.submitForceRemoveVault(vaultToRemove);
        vm.prank(manager);
        management.cancelForceRemoveVault(vaultToRemove);

        vm.prank(owner);
        management.submitForceRemoveVault(vaultToRemove);
        vm.prank(owner);
        management.cancelForceRemoveVault(vaultToRemove);
    }

    function testRolesForceRemoveVault() public {
        (CommonAggregator aggregator, CommonManagement management) = _aggregatorWithThreeVaults();

        IERC4626 vault0 = aggregator.getVaults()[0];
        IERC4626 vault1 = aggregator.getVaults()[1];
        vm.prank(manager);
        management.submitForceRemoveVault(vault0);
        vm.prank(manager);
        management.submitForceRemoveVault(vault1);

        vm.warp(STARTING_TIMESTAMP + 8 days);

        vm.expectRevert(CommonManagement.CallerNotManagerNorOwner.selector);
        vm.prank(alice);
        management.forceRemoveVault(vault0);

        vm.expectRevert(CommonManagement.CallerNotManagerNorOwner.selector);
        vm.prank(guardian);
        management.forceRemoveVault(vault0);

        vm.prank(manager);
        management.forceRemoveVault(vault0);
        vm.prank(owner);
        management.forceRemoveVault(vault1);

        assertEq(aggregator.getVaults().length, 1);
    }

    function _aggregatorWithThreeVaults() private returns (CommonAggregator aggregator, CommonManagement management) {
        IERC4626[] memory vaults = new IERC4626[](3);
        vaults[0] = new ERC4626Mock(address(asset));
        vaults[1] = new ERC4626Mock(address(asset));
        vaults[2] = new ERC4626Mock(address(asset));

        (aggregator, management) = setUpAggregator(owner, asset, protocolFeeReceiver, vaults);
        _grantRoles(management);
    }

    function _aggregatorWithSixVault() private returns (CommonAggregator aggregator, CommonManagement management) {
        IERC4626[] memory vaults = new IERC4626[](6);
        for (uint256 i = 0; i < vaults.length; ++i) {
            vaults[i] = new ERC4626Mock(address(asset));
        }

        (aggregator, management) = setUpAggregator(owner, asset, protocolFeeReceiver, vaults);
        _grantRoles(management);
    }

    function _noVaultAggregator() private returns (CommonAggregator aggregator, CommonManagement management) {
        (aggregator, management) = setUpAggregator(owner, asset, protocolFeeReceiver, new IERC4626[](0));
        _grantRoles(management);
    }

    function _grantRoles(CommonManagement management) private {
        vm.prank(owner);
        management.grantRole(CommonManagement.Roles.Manager, manager);

        vm.prank(owner);
        management.grantRole(CommonManagement.Roles.Guardian, guardian);
    }

    function _firstDeposit(CommonAggregator aggregator, uint256 initialDeposit) private returns (uint256) {
        asset.mint(alice, initialDeposit);

        vm.prank(alice);
        asset.approve(address(aggregator), initialDeposit);
        vm.prank(alice);
        return aggregator.deposit(initialDeposit, alice);
    }

    function _equalDistributionFromIdle(
        CommonAggregator aggregator,
        CommonManagement management,
        bool includeIdleInDistribution
    ) internal {
        uint256 totalAssets = aggregator.totalAssets();
        uint256 part = totalAssets / (aggregator.getVaults().length + (includeIdleInDistribution ? 1 : 0));
        for (uint256 i = 0; i < aggregator.getVaults().length; ++i) {
            IERC4626 vault = aggregator.getVaults()[i];
            vm.prank(owner);
            management.pushFunds(part, vault);
        }
    }
}
