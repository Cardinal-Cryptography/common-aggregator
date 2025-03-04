// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ICommonAggregator} from "contracts/interfaces/ICommonAggregator.sol";
import {CommonAggregator} from "contracts/CommonAggregator.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC4626Mock} from "tests/mock/ERC4626Mock.sol";
import {ERC20Mock} from "tests/mock/ERC20Mock.sol";
import {CommonTimelocks} from "contracts/CommonTimelocks.sol";

contract CommonAggregatorTest is Test {
    uint256 constant STARTING_TIMESTAMP = 100_000_000;

    CommonAggregator commonAggregator;
    address owner = address(0x123);
    address rebalancer = address(0x321);
    address guardian = address(0x135);
    address manager = address(0x531);

    ERC20Mock asset = new ERC20Mock();
    ERC4626Mock[] vaults = new ERC4626Mock[](2);

    ERC20Mock reward = new ERC20Mock();
    address trader = address(0x888);

    address alice = address(0x456);

    function setUp() public {
        vm.warp(STARTING_TIMESTAMP);
        CommonAggregator implementation = new CommonAggregator();
        vaults[0] = new ERC4626Mock(address(asset));
        vaults[1] = new ERC4626Mock(address(asset));

        bytes memory initializeData = abi.encodeWithSelector(CommonAggregator.initialize.selector, owner, asset, vaults);

        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initializeData);
        commonAggregator = CommonAggregator(address(proxy));
        vm.prank(owner);
        commonAggregator.grantRole(keccak256("REBALANCER"), rebalancer);
        vm.prank(owner);
        commonAggregator.grantRole(keccak256("GUARDIAN"), guardian);
        vm.prank(owner);
        commonAggregator.grantRole(keccak256("MANAGER"), manager);
    }

    function testHappyPath() public {
        reward.mint(alice, 1000);
        vm.prank(alice);
        reward.transfer(address(commonAggregator), 1000);

        assertEq(reward.balanceOf(trader), 0);

        vm.prank(owner);
        commonAggregator.submitSetRewardTrader(address(reward), trader);

        vm.warp(STARTING_TIMESTAMP + 8 days);

        vm.prank(alice);
        commonAggregator.setRewardTrader(address(reward), trader);

        vm.prank(alice);
        commonAggregator.transferRewardsForSale(address(reward));

        assertEq(reward.balanceOf(trader), 1000);
    }

    function testTimelock() public {
        vm.prank(owner);
        commonAggregator.submitSetRewardTrader(address(reward), trader);

        vm.warp(STARTING_TIMESTAMP + 2 days);

        vm.expectRevert(
            abi.encodeWithSelector(
                CommonTimelocks.ActionTimelocked.selector,
                keccak256(abi.encode(CommonAggregator.TimelockTypes.SET_TRADER, address(reward), trader)),
                STARTING_TIMESTAMP + 5 days
            )
        );
        vm.prank(owner);
        commonAggregator.setRewardTrader(address(reward), trader);

        vm.warp(STARTING_TIMESTAMP + 6 days);

        vm.expectRevert(
            abi.encodeWithSelector(
                CommonTimelocks.ActionNotRegistered.selector,
                keccak256(abi.encode(CommonAggregator.TimelockTypes.SET_TRADER, address(reward), owner))
            )
        );
        vm.prank(owner);
        commonAggregator.setRewardTrader(address(reward), owner);
    }

    function testTransferWithoutTraderSet() public {
        reward.mint(alice, 1000);
        vm.prank(alice);
        reward.transfer(address(commonAggregator), 1000);

        vm.expectRevert(abi.encodeWithSelector(ICommonAggregator.NoTraderSetForToken.selector, address(reward)));
        vm.prank(alice);
        commonAggregator.transferRewardsForSale(address(reward));
    }

    function testPermissions() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, manager, keccak256("OWNER")
            )
        );
        vm.prank(manager);
        commonAggregator.submitSetRewardTrader(address(reward), trader);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, rebalancer, keccak256("OWNER")
            )
        );
        vm.prank(rebalancer);
        commonAggregator.submitSetRewardTrader(address(reward), trader);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, guardian, keccak256("OWNER")
            )
        );
        vm.prank(guardian);
        commonAggregator.submitSetRewardTrader(address(reward), trader);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, keccak256("OWNER"))
        );
        vm.prank(alice);
        commonAggregator.submitSetRewardTrader(address(reward), trader);

        vm.prank(owner);
        commonAggregator.submitSetRewardTrader(address(reward), trader);

        vm.expectRevert(abi.encodeWithSelector(ICommonAggregator.CallerNotGuardianOrWithHigherRole.selector));
        vm.prank(alice);
        commonAggregator.cancelSetRewardTrader(address(reward), trader);

        vm.expectRevert(abi.encodeWithSelector(ICommonAggregator.CallerNotGuardianOrWithHigherRole.selector));
        vm.prank(rebalancer);
        commonAggregator.cancelSetRewardTrader(address(reward), trader);

        vm.prank(guardian);
        commonAggregator.cancelSetRewardTrader(address(reward), trader);

        vm.prank(owner);
        commonAggregator.submitSetRewardTrader(address(reward), trader);
        vm.prank(manager);
        commonAggregator.cancelSetRewardTrader(address(reward), trader);

        vm.prank(owner);
        commonAggregator.submitSetRewardTrader(address(reward), trader);
        vm.prank(owner);
        commonAggregator.cancelSetRewardTrader(address(reward), trader);
    }

    function testWrongTokens() public {
        vm.expectRevert(
            abi.encodeWithSelector(ICommonAggregator.InvalidRewardToken.selector, address(commonAggregator))
        );
        vm.prank(owner);
        commonAggregator.submitSetRewardTrader(address(commonAggregator), trader);

        vm.expectRevert(abi.encodeWithSelector(ICommonAggregator.InvalidRewardToken.selector, address(asset)));
        vm.prank(owner);
        commonAggregator.submitSetRewardTrader(address(asset), trader);

        for (uint256 i = 0; i < vaults.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(ICommonAggregator.InvalidRewardToken.selector, address(vaults[i])));
            vm.prank(owner);
            commonAggregator.submitSetRewardTrader(address(vaults[i]), trader);
        }
    }
}
