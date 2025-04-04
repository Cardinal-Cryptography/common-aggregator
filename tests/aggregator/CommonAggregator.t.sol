// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {CommonAggregator} from "contracts/CommonAggregator.sol";
import {CommonManagement} from "contracts/CommonManagement.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC4626Mock} from "tests/mock/ERC4626Mock.sol";
import {ERC20Mock} from "tests/mock/ERC20Mock.sol";

contract CommonAggregatorTest is Test {
    uint256 constant STARTING_TIMESTAMP = 100_000_000;

    CommonAggregator commonAggregator;
    CommonManagement commonManagement;
    address owner = address(0x123);
    ERC20Mock asset = new ERC20Mock();
    IERC4626[] vaults = new IERC4626[](2);

    address alice = address(0x456);
    address bob = address(0x678);

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
    }

    function testRoleGranting() public {
        assertTrue(commonManagement.hasRole(commonManagement.DEFAULT_ADMIN_ROLE(), owner));
        assertTrue(commonManagement.hasRole(commonManagement.OWNER(), owner));

        address otherAccount = address(0x456);
        assertFalse(commonManagement.hasRole(commonManagement.OWNER(), otherAccount));
        assertFalse(commonManagement.hasRole(commonManagement.MANAGER(), otherAccount));

        vm.prank(owner);
        commonManagement.grantRole(keccak256("MANAGER"), otherAccount);
        assertTrue(commonManagement.hasRole(commonManagement.MANAGER(), otherAccount));
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

        uint256 decimalOffset = commonAggregator.decimals() - asset.decimals();
        assertEq(commonAggregator.balanceOf(alice), 1000 * (10 ** decimalOffset));
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
        commonAggregator.updateHoldingsState();
        assertEq(commonAggregator.maxWithdraw(alice), 1009);
        assertEq(commonAggregator.maxWithdraw(bob), 504);

        // Bob exits
        vm.prank(bob);
        commonAggregator.withdraw(504, bob, bob);

        vm.warp(STARTING_TIMESTAMP + 20 days);

        commonAggregator.updateHoldingsState();
        assertEq(commonAggregator.maxWithdraw(alice), 1145);
        assertEq(commonAggregator.maxWithdraw(bob), 0);
    }

    function testProtocolFee() public {
        vm.prank(owner);
        commonManagement.setProtocolFee(100); // 1%

        vm.prank(owner);
        vm.expectRevert();
        commonManagement.setProtocolFeeReceiver(address(0));

        vm.prank(owner);
        commonManagement.setProtocolFeeReceiver(owner);

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

        // Protocol fee increases, but until new gain is reported, nothing changes.
        vm.warp(STARTING_TIMESTAMP + 10 days);
        vm.prank(owner);
        commonManagement.setProtocolFee(200);
        commonAggregator.updateHoldingsState();

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

        // New airdrop, fee increases
        uint256 ownerWithdrawalBefore = commonAggregator.maxWithdraw(owner);
        asset.mint(address(commonAggregator), airdropped);
        commonAggregator.updateHoldingsState();
        assertEq(commonAggregator.maxWithdraw(owner) - ownerWithdrawalBefore, airdropped / 50);
    }

    function testSmallLossNoProtocolFee() public {
        asset.mint(alice, 10000);
        asset.mint(bob, 5000);

        vm.prank(alice);
        asset.approve(address(commonAggregator), 10000);
        vm.prank(alice);
        commonAggregator.deposit(10000, alice);

        vm.prank(bob);
        asset.approve(address(commonAggregator), 5000);
        vm.prank(bob);
        commonAggregator.deposit(5000, bob);

        // Gain 20%
        asset.mint(address(commonAggregator), 3000);
        commonAggregator.updateHoldingsState();

        // But then lose 10%. Should be taken from the buffer only
        asset.burn(address(commonAggregator), 1800);
        commonAggregator.updateHoldingsState();

        assertEq(commonAggregator.totalAssets(), 16200);
        assertEq(commonAggregator.maxWithdraw(alice), 10000);
        assertEq(commonAggregator.maxWithdraw(bob), 5000);

        // Shares left are released linearly
        vm.warp(STARTING_TIMESTAMP + 10 days);
        commonAggregator.updateHoldingsState();

        assertEq(commonAggregator.maxWithdraw(alice), 10384);
        assertEq(commonAggregator.maxWithdraw(bob), 5192);

        vm.warp(STARTING_TIMESTAMP + 20 days);
        commonAggregator.updateHoldingsState();
        assertEq(commonAggregator.maxWithdraw(alice), 10799);
        assertEq(commonAggregator.maxWithdraw(bob), 5399);
    }

    function testLargeLossNoProtocolFee() public {
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

        // Gain 20%
        asset.mint(address(commonAggregator), 300);
        commonAggregator.updateHoldingsState();

        // But then lose 75%
        asset.burn(address(commonAggregator), 1800 * 3 / 4);
        commonAggregator.updateHoldingsState();

        assertEq(commonAggregator.totalAssets(), 450);
        assertEq(commonAggregator.maxWithdraw(alice), 300);
        assertEq(commonAggregator.maxWithdraw(bob), 150);
    }
}
