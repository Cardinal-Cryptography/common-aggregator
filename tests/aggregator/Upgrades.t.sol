// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {CommonAggregator, ICommonAggregator} from "contracts/CommonAggregator.sol";
import {CommonManagement, ICommonManagement} from "contracts/CommonManagement.sol";
import {ERC1967Proxy, ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC4626Mock} from "tests/mock/ERC4626Mock.sol";
import {ERC20Mock} from "tests/mock/ERC20Mock.sol";
import {CommonTimelocks} from "contracts/CommonTimelocks.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {
    AccessControlUpgradeable,
    IAccessControl
} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {
    IERC20,
    IERC4626,
    IERC20Metadata,
    SafeERC20,
    ERC20Upgradeable,
    ERC4626Upgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";

error ContractIsNoLongerPauseable();

contract CommonAggregatorUpgraded is CommonAggregator {
    function _pause() internal pure override {
        revert ContractIsNoLongerPauseable();
    }

    function newMethod() public pure returns (uint256) {
        return 42;
    }
}

contract ERC4626MockUUPS is ERC4626Upgradeable {}

contract CommonAggregatorTest is Test {
    uint256 constant STARTING_TIMESTAMP = 100_000_000;

    CommonAggregator commonAggregator;
    CommonManagement commonManagement;
    ERC20Mock asset = new ERC20Mock();
    IERC4626[] vaults = new IERC4626[](2);

    address owner = address(0x123);
    address manager = address(0x231);
    address rebalancer = address(0x312);
    address guardian = address(0x543);
    address alice = address(0x456);

    function setUp() public {
        vm.warp(STARTING_TIMESTAMP);
        CommonAggregator aggregatorImplementation = new CommonAggregator();
        CommonManagement managementImplementation = new CommonManagement();
        vaults[0] = new ERC4626Mock(address(asset));
        vaults[1] = new ERC4626Mock(address(asset));

        ERC1967Proxy aggregatorProxy = new ERC1967Proxy(address(aggregatorImplementation), "");
        ERC1967Proxy managementProxy = new ERC1967Proxy(address(managementImplementation), "");
        commonAggregator = CommonAggregator(address(aggregatorProxy));
        commonManagement = CommonManagement(address(managementProxy));
        commonAggregator.initialize(commonManagement, asset, vaults);
        commonManagement.initialize(owner, commonAggregator);

        vm.prank(owner);
        commonManagement.grantRole(keccak256("MANAGER"), manager);
        vm.prank(owner);
        commonManagement.grantRole(keccak256("REBALANCER"), rebalancer);
        vm.prank(owner);
        commonManagement.grantRole(keccak256("GUARDIAN"), guardian);
    }

    function testUpgrade() public {
        asset.mint(owner, 1000);
        vm.prank(owner);
        asset.approve(address(commonAggregator), 1000);
        vm.prank(owner);
        commonAggregator.deposit(1000, owner);

        address newImplementation = address(new CommonAggregatorUpgraded());

        vm.prank(owner);
        commonManagement.submitUpgradeAggregator(newImplementation);

        vm.warp(STARTING_TIMESTAMP + 30 days);

        vm.prank(owner);
        commonManagement.upgradeAggregator(newImplementation, "");

        CommonAggregatorUpgraded upgraded = CommonAggregatorUpgraded(address(commonAggregator));

        assertEq(upgraded.maxWithdraw(owner), 1000);
        assertEq(upgraded.newMethod(), 42);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ContractIsNoLongerPauseable.selector));
        commonManagement.pauseUserInteractions();
    }

    function testUpgradeWithCustomInitializer() public {
        address newImplementation = address(new CommonAggregatorUpgraded());

        vm.prank(owner);
        commonManagement.pauseUserInteractions();
        vm.prank(owner);
        commonManagement.submitUpgradeAggregator(newImplementation);

        vm.warp(STARTING_TIMESTAMP + 30 days);

        assertEq(commonAggregator.paused(), true);

        // The selector stays the same
        bytes memory unpauseData = abi.encodeWithSelector(CommonAggregator.unpauseUserInteractions.selector);

        vm.prank(owner);
        commonManagement.upgradeAggregator(newImplementation, unpauseData);

        assertEq(commonAggregator.paused(), false);
        assertEq(CommonAggregatorUpgraded(address(commonAggregator)).newMethod(), 42);
    }

    function testInvalidUpgrades() public {
        address nonContract = alice;
        address nonUUPSImpl = address(new ERC4626MockUUPS());

        vm.prank(owner);
        commonManagement.submitUpgradeAggregator(nonContract);

        vm.prank(owner);
        commonManagement.submitUpgradeAggregator(nonUUPSImpl);

        vm.warp(STARTING_TIMESTAMP + 30 days);

        vm.prank(owner);
        vm.expectRevert();
        commonManagement.upgradeAggregator(nonContract, "");

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ERC1967Utils.ERC1967InvalidImplementation.selector, nonUUPSImpl));
        commonManagement.upgradeAggregator(nonUUPSImpl, "");
    }

    function testTimelock() public {
        address newImplementation = address(new CommonAggregatorUpgraded());
        vm.prank(owner);
        commonManagement.submitUpgradeAggregator(newImplementation);

        vm.warp(STARTING_TIMESTAMP + 13 days);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                CommonTimelocks.ActionTimelocked.selector,
                keccak256(abi.encode(CommonManagement.TimelockTypes.AGGREGATOR_UPGRADE, newImplementation)),
                STARTING_TIMESTAMP + 14 days
            )
        );
        commonManagement.upgradeAggregator(newImplementation, "");
    }

    function testRolesUpgrading() public {
        address newImplementation = address(new CommonAggregatorUpgraded());

        vm.prank(alice);
        expectAutorizationRevert(alice, keccak256("OWNER"));
        commonManagement.submitUpgradeAggregator(newImplementation);

        vm.prank(rebalancer);
        expectAutorizationRevert(rebalancer, keccak256("OWNER"));
        commonManagement.submitUpgradeAggregator(newImplementation);

        vm.prank(guardian);
        expectAutorizationRevert(guardian, keccak256("OWNER"));
        commonManagement.submitUpgradeAggregator(newImplementation);

        vm.prank(manager);
        expectAutorizationRevert(manager, keccak256("OWNER"));
        commonManagement.submitUpgradeAggregator(newImplementation);

        vm.prank(owner);
        commonManagement.submitUpgradeAggregator(newImplementation);

        vm.warp(STARTING_TIMESTAMP + 30 days);

        vm.prank(alice);
        expectAutorizationRevert(alice, keccak256("OWNER"));
        commonManagement.upgradeAggregator(newImplementation, "");

        vm.prank(rebalancer);
        expectAutorizationRevert(rebalancer, keccak256("OWNER"));
        commonManagement.upgradeAggregator(newImplementation, "");

        vm.prank(guardian);
        expectAutorizationRevert(guardian, keccak256("OWNER"));
        commonManagement.upgradeAggregator(newImplementation, "");

        vm.prank(manager);
        expectAutorizationRevert(manager, keccak256("OWNER"));
        commonManagement.upgradeAggregator(newImplementation, "");

        vm.prank(owner);
        commonManagement.upgradeAggregator(newImplementation, "");
    }

    function testRolesCancelling() public {
        address[] memory impl = new address[](3);
        for (uint256 i = 0; i < 3; i++) {
            impl[i] = address(new CommonAggregatorUpgraded());
            vm.prank(owner);
            commonManagement.submitUpgradeAggregator(impl[i]);
        }

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ICommonManagement.CallerNotGuardianOrWithHigherRole.selector));
        commonManagement.cancelUpgradeAggregator(impl[0]);

        vm.prank(rebalancer);
        vm.expectRevert(abi.encodeWithSelector(ICommonManagement.CallerNotGuardianOrWithHigherRole.selector));
        commonManagement.cancelUpgradeAggregator(impl[0]);

        vm.prank(guardian);
        commonManagement.cancelUpgradeAggregator(impl[0]);

        vm.prank(manager);
        commonManagement.cancelUpgradeAggregator(impl[1]);

        vm.prank(owner);
        commonManagement.cancelUpgradeAggregator(impl[2]);

        vm.warp(STARTING_TIMESTAMP + 30 days);

        for (uint256 i = 0; i < 3; i++) {
            vm.prank(owner);
            vm.expectRevert(
                abi.encodeWithSelector(
                    CommonTimelocks.ActionNotRegistered.selector,
                    keccak256(abi.encode(CommonManagement.TimelockTypes.AGGREGATOR_UPGRADE, impl[i]))
                )
            );
            commonManagement.upgradeAggregator(impl[i], "");
        }
    }

    function expectAutorizationRevert(address caller, bytes32 role) private {
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, role));
    }
}
