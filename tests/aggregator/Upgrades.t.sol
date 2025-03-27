// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {CommonAggregator, ICommonAggregator} from "contracts/CommonAggregator.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC4626Mock} from "tests/mock/ERC4626Mock.sol";
import {ERC20Mock} from "tests/mock/ERC20Mock.sol";
import {CommonTimelocks} from "contracts/CommonTimelocks.sol";

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
    function _pause() internal override {
        revert ContractIsNoLongerPauseable();
    }

    function newMethod() public pure returns (uint256) {
        return 42;
    }
}

contract CommonAggregatorTest is Test {
    uint256 constant STARTING_TIMESTAMP = 100_000_000;

    ERC1967Proxy proxy;
    CommonAggregator commonAggregator;
    ERC20Mock asset = new ERC20Mock();
    ERC4626Mock[] vaults = new ERC4626Mock[](2);

    address owner = address(0x123);
    address manager = address(0x231);
    address rebalancer = address(0x312);
    address guardian = address(0x543);
    address alice = address(0x456);

    function setUp() public {
        vm.warp(STARTING_TIMESTAMP);
        CommonAggregator implementation = new CommonAggregator();
        vaults[0] = new ERC4626Mock(address(asset));
        vaults[1] = new ERC4626Mock(address(asset));

        bytes memory initializeData = abi.encodeWithSelector(CommonAggregator.initialize.selector, owner, asset, vaults);

        proxy = new ERC1967Proxy(address(implementation), initializeData);
        commonAggregator = CommonAggregator(address(proxy));

        vm.prank(owner);
        commonAggregator.grantRole(keccak256("MANAGER"), manager);
        vm.prank(owner);
        commonAggregator.grantRole(keccak256("REBALANCER"), rebalancer);
        vm.prank(owner);
        commonAggregator.grantRole(keccak256("GUARDIAN"), guardian);
    }

    function testUpgrade() public {
        asset.mint(owner, 1000);
        vm.prank(owner);
        asset.approve(address(commonAggregator), 1000);
        vm.prank(owner);
        commonAggregator.deposit(1000, owner);

        address newImplementation = address(new CommonAggregatorUpgraded());

        vm.prank(owner);
        commonAggregator.submitUpgrade(newImplementation);

        vm.warp(STARTING_TIMESTAMP + 30 days);

        vm.prank(owner);
        commonAggregator.upgradeToAndCall(newImplementation, "");

        CommonAggregatorUpgraded upgraded = CommonAggregatorUpgraded(address(proxy));

        assertEq(upgraded.maxWithdraw(owner), 1000);
        assertEq(upgraded.newMethod(), 42);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ContractIsNoLongerPauseable.selector));
        upgraded.pauseUserInteractions();
    }

    function testRolesUpgrading() public {
        address newImplementation = address(new CommonAggregatorUpgraded());

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(alice), keccak256("OWNER")
            )
        );
        commonAggregator.submitUpgrade(newImplementation);

        vm.prank(rebalancer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(rebalancer), keccak256("OWNER")
            )
        );
        commonAggregator.submitUpgrade(newImplementation);

        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(guardian), keccak256("OWNER")
            )
        );
        commonAggregator.submitUpgrade(newImplementation);

        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(manager), keccak256("OWNER")
            )
        );
        commonAggregator.submitUpgrade(newImplementation);

        vm.prank(owner);
        commonAggregator.submitUpgrade(newImplementation);

        vm.warp(STARTING_TIMESTAMP + 30 days);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(alice), keccak256("OWNER")
            )
        );
        commonAggregator.upgradeToAndCall(newImplementation, "");

        vm.prank(rebalancer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(rebalancer), keccak256("OWNER")
            )
        );
        commonAggregator.upgradeToAndCall(newImplementation, "");

        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(guardian), keccak256("OWNER")
            )
        );
        commonAggregator.upgradeToAndCall(newImplementation, "");

        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(manager), keccak256("OWNER")
            )
        );
        commonAggregator.upgradeToAndCall(newImplementation, "");
    }

    function testRolesCancelling() public {
        address[] memory impl = new address[](3);
        for (uint256 i = 0; i < 3; i++) {
            impl[i] = address(new CommonAggregatorUpgraded());
            vm.prank(owner);
            commonAggregator.submitUpgrade(impl[i]);
        }

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ICommonAggregator.CallerNotGuardianOrWithHigherRole.selector));
        commonAggregator.cancelUpgrade(impl[0]);

        vm.prank(rebalancer);
        vm.expectRevert(abi.encodeWithSelector(ICommonAggregator.CallerNotGuardianOrWithHigherRole.selector));
        commonAggregator.cancelUpgrade(impl[0]);

        vm.prank(guardian);
        commonAggregator.cancelUpgrade(impl[0]);

        vm.prank(manager);
        commonAggregator.cancelUpgrade(impl[1]);

        vm.prank(owner);
        commonAggregator.cancelUpgrade(impl[2]);

        vm.warp(STARTING_TIMESTAMP + 30 days);

        for (uint256 i = 0; i < 3; i++) {
            vm.prank(owner);
            vm.expectRevert(
                abi.encodeWithSelector(
                    CommonTimelocks.ActionNotRegistered.selector,
                    keccak256(abi.encode(CommonAggregator.TimelockTypes.CONTRACT_UPGRADE, impl[i]))
                )
            );
            commonAggregator.upgradeToAndCall(impl[i], "");
        }
    }
}
