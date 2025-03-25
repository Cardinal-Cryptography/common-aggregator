// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ICommonAggregator} from "contracts/interfaces/ICommonAggregator.sol";
import {CommonAggregator} from "contracts/CommonAggregator.sol";
import {CommonTimelocks} from "contracts/CommonTimelocks.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC4626Mock} from "tests/mock/ERC4626Mock.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20Mock} from "tests/mock/ERC20Mock.sol";
import {MAX_BPS} from "contracts/Math.sol";

contract VaultManagementTest is Test {
    uint256 constant STARTING_TIMESTAMP = 100_000_000;
    address owner = address(0x123);
    address manager = address(0x321);
    address guardian = address(0x432);

    ERC20Mock asset = new ERC20Mock();
    address alice = address(0x456);

    function setUp() public {
        vm.warp(STARTING_TIMESTAMP);
    }

    function testAddFirstVaultToEmptyAggregator() public {
        CommonAggregator aggregator = _noVaultAggregator();
        IERC4626 vault = new ERC4626Mock(address(asset));
        _testAddVault(aggregator, vault);
        assertEq(aggregator.getVaults().length, 1);
    }

    function testAddVault() public {
        CommonAggregator aggregator = _aggregatorWithThreeVaults();
        IERC4626 vault = new ERC4626Mock(address(asset));
        _testAddVault(aggregator, vault);
        assertEq(aggregator.getVaults().length, 4);
    }

    function _testAddVault(CommonAggregator aggregator, IERC4626 vault) private {
        vm.expectEmit(true, true, true, true, address(aggregator), 1);
        emit ICommonAggregator.VaultAdditionSubmitted(address(vault), vm.getBlockTimestamp() + 7 days);
        vm.prank(manager);
        aggregator.submitAddVault(vault);

        vm.warp(vm.getBlockTimestamp() + 7 days + 5 hours);

        vm.expectEmit(true, true, true, true, address(aggregator), 1);
        emit ICommonAggregator.VaultAdded(address(vault));
        vm.prank(manager);
        aggregator.addVault(vault);

        assertGt(aggregator.getVaults().length, 0);
        assertEq(address(aggregator.getVaults()[aggregator.getVaults().length - 1]), address(vault));
        assertEq(aggregator.getMaxAllocationLimit(vault), 0);
    }

    function testCantAddVaultTooEarly() public {
        CommonAggregator aggregator = _noVaultAggregator();
        IERC4626 vault = new ERC4626Mock(address(asset));

        vm.prank(manager);
        aggregator.submitAddVault(vault);

        // Limits are inclusive, so it's still too early
        vm.warp(STARTING_TIMESTAMP + 7 days);

        bytes32 actionHash = keccak256(abi.encode(CommonAggregator.TimelockTypes.ADD_VAULT, vault));
        vm.expectRevert(
            abi.encodeWithSelector(CommonTimelocks.ActionTimelocked.selector, actionHash, STARTING_TIMESTAMP + 7 days)
        );
        vm.prank(manager);
        aggregator.addVault(vault);
    }

    function testCantSubmitAddExistingVault() public {
        CommonAggregator aggregator = _aggregatorWithThreeVaults();
        IERC4626 vault = aggregator.getVaults()[0];

        vm.expectRevert(abi.encodeWithSelector(ICommonAggregator.VaultAlreadyAdded.selector, vault));
        vm.prank(manager);
        aggregator.submitAddVault(vault);
    }

    function testCantSubmitAddSameVaultTwice() public {
        CommonAggregator aggregator = _aggregatorWithThreeVaults();
        IERC4626 vault = new ERC4626Mock(address(asset));

        vm.prank(manager);
        aggregator.submitAddVault(vault);

        vm.expectRevert(
            abi.encodeWithSelector(
                CommonTimelocks.ActionAlreadyRegistered.selector,
                keccak256(abi.encode(CommonAggregator.TimelockTypes.ADD_VAULT, vault))
            )
        );
        vm.prank(manager);
        aggregator.submitAddVault(vault);

        vm.expectRevert();
        vm.prank(manager);
        aggregator.addVault(vault);

        vm.prank(manager);
        aggregator.cancelAddVault(vault);

        vm.prank(manager);
        aggregator.submitAddVault(vault);

        vm.warp(STARTING_TIMESTAMP + 8 days);
        vm.prank(manager);
        aggregator.addVault(vault);

        assertEq(aggregator.getVaults().length, 4);
        assertEq(aggregator.getMaxAllocationLimit(vault), 0);
    }

    function testCancelAddVault() public {
        CommonAggregator aggregator = _aggregatorWithThreeVaults();
        IERC4626 vault = new ERC4626Mock(address(asset));
        vm.prank(manager);
        aggregator.submitAddVault(vault);

        vm.warp(STARTING_TIMESTAMP + 2 days);

        vm.expectEmit(true, true, true, true, address(aggregator), 1);
        emit ICommonAggregator.VaultAdditionCancelled(address(vault));
        vm.prank(guardian);
        aggregator.cancelAddVault(vault);

        vm.warp(STARTING_TIMESTAMP + 8 days);
        vm.expectRevert();
        vm.prank(manager);
        aggregator.addVault(vault);
    }

    function testAddManyVaults() public {
        CommonAggregator aggregator = _aggregatorWithThreeVaults();
        IERC4626 vaultA = new ERC4626Mock(address(asset));
        IERC4626 vaultB = new ERC4626Mock(address(asset));
        IERC4626 vaultC = new ERC4626Mock(address(asset));

        vm.prank(manager);
        aggregator.submitAddVault(vaultA);

        vm.warp(STARTING_TIMESTAMP + 1 days);

        vm.prank(manager);
        aggregator.submitAddVault(vaultB);
        vm.prank(manager);
        aggregator.submitAddVault(vaultC);

        vm.warp(STARTING_TIMESTAMP + 8 days + 1 seconds);

        vm.prank(manager);
        aggregator.addVault(vaultB);

        vm.warp(STARTING_TIMESTAMP + 8 days + 2 seconds);

        vm.prank(manager);
        aggregator.addVault(vaultA);

        assertEq(aggregator.getVaults().length, 5);
        assertEq(address(aggregator.getVaults()[3]), address(vaultB));
        assertEq(address(aggregator.getVaults()[4]), address(vaultA));

        vm.prank(manager);
        vm.expectRevert(ICommonAggregator.VaultLimitExceeded.selector);
        aggregator.addVault(vaultC);
    }

    function testChangeLimitAfterAddingAndRemovingVault() public {
        CommonAggregator aggregator = _aggregatorWithThreeVaults();
        IERC4626 vault = new ERC4626Mock(address(asset));
        vm.prank(manager);
        aggregator.submitAddVault(vault);

        vm.warp(STARTING_TIMESTAMP + 8 days);
        vm.prank(manager);
        aggregator.addVault(vault);

        assertEq(aggregator.getMaxAllocationLimit(vault), 0);

        vm.prank(owner);
        aggregator.setLimit(vault, MAX_BPS);

        assertEq(aggregator.getMaxAllocationLimit(vault), MAX_BPS);

        vm.prank(manager);
        aggregator.removeVault(vault);

        // vault limit should be deleted
        assertEq(aggregator.getMaxAllocationLimit(vault), 0);
    }

    function testRemoveVault() public {
        CommonAggregator aggregator = _aggregatorWithThreeVaults();
        IERC4626[] memory initialVaults = aggregator.getVaults();

        vm.prank(manager);
        vm.expectEmit(true, true, true, true, address(aggregator), 1);
        emit ICommonAggregator.VaultRemoved(address(initialVaults[1]));
        aggregator.removeVault(initialVaults[1]);

        assertEq(aggregator.getVaults().length, 2);
        assertEq(address(aggregator.getVaults()[0]), address(initialVaults[0]));
        assertEq(address(aggregator.getVaults()[1]), address(initialVaults[2]));

        vm.prank(manager);
        aggregator.removeVault(initialVaults[2]);
        vm.prank(manager);
        aggregator.removeVault(initialVaults[0]);
        assertEq(aggregator.getVaults().length, 0);
    }

    function testRemoveVaultRedeemsShares() public {
        CommonAggregator aggregator = _aggregatorWithThreeVaults();
        IERC4626[] memory initialVaults = aggregator.getVaults();
        ERC4626Mock toRemove = ERC4626Mock(address(initialVaults[1]));

        asset.mint(address(alice), 1000);

        vm.prank(alice);
        asset.approve(address(aggregator), 1000);
        vm.prank(alice);
        aggregator.deposit(1000, alice);

        vm.prank(manager);
        aggregator.pushFunds(1000, toRemove);

        // Frontrunned donation
        asset.mint(address(toRemove), 400);
        toRemove.mint(address(aggregator), 400);

        vm.prank(manager);
        aggregator.removeVault(toRemove);
        aggregator.updateHoldingsState();

        assertEq(aggregator.totalAssets(), 1400);
        assertEq(aggregator.balanceOf(alice), 1000 * 10 ** (aggregator.decimals() - asset.decimals()));
        assertEq(toRemove.balanceOf(address(aggregator)), 0);
    }

    function testRemoveVaultRedeemSharesWhenItCantRedeemAllOfThem() public {
        CommonAggregator aggregator = _aggregatorWithThreeVaults();
        IERC4626[] memory initialVaults = aggregator.getVaults();
        ERC4626Mock toRemove = ERC4626Mock(address(initialVaults[1]));

        asset.mint(address(alice), 1000);

        vm.prank(alice);
        asset.approve(address(aggregator), 1000);
        vm.prank(alice);
        aggregator.deposit(1000, alice);

        vm.prank(manager);
        aggregator.pushFunds(1000, toRemove);

        toRemove.setWithdrawLimit(999);
        toRemove.setRedeemLimit(999);

        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxRedeem.selector, address(aggregator), 1000, 999)
        );
        aggregator.removeVault(toRemove);
    }

    function testCantRemoveVaultWhenPendingForceRemoval() public {
        CommonAggregator aggregator = _aggregatorWithThreeVaults();
        IERC4626[] memory initialVaults = aggregator.getVaults();
        ERC4626Mock toRemove = ERC4626Mock(address(initialVaults[1]));

        vm.prank(manager);
        aggregator.submitForceRemoveVault(toRemove);

        vm.expectRevert(abi.encodeWithSelector(ICommonAggregator.PendingVaultForceRemoval.selector, toRemove));
        vm.prank(manager);
        aggregator.removeVault(toRemove);
    }

    function testForceRemoveVaultNotPaused() public {
        CommonAggregator aggregator = _aggregatorWithThreeVaults();
        _testSimpleForceRemoveMiddleVault(aggregator);
    }

    function testForceRemoveVaultPaused() public {
        CommonAggregator aggregator = _aggregatorWithThreeVaults();
        vm.prank(owner);
        aggregator.pauseUserInteractions();

        _testSimpleForceRemoveMiddleVault(aggregator);
    }

    function _testSimpleForceRemoveMiddleVault(CommonAggregator aggregator) private {
        assertEq(aggregator.getVaults().length, 3, "Incorrect test usage");

        IERC4626[] memory initialVaults = aggregator.getVaults();
        ERC4626Mock toRemove = ERC4626Mock(address(initialVaults[1]));

        vm.prank(manager);
        vm.expectEmit(true, true, true, true, address(aggregator), 1);
        emit ICommonAggregator.VaultForceRemovalSubmitted(address(toRemove), vm.getBlockTimestamp() + 14 days);
        aggregator.submitForceRemoveVault(toRemove);

        assertEq(aggregator.paused(), true);

        vm.warp(STARTING_TIMESTAMP + 30 days);

        vm.prank(manager);
        vm.expectEmit(true, true, true, true, address(aggregator), 1);
        emit ICommonAggregator.VaultForceRemoved(address(toRemove));
        aggregator.forceRemoveVault(toRemove);

        assertEq(aggregator.getVaults().length, 2);
        assertEq(address(aggregator.getVaults()[0]), address(initialVaults[0]));
        assertEq(address(aggregator.getVaults()[1]), address(initialVaults[2]));
    }

    function testCantForceRemoveVaultTooEarly() public {
        CommonAggregator aggregator = _aggregatorWithThreeVaults();
        IERC4626[] memory initialVaults = aggregator.getVaults();
        ERC4626Mock toRemove = ERC4626Mock(address(initialVaults[1]));

        vm.expectRevert(
            abi.encodeWithSelector(
                CommonTimelocks.ActionNotRegistered.selector,
                keccak256(abi.encode(CommonAggregator.TimelockTypes.FORCE_REMOVE_VAULT, toRemove))
            )
        );
        vm.prank(manager);
        aggregator.forceRemoveVault(toRemove);

        vm.prank(manager);
        aggregator.submitForceRemoveVault(toRemove);

        // Limits are inclusive, so it's still too early
        vm.warp(STARTING_TIMESTAMP + 14 days);

        bytes32 actionHash = keccak256(abi.encode(CommonAggregator.TimelockTypes.FORCE_REMOVE_VAULT, toRemove));
        vm.expectRevert(
            abi.encodeWithSelector(CommonTimelocks.ActionTimelocked.selector, actionHash, STARTING_TIMESTAMP + 14 days)
        );
        vm.prank(manager);
        aggregator.forceRemoveVault(toRemove);
    }

    function submitForceRemoveSameVaultTwiceFails() public {
        CommonAggregator aggregator = _aggregatorWithThreeVaults();
        IERC4626[] memory initialVaults = aggregator.getVaults();
        ERC4626Mock toRemove = ERC4626Mock(address(initialVaults[1]));

        vm.prank(manager);
        aggregator.submitForceRemoveVault(toRemove);

        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(
                CommonTimelocks.ActionAlreadyRegistered.selector,
                keccak256(abi.encode(CommonAggregator.TimelockTypes.FORCE_REMOVE_VAULT, toRemove))
            )
        );
        aggregator.submitForceRemoveVault(toRemove);
    }

    function submitForceRemoveOfNonExistentVaultFails() public {
        CommonAggregator aggregator = _aggregatorWithThreeVaults();
        ERC4626Mock fakeVault = new ERC4626Mock(address(3));

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ICommonAggregator.VaultNotOnTheList.selector, fakeVault));
        aggregator.submitForceRemoveVault(fakeVault);
    }

    function testCancelForceRemoveVault() public {
        CommonAggregator aggregator = _aggregatorWithThreeVaults();
        IERC4626[] memory initialVaults = aggregator.getVaults();
        ERC4626Mock toRemove = ERC4626Mock(address(initialVaults[1]));

        // Cancelling too early fails
        vm.expectRevert(
            abi.encodeWithSelector(
                CommonTimelocks.ActionNotRegistered.selector,
                keccak256(abi.encode(CommonAggregator.TimelockTypes.FORCE_REMOVE_VAULT, toRemove))
            )
        );
        vm.prank(guardian);
        aggregator.cancelForceRemoveVault(toRemove);

        // Successfull submission and cancellation
        vm.prank(manager);
        aggregator.submitForceRemoveVault(toRemove);
        vm.warp(STARTING_TIMESTAMP + 8 days);
        vm.expectEmit(true, true, true, true, address(aggregator), 1);
        emit ICommonAggregator.VaultForceRemovalCancelled(address(toRemove));
        vm.prank(guardian);
        aggregator.cancelForceRemoveVault(toRemove);

        // Cancelling for the second time fails
        vm.expectRevert(
            abi.encodeWithSelector(
                CommonTimelocks.ActionNotRegistered.selector,
                keccak256(abi.encode(CommonAggregator.TimelockTypes.FORCE_REMOVE_VAULT, toRemove))
            )
        );
        vm.prank(guardian);
        aggregator.cancelForceRemoveVault(toRemove);

        // Force removal doesn't work after cancelling
        vm.warp(STARTING_TIMESTAMP + 30 days);
        bytes32 actionHash = keccak256(abi.encode(CommonAggregator.TimelockTypes.FORCE_REMOVE_VAULT, toRemove));
        vm.expectRevert(abi.encodeWithSelector(CommonTimelocks.ActionNotRegistered.selector, actionHash));
        vm.prank(manager);
        aggregator.forceRemoveVault(toRemove);
    }

    function testForceRemoveVaultRemovesAssetsWhenVaultIsBroken() public {
        CommonAggregator aggregator = _aggregatorWithThreeVaults();
        _firstDeposit(aggregator, 1000);
        _equalDistributionFromIdle(aggregator, true);
        assertEq(aggregator.totalAssets(), 1000);

        ERC4626Mock(address(aggregator.getVaults()[1])).setReverting(true);
        _testSimpleForceRemoveMiddleVault(aggregator);

        assertEq(aggregator.totalAssets(), 750);
    }

    function testForceRemoveVaultRedeemsSharesIfPossilbe() public {
        CommonAggregator aggregator = _aggregatorWithThreeVaults();
        _firstDeposit(aggregator, 1000);
        _equalDistributionFromIdle(aggregator, true);
        assertEq(aggregator.totalAssets(), 1000);

        ERC4626Mock(address(aggregator.getVaults()[1])).setRedeemLimit(200);
        _testSimpleForceRemoveMiddleVault(aggregator);

        assertEq(aggregator.totalAssets(), 950);
    }

    function testSubmitForceRemoveVaultDoesntRemoveAssetsYet() public {
        CommonAggregator aggregator = _aggregatorWithThreeVaults();
        _firstDeposit(aggregator, 1000);
        _equalDistributionFromIdle(aggregator, true);
        assertEq(aggregator.totalAssets(), 1000);

        IERC4626[] memory initialVaults = aggregator.getVaults();
        ERC4626Mock toRemove = ERC4626Mock(address(initialVaults[1]));

        toRemove.setReverting(true);

        vm.prank(manager);
        aggregator.submitForceRemoveVault(toRemove);

        assertEq(aggregator.totalAssets(), 1000);
    }

    function testUserCanEmergencyRedeemWhenPendingForceRemoval() public {
        CommonAggregator aggregator = _aggregatorWithThreeVaults();
        _firstDeposit(aggregator, 1000);
        _equalDistributionFromIdle(aggregator, true);

        uint256 aliceShares = aggregator.totalSupply();

        assertEq(aggregator.totalAssets(), 1000);

        IERC4626[] memory initialVaults = aggregator.getVaults();
        ERC4626Mock toRemove = ERC4626Mock(address(initialVaults[1]));

        toRemove.setReverting(true);

        vm.prank(manager);
        aggregator.submitForceRemoveVault(toRemove);

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
        CommonAggregator aggregator = _noVaultAggregator();
        IERC4626 vault = new ERC4626Mock(address(asset));

        vm.expectRevert(ICommonAggregator.CallerNotManagerNorOwner.selector);
        vm.prank(alice);
        aggregator.submitAddVault(vault);

        vm.expectRevert(ICommonAggregator.CallerNotManagerNorOwner.selector);
        vm.prank(guardian);
        aggregator.submitAddVault(vault);

        vm.prank(manager);
        aggregator.submitAddVault(vault);

        IERC4626 vault2 = new ERC4626Mock(address(asset));
        vm.prank(owner);
        aggregator.submitAddVault(vault2);
    }

    function testRolesCancelAddVault() public {
        CommonAggregator aggregator = _noVaultAggregator();
        IERC4626 vault = new ERC4626Mock(address(asset));

        vm.prank(manager);
        aggregator.submitAddVault(vault);

        vm.expectRevert(ICommonAggregator.CallerNotGuardianOrWithHigherRole.selector);
        vm.prank(alice);
        aggregator.cancelAddVault(vault);

        vm.prank(guardian);
        aggregator.cancelAddVault(vault);

        vm.prank(manager);
        aggregator.submitAddVault(vault);
        vm.prank(manager);
        aggregator.cancelAddVault(vault);

        vm.prank(manager);
        aggregator.submitAddVault(vault);
        vm.prank(owner);
        aggregator.cancelAddVault(vault);
    }

    function testRolesAddVault() public {
        CommonAggregator aggregator = _noVaultAggregator();
        IERC4626 vault = new ERC4626Mock(address(asset));
        IERC4626 vault2 = new ERC4626Mock(address(asset));

        vm.prank(manager);
        aggregator.submitAddVault(vault);
        vm.prank(manager);
        aggregator.submitAddVault(vault2);

        vm.warp(STARTING_TIMESTAMP + 8 days);

        vm.expectRevert(ICommonAggregator.CallerNotManagerNorOwner.selector);
        vm.prank(alice);
        aggregator.addVault(vault);

        vm.expectRevert(ICommonAggregator.CallerNotManagerNorOwner.selector);
        vm.prank(guardian);
        aggregator.addVault(vault);

        vm.prank(manager);
        aggregator.addVault(vault);

        vm.prank(owner);
        aggregator.addVault(vault2);
    }

    function testRolesRemoveVault() public {
        CommonAggregator aggregator = _aggregatorWithThreeVaults();

        IERC4626 vaultToRemove = aggregator.getVaults()[0];
        vm.expectRevert(ICommonAggregator.CallerNotManagerNorOwner.selector);
        vm.prank(alice);
        aggregator.removeVault(vaultToRemove);

        vm.expectRevert(ICommonAggregator.CallerNotManagerNorOwner.selector);
        vm.prank(guardian);
        aggregator.removeVault(vaultToRemove);

        vm.prank(manager);
        aggregator.removeVault(vaultToRemove);

        vaultToRemove = aggregator.getVaults()[0];
        vm.prank(owner);
        aggregator.removeVault(vaultToRemove);
    }

    function testRolesSubmitForceRemoveVault() public {
        CommonAggregator aggregator = _aggregatorWithThreeVaults();

        IERC4626 vault0 = aggregator.getVaults()[0];
        IERC4626 vault1 = aggregator.getVaults()[1];

        vm.expectRevert(ICommonAggregator.CallerNotManagerNorOwner.selector);
        vm.prank(alice);
        aggregator.submitForceRemoveVault(vault0);

        vm.expectRevert(ICommonAggregator.CallerNotManagerNorOwner.selector);
        vm.prank(guardian);
        aggregator.submitForceRemoveVault(vault0);

        vm.prank(manager);
        aggregator.submitForceRemoveVault(vault0);

        vm.prank(owner);
        aggregator.submitForceRemoveVault(vault1);
    }

    function testRolesCancelForceRemoveVault() public {
        CommonAggregator aggregator = _aggregatorWithThreeVaults();

        IERC4626 vaultToRemove = aggregator.getVaults()[0];
        vm.prank(manager);
        aggregator.submitForceRemoveVault(vaultToRemove);

        vm.expectRevert(ICommonAggregator.CallerNotGuardianOrWithHigherRole.selector);
        vm.prank(alice);
        aggregator.cancelForceRemoveVault(vaultToRemove);

        vm.prank(guardian);
        aggregator.cancelForceRemoveVault(vaultToRemove);

        vm.prank(manager);
        aggregator.submitForceRemoveVault(vaultToRemove);
        vm.prank(manager);
        aggregator.cancelForceRemoveVault(vaultToRemove);

        vm.prank(owner);
        aggregator.submitForceRemoveVault(vaultToRemove);
        vm.prank(owner);
        aggregator.cancelForceRemoveVault(vaultToRemove);
    }

    function testRolesForceRemoveVault() public {
        CommonAggregator aggregator = _aggregatorWithThreeVaults();

        IERC4626 vault0 = aggregator.getVaults()[0];
        IERC4626 vault1 = aggregator.getVaults()[1];
        vm.prank(manager);
        aggregator.submitForceRemoveVault(vault0);
        vm.prank(manager);
        aggregator.submitForceRemoveVault(vault1);

        vm.warp(STARTING_TIMESTAMP + 30 days);

        vm.expectRevert(ICommonAggregator.CallerNotManagerNorOwner.selector);
        vm.prank(alice);
        aggregator.forceRemoveVault(vault0);

        vm.expectRevert(ICommonAggregator.CallerNotManagerNorOwner.selector);
        vm.prank(guardian);
        aggregator.forceRemoveVault(vault0);

        vm.prank(manager);
        aggregator.forceRemoveVault(vault0);
        vm.prank(owner);
        aggregator.forceRemoveVault(vault1);

        assertEq(aggregator.getVaults().length, 1);
    }

    function _aggregatorWithThreeVaults() private returns (CommonAggregator) {
        IERC4626[] memory vaults = new IERC4626[](3);
        vaults[0] = new ERC4626Mock(address(asset));
        vaults[1] = new ERC4626Mock(address(asset));
        vaults[2] = new ERC4626Mock(address(asset));

        bytes memory initializeData = abi.encodeWithSelector(CommonAggregator.initialize.selector, owner, asset, vaults);
        CommonAggregator implementation = new CommonAggregator();
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initializeData);
        CommonAggregator aggregator = CommonAggregator(address(proxy));
        _grantRoles(aggregator);
        return aggregator;
    }

    function _noVaultAggregator() private returns (CommonAggregator) {
        bytes memory initializeData =
            abi.encodeWithSelector(CommonAggregator.initialize.selector, owner, asset, new ERC4626Mock[](0));
        CommonAggregator implementation = new CommonAggregator();
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initializeData);
        CommonAggregator aggregator = CommonAggregator(address(proxy));
        _grantRoles(aggregator);
        return aggregator;
    }

    function _grantRoles(CommonAggregator aggregator) private {
        vm.prank(owner);
        aggregator.grantRole(keccak256("MANAGER"), manager);

        vm.prank(owner);
        aggregator.grantRole(keccak256("GUARDIAN"), guardian);
    }

    function _firstDeposit(CommonAggregator aggregator, uint256 initialDeposit) private returns (uint256) {
        asset.mint(alice, initialDeposit);

        vm.prank(alice);
        asset.approve(address(aggregator), initialDeposit);
        vm.prank(alice);
        return aggregator.deposit(initialDeposit, alice);
    }

    function _equalDistributionFromIdle(CommonAggregator aggregator, bool includeIdleInDistribution) internal {
        uint256 totalAssets = aggregator.totalAssets();
        uint256 part = totalAssets / (aggregator.getVaults().length + (includeIdleInDistribution ? 1 : 0));
        for (uint256 i = 0; i < aggregator.getVaults().length; ++i) {
            IERC4626 vault = aggregator.getVaults()[i];
            vm.prank(owner);
            aggregator.pushFunds(part, vault);
        }
    }
}
