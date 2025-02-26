// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {CommonAggregator} from "contracts/CommonAggregator.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC4626Mock} from "tests/mock/ERC4626Mock.sol";
import {ERC20Mock} from "tests/mock/ERC20Mock.sol";

contract CommonAggregatorTest is Test {
    uint256 constant STARTING_TIMESTAMP = 100;

    CommonAggregator commonAggregator;
    address owner = address(0x123);
    ERC20Mock asset = new ERC20Mock();
    ERC4626Mock[] vaults = new ERC4626Mock[](2);

    address alice = address(0x456);
    address bob = address(0x678);

    function setUp() public {
        vm.warp(STARTING_TIMESTAMP);
        CommonAggregator implementation = new CommonAggregator();
        vaults[0] = new ERC4626Mock(address(asset));
        vaults[1] = new ERC4626Mock(address(asset));

        bytes memory initializeData = abi.encodeWithSelector(CommonAggregator.initialize.selector, owner, asset, vaults);

        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initializeData);
        commonAggregator = CommonAggregator(address(proxy));
    }

    function testRoleGranting() public {
        assertTrue(commonAggregator.hasRole(commonAggregator.DEFAULT_ADMIN_ROLE(), owner));
        assertTrue(commonAggregator.hasRole(commonAggregator.OWNER(), owner));

        address otherAccount = address(0x456);
        assertFalse(commonAggregator.hasRole(commonAggregator.OWNER(), otherAccount));
        assertFalse(commonAggregator.hasRole(commonAggregator.MANAGER(), otherAccount));

        vm.prank(owner);
        commonAggregator.grantRole(keccak256("MANAGER"), otherAccount);
        assertTrue(commonAggregator.hasRole(commonAggregator.MANAGER(), otherAccount));
    }

    // Reporting

    function testFirstDeposit() public {
        asset.mint(alice, 1000);
        vm.prank(alice);
        asset.approve(address(commonAggregator), 1000);

        assertEq(commonAggregator.totalAssets(), 0);
        assertEq(commonAggregator.maxWithdraw(alice), 0);
        assertEq(commonAggregator.balanceOf(alice), 0);
        assertEq(commonAggregator.totalSupply(), 0);

        vm.prank(alice);
        commonAggregator.deposit(1000, alice);

        assertEq(commonAggregator.totalAssets(), 1000);
        assertEq(commonAggregator.maxWithdraw(alice), 1000);

        // Shares should have 4 more decimals than the asset
        assertEq(commonAggregator.balanceOf(alice), 1000 * 10000);
        assertEq(commonAggregator.totalSupply(), commonAggregator.balanceOf(alice));
    }

    function testMaxWithdrawUsesAccumulatedShares() public {
        asset.mint(alice, 1000);

        vm.prank(alice);
        asset.approve(address(commonAggregator), 1000);

        vm.prank(alice);
        commonAggregator.deposit(100, alice);
        assertEq(commonAggregator.maxWithdraw(alice), 100);

        vm.prank(alice);
        commonAggregator.deposit(900, alice);
        assertEq(commonAggregator.maxWithdraw(alice), 1000);

        vm.prank(alice);
        commonAggregator.withdraw(200, alice, alice);
        assertEq(commonAggregator.maxWithdraw(alice), 800);
    }

    function testCantWithdrawMoreThanLimits() public {
        asset.mint(alice, 1000);
        asset.mint(bob, 100);

        vm.prank(alice);
        asset.approve(address(commonAggregator), 1000);
        vm.prank(bob);
        asset.approve(address(commonAggregator), 100);

        vm.prank(alice);
        commonAggregator.deposit(1000, alice);
        vm.prank(bob);
        commonAggregator.deposit(100, bob);

        assertEq(commonAggregator.maxWithdraw(alice), 1000);
        assertEq(commonAggregator.maxWithdraw(bob), 100);

        vm.prank(alice);
        commonAggregator.withdraw(500, alice, alice);
        assertEq(commonAggregator.maxWithdraw(alice), 500);

        vm.prank(alice);
        vm.expectRevert();
        commonAggregator.withdraw(501, alice, alice);
    }

    function testVaultCanHaveZeroAssetsBack() public {
        asset.mint(alice, 1000);
        asset.mint(bob, 100);

        vm.prank(alice);
        asset.approve(address(commonAggregator), 1000);
        vm.prank(bob);
        asset.approve(address(commonAggregator), 100);

        vm.prank(alice);
        commonAggregator.deposit(1000, alice);

        vm.warp(STARTING_TIMESTAMP + 1);

        vm.prank(alice);
        commonAggregator.withdraw(1000, alice, alice);

        assertEq(commonAggregator.totalAssets(), 0);
        assertEq(commonAggregator.maxWithdraw(alice), 0);
        assertEq(commonAggregator.maxWithdraw(bob), 0);

        // Should not revert
        commonAggregator.updateHoldingsState();

        vm.warp(STARTING_TIMESTAMP + 2);

        vm.prank(bob);
        commonAggregator.deposit(100, bob);
        assertEq(commonAggregator.totalAssets(), 100);
        assertEq(commonAggregator.maxWithdraw(alice), 0);
        assertEq(commonAggregator.maxWithdraw(bob), 100);
    }

    function testSharesCanBeTransferred() public {
        asset.mint(alice, 1000);
        vm.prank(alice);
        asset.approve(address(commonAggregator), 1000);

        vm.prank(alice);
        commonAggregator.deposit(1000, alice);

        uint256 amount = commonAggregator.balanceOf(alice) * 4 / 10;
        vm.prank(alice);
        commonAggregator.transfer(bob, amount);

        vm.prank(bob);
        commonAggregator.withdraw(400, bob, bob);
        assertEq(asset.balanceOf(bob), 400);
    }

    function testAirdropIsAddedToRewards() public {
        asset.mint(alice, 1000);
        asset.mint(bob, 500);

        vm.prank(alice);
        asset.approve(address(commonAggregator), 1000);
        vm.prank(alice);
        commonAggregator.deposit(1000, alice);

        vm.prank(bob);
        asset.approve(address(commonAggregator), 500);
        vm.prank(bob);
        commonAggregator.deposit(500, bob);

        // Initial amounts
        assertEq(commonAggregator.maxWithdraw(alice), 1000);
        assertEq(commonAggregator.maxWithdraw(bob), 500);
        assertEq(commonAggregator.totalAssets(), 1500);

        asset.mint(address(commonAggregator), 150);

        // Rewards are buffered, so no airdrop is visible yet.
        assertEq(commonAggregator.maxWithdraw(alice), 1000);
        assertEq(commonAggregator.maxWithdraw(bob), 500);
        assertEq(commonAggregator.totalAssets(), 1500);

        commonAggregator.updateHoldingsState();

        // Only after updateHoldingsState() the airdrop is visible,
        // but rewards are not accrued yet.
        assertEq(commonAggregator.maxWithdraw(alice), 1000);
        assertEq(commonAggregator.maxWithdraw(bob), 500);
        assertEq(commonAggregator.totalAssets(), 1650);

        vm.warp(STARTING_TIMESTAMP + 2 days);

        // after 10% of buffering time
        assertEq(commonAggregator.maxWithdraw(alice), 1009);
        assertEq(commonAggregator.maxWithdraw(bob), 504);

        // Bob exits
        vm.prank(bob);
        commonAggregator.withdraw(504, bob, bob);

        vm.warp(STARTING_TIMESTAMP + 20 days);

        assertEq(commonAggregator.maxWithdraw(alice), 1145);
        assertEq(commonAggregator.maxWithdraw(bob), 0);
    }

    function testProtocolFee() public {
        vm.prank(owner);
        commonAggregator.setProtocolFee(100); // 1%

        vm.prank(owner);
        vm.expectRevert();
        commonAggregator.setProtocolFeeReceiver(address(0));

        vm.prank(owner);
        commonAggregator.setProtocolFeeReceiver(owner);

        uint256 aliceInitialBalance = 100_000;
        uint256 airdropped = 10_000;

        asset.mint(alice, aliceInitialBalance);
        vm.prank(alice);
        asset.approve(address(commonAggregator), aliceInitialBalance);
        vm.prank(alice);
        commonAggregator.deposit(aliceInitialBalance, alice);

        asset.mint(address(commonAggregator), airdropped);
        commonAggregator.updateHoldingsState();

        assertEq(asset.balanceOf(owner), 0);
        uint256 ownerInitialEarning = airdropped / 100; // Protocol earns 1 %
        assertEq(commonAggregator.maxWithdraw(owner), ownerInitialEarning);
        assertEq(commonAggregator.maxWithdraw(alice), aliceInitialBalance);

        vm.warp(STARTING_TIMESTAMP + 25 days);
        commonAggregator.updateHoldingsState();

        assertEq(asset.balanceOf(owner), 0);
        assertEq(commonAggregator.totalAssets(), aliceInitialBalance + airdropped);
        assertEq(
            commonAggregator.maxWithdraw(owner),
            ownerInitialEarning + ownerInitialEarning * airdropped / (aliceInitialBalance + airdropped)
        );
        assertEq(
            commonAggregator.maxWithdraw(alice),
            aliceInitialBalance + airdropped - commonAggregator.maxWithdraw(owner) - 1
        );
    }
}
