// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {CommonAggregator} from "contracts/CommonAggregator.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC4626Mock} from "tests/mock/ERC4626Mock.sol";
import {ERC20Mock} from "tests/mock/ERC20Mock.sol";
import {MAX_BPS} from "contracts/Math.sol";

contract CommonAggregatorTest is Test {
    uint256 constant STARTING_TIMESTAMP = 100_000_000;

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

        // Protocol fee increases, but until new gain is reported, nothing changes.
        vm.warp(STARTING_TIMESTAMP + 10 days);
        vm.prank(owner);
        commonAggregator.setProtocolFee(200);

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

    function testTotalSupply() public {
        IERC4626 vault0 = commonAggregator.getVaults()[0];
        IERC4626 vault1 = commonAggregator.getVaults()[1];
        uint256 decimalsOffset = commonAggregator.decimals() - asset.decimals();

        vm.prank(owner);
        commonAggregator.setLimit(vault0, MAX_BPS);
        vm.prank(owner);
        commonAggregator.setLimit(vault1, MAX_BPS);

        assertEq(commonAggregator.totalSupply(), 0, "1");

        asset.mint(alice, 1000);
        asset.mint(bob, 500);
        vm.prank(alice);
        asset.approve(address(commonAggregator), 1000);
        vm.prank(alice);
        commonAggregator.deposit(800, alice);
        vm.prank(bob);
        asset.approve(address(commonAggregator), 500);
        vm.prank(bob);
        commonAggregator.deposit(200, bob);

        assertEq(commonAggregator.totalSupply(), 1000 * (10 ** decimalsOffset), "2");

        vm.prank(owner);
        commonAggregator.pushFunds(600, vault0);
        vm.prank(owner);
        commonAggregator.pushFunds(200, vault1);

        assertEq(commonAggregator.totalSupply(), 1000 * (10 ** decimalsOffset), "3");

        asset.mint(address(vault0), 600);
        asset.mint(address(vault1), 400);
        commonAggregator.updateHoldingsState();

        assertEq(commonAggregator.totalSupply(), 1997 * (10 ** decimalsOffset), "4");

        vm.warp(STARTING_TIMESTAMP + 2 days);

        _checkIfUpdateHoldingsStateDoesntAffectAnything();

        vm.prank(bob);
        commonAggregator.deposit(200, bob);

        vm.warp(STARTING_TIMESTAMP + 7 days);

        _checkIfUpdateHoldingsStateDoesntAffectAnything();

        vm.prank(bob);
        commonAggregator.deposit(100, bob);
        vm.prank(alice);
        commonAggregator.deposit(200, alice);

        vm.warp(STARTING_TIMESTAMP + 13 days);

        _checkIfUpdateHoldingsStateDoesntAffectAnything();

        vm.warp(STARTING_TIMESTAMP + 20 days);
        assertEq(commonAggregator.balanceOf(address(commonAggregator)), 0);
    }

    function _checkIfUpdateHoldingsStateDoesntAffectAnything() private {
        uint256 totalSupply = commonAggregator.totalSupply();
        uint256 aggregatorShares = commonAggregator.balanceOf(address(commonAggregator));
        uint256 aliceShares = commonAggregator.balanceOf(alice);
        uint256 maxWithdrawAlice = commonAggregator.maxWithdraw(alice);
        uint256 bobShares = commonAggregator.balanceOf(bob);
        uint256 maxWithdrawBob = commonAggregator.maxWithdraw(bob);

        commonAggregator.updateHoldingsState();

        assertEq(commonAggregator.totalSupply(), totalSupply, "5");
        assertEq(commonAggregator.balanceOf(address(commonAggregator)), aggregatorShares, "6");
        assertEq(commonAggregator.balanceOf(alice), aliceShares, "7");
        assertEq(commonAggregator.maxWithdraw(alice), maxWithdrawAlice, "8");
        assertEq(commonAggregator.balanceOf(bob), bobShares, "9");
        assertEq(commonAggregator.maxWithdraw(bob), maxWithdrawBob, "10");
        assertEq(aliceShares + bobShares + aggregatorShares, totalSupply, "11");
    }
}
