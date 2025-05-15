// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {CommonAggregator, ERC4626BufferedUpgradeable} from "contracts/CommonAggregator.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20, IERC20Errors} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC4626Mock} from "tests/mock/ERC4626Mock.sol";
import {ERC20Mock} from "tests/mock/ERC20Mock.sol";

contract CommonAggregatorTest is Test {
    using Math for uint256;

    uint256 constant STARTING_TIMESTAMP = 100_000_000;
    uint256 constant VAULT_COUNT = 3;

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

    function testEmergencyRedeemAllShares() public {
        uint256 aliceShares = _deposit(1000, alice);
        _deposit(500, bob);

        _distribute([uint256(400), 300, 200]);

        uint256 expectedAliceAssets = _expectedUserAssets(aliceShares);
        uint256[VAULT_COUNT] memory expectedAliceVaultsShares = _expectedUserVaultsShares(aliceShares);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626BufferedUpgradeable.ERC4626ExceededMaxRedeem.selector, alice, aliceShares + 1, aliceShares
            )
        );
        commonAggregator.emergencyRedeem(aliceShares + 1, alice, alice);

        vm.prank(alice);
        (uint256 assets, uint256[] memory aliceVaultShares) =
            commonAggregator.emergencyRedeem(aliceShares, alice, alice);

        assertEq(expectedAliceAssets, assets);
        assertEq(expectedAliceAssets, asset.balanceOf(alice));

        for (uint256 i = 0; i < VAULT_COUNT; i++) {
            assertEq(expectedAliceVaultsShares[i], aliceVaultShares[i]);
            assertEq(expectedAliceVaultsShares[i], IERC20(vaults[i]).balanceOf(alice));
        }
    }

    function testEmergencyRedeemPartialShares() public {
        uint256 aliceShares = _deposit(1000, alice);
        _deposit(500, bob);

        _distribute([uint256(400), 300, 200]);

        uint256 sharesToRedeem = aliceShares / 4;

        uint256 expectedAliceAssets = _expectedUserAssets(sharesToRedeem);
        uint256[VAULT_COUNT] memory expectedAliceVaultsShares = _expectedUserVaultsShares(sharesToRedeem);

        vm.prank(alice);
        (uint256 assets, uint256[] memory aliceVaultShares) =
            commonAggregator.emergencyRedeem(sharesToRedeem, alice, alice);

        assertEq(expectedAliceAssets, assets);
        assertEq(expectedAliceAssets, asset.balanceOf(alice));

        for (uint256 i = 0; i < VAULT_COUNT; i++) {
            assertEq(expectedAliceVaultsShares[i], aliceVaultShares[i]);
            assertEq(expectedAliceVaultsShares[i], IERC20(vaults[i]).balanceOf(alice));
        }
    }

    function testEmergencyRedeemZeroVaultsShares() public {
        uint256 aliceShares = _deposit(1000, alice);
        _deposit(500, bob);

        uint256 expectedAliceAssets = _expectedUserAssets(aliceShares);

        vm.prank(alice);
        (uint256 assets, uint256[] memory aliceVaultShares) =
            commonAggregator.emergencyRedeem(aliceShares, alice, alice);

        assertEq(expectedAliceAssets, assets);
        assertEq(expectedAliceAssets, asset.balanceOf(alice));

        for (uint256 i = 0; i < VAULT_COUNT; i++) {
            assertEq(0, aliceVaultShares[i]);
            assertEq(0, IERC20(vaults[i]).balanceOf(alice));
        }
    }

    function testEmergencyRedeemPartialSharesWithAllowance() public {
        uint256 aliceShares = _deposit(1000, alice);
        _deposit(500, bob);

        _distribute([uint256(400), 300, 200]);

        uint256 sharesToRedeem = aliceShares / 4;

        vm.prank(alice);
        commonAggregator.approve(bob, sharesToRedeem);

        uint256 expectedAliceAssets = _expectedUserAssets(sharesToRedeem);
        uint256[VAULT_COUNT] memory expectedAliceVaultsShares = _expectedUserVaultsShares(sharesToRedeem);

        address charlie = address(0x4321);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, bob, sharesToRedeem, sharesToRedeem + 1
            )
        );
        commonAggregator.emergencyRedeem(sharesToRedeem + 1, charlie, alice);

        vm.prank(bob);
        (, uint256[] memory aliceVaultShares) = commonAggregator.emergencyRedeem(sharesToRedeem, charlie, alice);

        assertEq(expectedAliceAssets, asset.balanceOf(charlie));

        for (uint256 i = 0; i < VAULT_COUNT; i++) {
            assertEq(expectedAliceVaultsShares[i], aliceVaultShares[i]);
            assertEq(expectedAliceVaultsShares[i], IERC20(vaults[i]).balanceOf(charlie));
        }
    }

    function testEmergencyRedeemZeroAssets() public {
        uint256 aliceShares = _deposit(1000, alice);
        _deposit(500, bob);

        _distribute([uint256(700), 500, 300]);

        uint256[VAULT_COUNT] memory expectedAliceVaultsShares = _expectedUserVaultsShares(aliceShares);

        vm.prank(alice);
        (uint256 assets, uint256[] memory aliceVaultShares) =
            commonAggregator.emergencyRedeem(aliceShares, alice, alice);

        assertEq(0, assets);
        assertEq(0, asset.balanceOf(alice));

        for (uint256 i = 0; i < VAULT_COUNT; i++) {
            assertEq(expectedAliceVaultsShares[i], aliceVaultShares[i]);
            assertEq(expectedAliceVaultsShares[i], IERC20(vaults[i]).balanceOf(alice));
        }
    }

    function testEmergencyRedeemWithAssetProfit() public {
        uint256 aliceShares = _deposit(1000, alice);
        _deposit(500, bob);

        _distribute([uint256(400), 300, 200]);

        uint256 expectedAliceAssetsBeforeChange = _expectedUserAssets(aliceShares);
        uint256[VAULT_COUNT] memory expectedAliceVaultsSharesBeforeChange = _expectedUserVaultsShares(aliceShares);

        uint256 expectedValueInAssetsBeforeChange = _expectedValueInAssets(aliceShares);

        asset.mint(address(commonAggregator), 150);
        commonAggregator.updateHoldingsState();
        vm.warp(STARTING_TIMESTAMP + 2 days);

        uint256 expectedAliceAssets = _expectedUserAssets(aliceShares);
        uint256[VAULT_COUNT] memory expectedAliceVaultsShares = _expectedUserVaultsShares(aliceShares);

        uint256 expectedValueInAssets = _expectedValueInAssets(aliceShares);

        vm.prank(alice);
        (uint256 assets, uint256[] memory aliceVaultShares) =
            commonAggregator.emergencyRedeem(aliceShares, alice, alice);

        assertEq(expectedAliceAssets, assets);
        assertEq(expectedAliceAssets, asset.balanceOf(alice));
        assertGt(expectedAliceAssets, expectedAliceAssetsBeforeChange);

        for (uint256 i = 0; i < VAULT_COUNT; i++) {
            assertEq(expectedAliceVaultsShares[i], aliceVaultShares[i]);
            assertEq(expectedAliceVaultsShares[i], IERC20(vaults[i]).balanceOf(alice));
            assertLt(expectedAliceVaultsShares[i], expectedAliceVaultsSharesBeforeChange[i]);
        }

        assertGt(expectedValueInAssets, expectedValueInAssetsBeforeChange);
    }

    function testEmergencyRedeemWithVaultsProfit() public {
        uint256 aliceShares = _deposit(1000, alice);
        _deposit(500, bob);

        _distribute([uint256(400), 300, 200]);

        uint256 expectedAliceAssetsBeforeChange = _expectedUserAssets(aliceShares);
        uint256[VAULT_COUNT] memory expectedAliceVaultsSharesBeforeChange = _expectedUserVaultsShares(aliceShares);

        uint256 expectedValueInAssetsBeforeChange = _expectedValueInAssets(aliceShares);

        asset.mint(address(vaults[0]), 50);
        asset.mint(address(vaults[1]), 50);
        asset.mint(address(vaults[2]), 50);
        commonAggregator.updateHoldingsState();
        vm.warp(STARTING_TIMESTAMP + 2 days);

        uint256 expectedAliceAssets = _expectedUserAssets(aliceShares);
        uint256[VAULT_COUNT] memory expectedAliceVaultsShares = _expectedUserVaultsShares(aliceShares);

        uint256 expectedValueInAssets = _expectedValueInAssets(aliceShares);

        vm.prank(alice);
        (uint256 assets, uint256[] memory aliceVaultShares) =
            commonAggregator.emergencyRedeem(aliceShares, alice, alice);

        assertEq(expectedAliceAssets, assets);
        assertEq(expectedAliceAssets, asset.balanceOf(alice));
        assertLt(expectedAliceAssets, expectedAliceAssetsBeforeChange);

        for (uint256 i = 0; i < VAULT_COUNT; i++) {
            assertEq(expectedAliceVaultsShares[i], aliceVaultShares[i]);
            assertEq(expectedAliceVaultsShares[i], IERC20(vaults[i]).balanceOf(alice));
            assertLt(expectedAliceVaultsShares[i], expectedAliceVaultsSharesBeforeChange[i]);
        }

        assertGt(expectedValueInAssets, expectedValueInAssetsBeforeChange);
    }

    function testEmergencyRedeemWithAssetLoss() public {
        uint256 aliceShares = _deposit(1000, alice);
        _deposit(500, bob);

        _distribute([uint256(400), 300, 200]);

        uint256 expectedAliceAssetsBeforeChange = _expectedUserAssets(aliceShares);
        uint256[VAULT_COUNT] memory expectedAliceVaultsSharesBeforeChange = _expectedUserVaultsShares(aliceShares);

        uint256 expectedValueInAssetsBeforeChange = _expectedValueInAssets(aliceShares);

        asset.burn(address(commonAggregator), 150);
        commonAggregator.updateHoldingsState();
        vm.warp(STARTING_TIMESTAMP + 2 days);

        uint256 expectedAliceAssets = _expectedUserAssets(aliceShares);
        uint256[VAULT_COUNT] memory expectedAliceVaultsShares = _expectedUserVaultsShares(aliceShares);

        uint256 expectedValueInAssets = _expectedValueInAssets(aliceShares);

        vm.prank(alice);
        (uint256 assets, uint256[] memory aliceVaultShares) =
            commonAggregator.emergencyRedeem(aliceShares, alice, alice);

        assertEq(expectedAliceAssets, assets);
        assertEq(expectedAliceAssets, asset.balanceOf(alice));
        assertLt(expectedAliceAssets, expectedAliceAssetsBeforeChange);

        for (uint256 i = 0; i < VAULT_COUNT; i++) {
            assertEq(expectedAliceVaultsShares[i], aliceVaultShares[i]);
            assertEq(expectedAliceVaultsShares[i], IERC20(vaults[i]).balanceOf(alice));
            assertEq(expectedAliceVaultsShares[i], expectedAliceVaultsSharesBeforeChange[i]);
        }

        assertLt(expectedValueInAssets, expectedValueInAssetsBeforeChange);
    }

    function testEmergencyRedeemWithVaultsLoss() public {
        uint256 aliceShares = _deposit(1000, alice);
        _deposit(500, bob);

        _distribute([uint256(400), 300, 200]);

        uint256 expectedAliceAssetsBeforeChange = _expectedUserAssets(aliceShares);
        uint256[VAULT_COUNT] memory expectedAliceVaultsSharesBeforeChange = _expectedUserVaultsShares(aliceShares);

        uint256 expectedValueInAssetsBeforeChange = _expectedValueInAssets(aliceShares);

        asset.burn(address(vaults[0]), 50);
        asset.burn(address(vaults[1]), 50);
        asset.burn(address(vaults[2]), 50);
        commonAggregator.updateHoldingsState();
        vm.warp(STARTING_TIMESTAMP + 2 days);

        uint256 expectedAliceAssets = _expectedUserAssets(aliceShares);
        uint256[VAULT_COUNT] memory expectedAliceVaultsShares = _expectedUserVaultsShares(aliceShares);

        uint256 expectedValueInAssets = _expectedValueInAssets(aliceShares);

        vm.prank(alice);
        (uint256 assets, uint256[] memory aliceVaultShares) =
            commonAggregator.emergencyRedeem(aliceShares, alice, alice);

        assertEq(expectedAliceAssets, assets);
        assertEq(expectedAliceAssets, asset.balanceOf(alice));
        assertEq(expectedAliceAssets, expectedAliceAssetsBeforeChange);

        for (uint256 i = 0; i < VAULT_COUNT; i++) {
            assertEq(expectedAliceVaultsShares[i], aliceVaultShares[i]);
            assertEq(expectedAliceVaultsShares[i], IERC20(vaults[i]).balanceOf(alice));
            assertEq(expectedAliceVaultsShares[i], expectedAliceVaultsSharesBeforeChange[i]);
        }

        assertLt(expectedValueInAssets, expectedValueInAssetsBeforeChange);
    }

    function testFuzz_EmergencyReedemRoundingError(uint256 a, uint192 p, uint192 q, uint192 r, uint192 s) public {
        uint256 sum = uint256(p) + q + r + s;
        a = bound(a, 0, sum);
        uint256 b = sum - a;

        uint256 aliceShares = _deposit(uint256(a), alice);
        _deposit(b, bob);

        _distribute([uint256(p), q, r]); // `s` stays as the idle balance

        uint256 expectedAliceAssets = _expectedUserAssets(aliceShares);
        uint256[VAULT_COUNT] memory expectedAliceVaultsShares = _expectedUserVaultsShares(aliceShares);

        uint256 expectedEmergencyRedeem = _expectedValueInAssets(aliceShares);
        uint256 expectedRedeem = commonAggregator.previewRedeem(aliceShares);

        vm.prank(alice);
        (uint256 assets, uint256[] memory aliceVaultShares) =
            commonAggregator.emergencyRedeem(aliceShares, alice, alice);

        for (uint256 i = 0; i < VAULT_COUNT; i++) {
            assertEq(expectedAliceVaultsShares[i], aliceVaultShares[i]);
            assertEq(expectedAliceVaultsShares[i], IERC20(vaults[i]).balanceOf(alice));
        }

        assertEq(expectedAliceAssets, assets);
        assertLe(expectedEmergencyRedeem, expectedRedeem);
        (, uint256 expectedRedeemWithRoundingError) = expectedRedeem.trySub(VAULT_COUNT);
        assertGe(expectedEmergencyRedeem, expectedRedeemWithRoundingError);
    }

    function _deposit(uint256 amount, address depositor) internal returns (uint256) {
        asset.mint(depositor, amount);

        vm.prank(depositor);
        asset.approve(address(commonAggregator), amount);
        vm.prank(depositor);
        return commonAggregator.deposit(amount, depositor);
    }

    function _distribute(uint256[VAULT_COUNT] memory vaultFunds) internal {
        for (uint256 i = 0; i < VAULT_COUNT; ++i) {
            vm.prank(owner);
            commonAggregator.pushFunds(vaultFunds[i], vaults[i]);
        }
    }

    /// Should be called before `emergencyRedeem`.
    function _expectedUserVaultsShares(uint256 userShares)
        internal
        view
        returns (uint256[VAULT_COUNT] memory expectedUserVaultsShares)
    {
        uint256 totalShares = commonAggregator.totalSupply();
        for (uint256 i = 0; i < VAULT_COUNT; i++) {
            expectedUserVaultsShares[i] = vaults[i].balanceOf(address(commonAggregator)).mulDiv(userShares, totalShares);
        }
    }

    /// Should be called before `emergencyRedeem`.
    function _expectedUserAssets(uint256 userShares) internal view returns (uint256) {
        uint256 idleAssets = asset.balanceOf(address(commonAggregator));
        uint256 totalShares = commonAggregator.totalSupply();
        return idleAssets.mulDiv(userShares, totalShares);
    }

    /// Should be called before `emergencyRedeem`.
    function _expectedValueInAssets(uint256 userShares) internal view returns (uint256 valueInAssets) {
        uint256[VAULT_COUNT] memory userVaultsShares = _expectedUserVaultsShares(userShares);
        valueInAssets = _expectedUserAssets(userShares);
        for (uint256 i = 0; i < VAULT_COUNT; i++) {
            valueInAssets += vaults[i].convertToAssets(userVaultsShares[i]);
        }
    }
}
