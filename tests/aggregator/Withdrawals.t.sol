// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {
    CommonAggregator,
    ICommonAggregator,
    IERC4626,
    IERC20,
    ERC4626BufferedUpgradeable
} from "contracts/CommonAggregator.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC4626Mock} from "tests/mock/ERC4626Mock.sol";
import {ERC20Mock} from "tests/mock/ERC20Mock.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MAX_BPS} from "contracts/Math.sol";

contract CommonAggregatorTest is Test {
    using Math for uint256;

    uint256 constant STARTING_TIMESTAMP = 100_000_000;
    uint256 constant VAULT_COUNT = 3;
    uint256 constant INITIAL_DEPOSIT = 10000;

    CommonAggregator commonAggregator;
    address owner = address(0x123);
    address protocolFeeReceiver = address(1);

    ERC20Mock asset = new ERC20Mock();
    ERC4626Mock[] vaults = new ERC4626Mock[](VAULT_COUNT);

    address alice = address(0x456);
    address bob = address(0x654);

    function setUp() public {
        vm.warp(STARTING_TIMESTAMP);
        CommonAggregator implementation = new CommonAggregator();

        for (uint256 i = 0; i < VAULT_COUNT; ++i) {
            vaults[i] = new ERC4626Mock(address(asset));
        }

        bytes memory initializeData =
            abi.encodeWithSelector(CommonAggregator.initialize.selector, owner, asset, protocolFeeReceiver, vaults);

        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initializeData);
        commonAggregator = CommonAggregator(address(proxy));
    }

    function testMaxWithdraw() public {
        _prepareDistribution([uint256(30), 30, 30], 30);
        vaults[0].setWithdrawLimit(10);

        assertEq(commonAggregator.maxWithdraw(alice), 100);
    }

    function testMaxWithdrawDoesNotOverestimate() public {
        _prepareDistribution([uint256(30), 30, 30], 30);
        vaults[0].setWithdrawLimit(10);

        assertEq(commonAggregator.maxWithdraw(alice), 100);

        // simulate loss on vault
        asset.burn(address(vaults[1]), 10);

        assertEq(commonAggregator.maxWithdraw(alice), 90);
    }

    function testMaxWithdrawWithRevertingVault() public {
        _prepareDistribution([uint256(30), 30, 30], 30);
        vaults[2].setReverting(true);

        assertEq(commonAggregator.maxWithdraw(alice), 90);
    }

    function testMaxRedeem() public {
        _prepareDistribution([uint256(30), 30, 30], 30);
        vaults[0].setWithdrawLimit(10);

        assertEq(commonAggregator.maxRedeem(alice), commonAggregator.convertToShares(100));
    }

    function testMaxRedeemWithRevertingVault() public {
        _prepareDistribution([uint256(30), 30, 30], 30);
        vaults[2].setReverting(true);

        assertEq(commonAggregator.maxRedeem(alice), commonAggregator.convertToShares(90));
    }

    function testMaxWithdrawAndRedeemDontRevert() public {
        _prepareDistribution([uint256(1 << 230), uint256(1 << 230), 0], 0);

        uint256 aliceInitialShares = commonAggregator.balanceOf(alice);

        asset.mint(address(commonAggregator.getVaults()[0]), 1 << 254);
        asset.mint(address(commonAggregator.getVaults()[2]), 1 << 255);

        // Not yet updated
        assertEq(commonAggregator.totalAssets(), 2 * (1 << 230));
        assertEq(commonAggregator.maxWithdraw(alice), 2 * (1 << 230));
        assertEq(commonAggregator.maxRedeem(alice), aliceInitialShares);
    }

    function testSimpleWithdraw() public {
        _prepareDistribution([uint256(10), 20, 30], 5);

        _bobWithdraw(13);

        assertEq(asset.balanceOf(bob), 13);

        assertEq(_vaultsAllocation(vaults[0]), 10 - 2);
        assertEq(_vaultsAllocation(vaults[1]), 20 - 4);
        assertEq(_vaultsAllocation(vaults[2]), 30 - 6);
        assertEq(asset.balanceOf(address(commonAggregator)), 5 - 1);
    }

    function testWithdrawRoundingErrors() public {
        _prepareDistribution([uint256(10), 20, 50], 5);

        _bobWithdraw(12);
        assertEq(asset.balanceOf(bob), 12);

        // 12 * 10 % 85 > 0 so we round up
        assertEq(_vaultsAllocation(vaults[0]), 10 - 1 - 1);
        // 12 * 20 % 85 > 0 so we round up
        assertEq(_vaultsAllocation(vaults[1]), 20 - 2 - 1);
        // 12 * 50 % 85 > 0 so we round up
        assertEq(_vaultsAllocation(vaults[2]), 50 - 7 - 1);
        // due to rounding up, we end up with extra 1 in idle
        assertEq(asset.balanceOf(address(commonAggregator)), 5 + 1);
    }

    function testWithdrawRoundingErrors2() public {
        _prepareDistribution([uint256(10), 20, 50], 1);

        _bobWithdraw(12);
        assertEq(asset.balanceOf(bob), 12);

        // 12 * 10 % 81 > 0 so we round up
        assertEq(_vaultsAllocation(vaults[0]), 10 - 1 - 1);
        // 12 * 20 % 81 > 0 so we round up
        assertEq(_vaultsAllocation(vaults[1]), 20 - 2 - 1);
        // 12 * 50 % 81 > 0 so we round up
        assertEq(_vaultsAllocation(vaults[2]), 50 - 7 - 1);
        // due to rounding up, we end up with extra 1 in idle
        assertEq(asset.balanceOf(address(commonAggregator)), 1 + 1);
    }

    function testZeroAssets() public {
        vm.expectRevert(ICommonAggregator.NotEnoughFunds.selector);
        vm.prank(address(commonAggregator));
        commonAggregator.pullFundsProportional(1);
    }

    function testWithdrawAll() public {
        _prepareDistribution([uint256(10), 20, 50], 23);

        _bobWithdraw(103);

        assertEq(asset.balanceOf(bob), 103);
    }

    function testFuzz_CanPullAssets(uint120[VAULT_COUNT] memory vaultFunds, uint120 idle, uint16 bps) public {
        vm.assume(bps <= MAX_BPS);

        uint256[VAULT_COUNT] memory _vaultFunds;
        for (uint256 i = 0; i < VAULT_COUNT; ++i) {
            _vaultFunds[i] = uint256(vaultFunds[i]);
        }

        uint256 assetsDeposited = _prepareDistribution(_vaultFunds, idle);

        uint256 assetsToWithdraw = assetsDeposited.mulDiv(bps, MAX_BPS);

        vm.prank(address(commonAggregator));
        commonAggregator.pullFundsProportional(assetsToWithdraw);
    }

    function testCustomVaultWithdrawLimits() public {
        _prepareDistribution([uint256(30), 30, 30], 30);

        vaults[0].setWithdrawLimit(10);

        vm.prank(address(commonAggregator));
        vm.expectPartialRevert(ERC4626BufferedUpgradeable.ERC4626ExceededMaxWithdraw.selector);
        commonAggregator.pullFundsProportional(70);
    }

    function testFallback() public {
        _prepareDistribution([uint256(30), 30, 30], 30);

        vaults[0].setWithdrawLimit(10);

        // Max amount that can be withdrawn from aggregated vaults.
        // Sequential withdrawal should be able to pull all 100.
        _bobWithdraw(100);
    }

    function testTryDirectCall() public {
        vm.expectRevert(ICommonAggregator.CallerNotAggregator.selector);
        commonAggregator.pullFundsProportional(10);
    }

    function testSimpleRedeem() public {
        _prepareDistribution([uint256(10), 20, 50], 20);

        uint256 bobShares = commonAggregator.balanceOf(alice) / 2;
        vm.prank(alice);
        commonAggregator.transfer(bob, bobShares);

        vm.prank(bob);
        commonAggregator.approve(address(commonAggregator), bobShares);
        vm.prank(bob);
        commonAggregator.redeem(bobShares, bob, bob);

        assertEq(_vaultsAllocation(vaults[0]), 5);
        assertEq(_vaultsAllocation(vaults[1]), 10);
        assertEq(_vaultsAllocation(vaults[2]), 25);
        assertEq(asset.balanceOf(address(commonAggregator)), 10);

        assertEq(asset.balanceOf(bob), 50);
    }

    function testRedeemAll() public {
        _prepareDistribution([uint256(10), 20, 50], 20);

        uint256 bobShares = commonAggregator.balanceOf(alice);
        vm.prank(alice);
        commonAggregator.transfer(bob, bobShares);

        vm.prank(bob);
        commonAggregator.approve(address(commonAggregator), bobShares);
        vm.prank(bob);
        commonAggregator.redeem(bobShares, bob, bob);

        assertEq(asset.balanceOf(bob), 100);
    }

    function _bobWithdraw(uint256 amount) internal {
        uint256 bobShares = commonAggregator.convertToShares(amount);
        vm.prank(alice);
        commonAggregator.transfer(bob, bobShares);

        vm.prank(bob);
        commonAggregator.approve(address(commonAggregator), bobShares);
        vm.prank(bob);
        commonAggregator.withdraw(amount, bob, bob);
    }

    function _vaultsAllocation(IERC4626 vault) internal view returns (uint256) {
        uint256 sharesInAggregator = vault.balanceOf(address(commonAggregator));
        return vault.convertToAssets(sharesInAggregator);
    }

    function _prepareDistribution(uint256[VAULT_COUNT] memory vaultFunds, uint256 idle) internal returns (uint256) {
        uint256 initialDeposit = idle;
        for (uint256 i = 0; i < vaultFunds.length; ++i) {
            initialDeposit += vaultFunds[i];
        }

        asset.mint(alice, initialDeposit);

        vm.prank(alice);
        asset.approve(address(commonAggregator), initialDeposit);
        vm.prank(alice);
        commonAggregator.deposit(initialDeposit, alice);

        for (uint256 i = 0; i < VAULT_COUNT; ++i) {
            vm.prank(owner);
            commonAggregator.pushFunds(vaultFunds[i], vaults[i]);
        }

        return initialDeposit;
    }
}
