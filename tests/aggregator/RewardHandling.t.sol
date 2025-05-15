// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {CommonAggregator, ICommonAggregator} from "contracts/CommonAggregator.sol";
import {CommonManagement} from "contracts/CommonManagement.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
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
    address rebalancer = address(0x321);
    address guardian = address(0x135);
    address manager = address(0x531);
    address protocolFeeReceiver = address(1);

    ERC20Mock asset = new ERC20Mock();
    IERC4626[] vaults = new IERC4626[](2);

    ERC20Mock reward = new ERC20Mock();
    address trader = address(0x888);

    address alice = address(0x456);

    function setUp() public {
        vm.warp(STARTING_TIMESTAMP);
        vaults[0] = new ERC4626Mock(address(asset));
        vaults[1] = new ERC4626Mock(address(asset));

        (commonAggregator, commonManagement) = setUpAggregator(owner, asset, protocolFeeReceiver, vaults);
        vm.prank(owner);
        commonManagement.grantRole(CommonManagement.Roles.Rebalancer, rebalancer);
        vm.prank(owner);
        commonManagement.grantRole(CommonManagement.Roles.Guardian, guardian);
        vm.prank(owner);
        commonManagement.grantRole(CommonManagement.Roles.Manager, manager);
    }

    function testHappyPath() public {
        reward.mint(alice, 1000);
        vm.prank(alice);
        reward.transfer(address(commonAggregator), 1000);

        assertEq(reward.balanceOf(trader), 0);

        vm.prank(owner);
        commonManagement.submitSetRewardTrader(address(reward), trader);

        vm.warp(STARTING_TIMESTAMP + 8 days);

        vm.prank(manager);
        commonManagement.setRewardTrader(address(reward), trader);

        vm.prank(alice);
        commonManagement.transferRewardsForSale(address(reward));

        assertEq(reward.balanceOf(trader), 1000);
    }

    function testTimelock() public {
        vm.prank(owner);
        commonManagement.submitSetRewardTrader(address(reward), trader);

        vm.warp(STARTING_TIMESTAMP + 2 days);

        vm.expectRevert(
            abi.encodeWithSelector(
                CommonManagement.ActionTimelocked.selector,
                keccak256(abi.encode(CommonManagement.TimelockTypes.SET_TRADER, address(reward))),
                STARTING_TIMESTAMP + 3 days
            )
        );
        vm.prank(owner);
        commonManagement.setRewardTrader(address(reward), trader);

        vm.warp(STARTING_TIMESTAMP + 4 days);

        vm.expectRevert(
            abi.encodeWithSelector(
                CommonManagement.IncorrectActionData.selector,
                keccak256(abi.encode(CommonManagement.TimelockTypes.SET_TRADER, address(reward))),
                keccak256(abi.encode(owner))
            )
        );
        vm.prank(owner);
        commonManagement.setRewardTrader(address(reward), owner);
    }

    function testTransferWithoutTraderSet() public {
        reward.mint(alice, 1000);
        vm.prank(alice);
        reward.transfer(address(commonAggregator), 1000);

        vm.expectRevert(abi.encodeWithSelector(CommonManagement.NoTraderSetForToken.selector, address(reward)));
        vm.prank(owner);
        commonManagement.transferRewardsForSale(address(reward));
    }

    function testRewardTradingWithPendingAddVaults() public {
        IERC4626 newVaultA = new ERC4626Mock(address(asset));
        IERC4626 newVaultB = new ERC4626Mock(address(asset));

        vm.startPrank(owner);
        commonManagement.submitAddVault(newVaultA);

        vm.expectRevert(abi.encodeWithSelector(CommonManagement.InvalidRewardToken.selector, address(newVaultA)));
        commonManagement.submitSetRewardTrader(address(newVaultA), trader);

        // in other direction it works
        commonManagement.submitSetRewardTrader(address(newVaultB), trader);
        commonManagement.submitAddVault(newVaultB);

        vm.warp(STARTING_TIMESTAMP + 30 days);

        vm.expectRevert(abi.encodeWithSelector(CommonManagement.InvalidRewardToken.selector, address(newVaultB)));
        commonManagement.setRewardTrader(address(newVaultB), trader);

        commonManagement.cancelAddVault(newVaultB);

        // should succeed
        commonManagement.setRewardTrader(address(newVaultB), trader);
    }

    function testPermissions() public {
        vm.expectRevert(CommonManagement.CallerNotManagerNorOwner.selector);
        vm.prank(rebalancer);
        commonManagement.submitSetRewardTrader(address(reward), trader);

        vm.expectRevert(CommonManagement.CallerNotManagerNorOwner.selector);
        vm.prank(guardian);
        commonManagement.submitSetRewardTrader(address(reward), trader);

        vm.expectRevert(abi.encodeWithSelector(CommonManagement.CallerNotManagerNorOwner.selector));
        vm.prank(alice);
        commonManagement.submitSetRewardTrader(address(reward), trader);

        vm.prank(owner);
        commonManagement.submitSetRewardTrader(address(reward), trader);

        vm.expectRevert(CommonManagement.CallerNotGuardianOrWithHigherRole.selector);
        vm.prank(alice);
        commonManagement.cancelSetRewardTrader(address(reward), trader);

        vm.expectRevert(CommonManagement.CallerNotGuardianOrWithHigherRole.selector);
        vm.prank(rebalancer);
        commonManagement.cancelSetRewardTrader(address(reward), trader);

        vm.prank(guardian);
        commonManagement.cancelSetRewardTrader(address(reward), trader);

        vm.prank(owner);
        commonManagement.submitSetRewardTrader(address(reward), trader);
        vm.prank(manager);
        commonManagement.cancelSetRewardTrader(address(reward), trader);

        vm.prank(owner);
        commonManagement.submitSetRewardTrader(address(reward), trader);
        vm.prank(owner);
        commonManagement.cancelSetRewardTrader(address(reward), trader);

        vm.prank(manager);
        commonManagement.submitSetRewardTrader(address(reward), trader);

        vm.warp(STARTING_TIMESTAMP + 6 days);

        vm.expectRevert(CommonManagement.CallerNotManagerNorOwner.selector);
        vm.prank(alice);
        commonManagement.setRewardTrader(address(reward), trader);

        vm.expectRevert(CommonManagement.CallerNotManagerNorOwner.selector);
        vm.prank(guardian);
        commonManagement.setRewardTrader(address(reward), trader);

        // Manager can set trader
        vm.prank(manager);
        commonManagement.setRewardTrader(address(reward), trader);

        vm.prank(owner);
        commonManagement.submitSetRewardTrader(address(reward), trader);

        vm.warp(STARTING_TIMESTAMP + 12 days);

        // Owner can set trader
        vm.prank(owner);
        commonManagement.setRewardTrader(address(reward), trader);
    }

    function testWrongTokens() public {
        vm.expectRevert(
            abi.encodeWithSelector(ICommonAggregator.InvalidRewardToken.selector, address(commonAggregator))
        );
        vm.prank(owner);
        commonManagement.submitSetRewardTrader(address(commonAggregator), trader);

        vm.expectRevert(abi.encodeWithSelector(ICommonAggregator.InvalidRewardToken.selector, address(asset)));
        vm.prank(owner);
        commonManagement.submitSetRewardTrader(address(asset), trader);

        for (uint256 i = 0; i < vaults.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(ICommonAggregator.InvalidRewardToken.selector, address(vaults[i])));
            vm.prank(owner);
            commonManagement.submitSetRewardTrader(address(vaults[i]), trader);
        }
    }

    function testAddedVaultCannotBeTransferred() public {
        ERC4626Mock freshVault = new ERC4626Mock(address(asset));

        vm.prank(owner);
        commonManagement.submitSetRewardTrader(address(freshVault), trader);

        vm.warp(STARTING_TIMESTAMP + 6 days);

        vm.prank(owner);
        commonManagement.setRewardTrader(address(freshVault), trader);

        vm.prank(owner);
        commonManagement.submitAddVault(IERC4626(address(freshVault)));

        vm.expectRevert(abi.encodeWithSelector(ICommonAggregator.InvalidRewardToken.selector, address(freshVault)));
        commonManagement.transferRewardsForSale(address(freshVault));

        vm.warp(STARTING_TIMESTAMP + 20 days);

        vm.prank(owner);
        commonManagement.addVault(IERC4626(address(freshVault)));

        vm.expectRevert(abi.encodeWithSelector(ICommonAggregator.InvalidRewardToken.selector, address(freshVault)));
        commonManagement.transferRewardsForSale(address(freshVault));
    }
}
