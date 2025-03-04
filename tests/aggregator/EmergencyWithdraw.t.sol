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
import {MAX_BPS} from "contracts/Math.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract CommonAggregatorTest is Test {
    using Math for uint256;

    uint256 constant STARTING_TIMESTAMP = 100_000_000;
    uint256 constant VAULT_COUNT = 3;

    CommonAggregator commonAggregator;
    address owner = address(0x123);

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

        bytes memory initializeData = abi.encodeWithSelector(CommonAggregator.initialize.selector, owner, asset, vaults);

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
        (uint256 assets, uint256[] memory aliceVaultShares) =
            commonAggregator.emergencyRedeem(aliceShares, alice, alice);

        assertEq(expectedAliceAssets, assets);
        assertEq(expectedAliceAssets, asset.balanceOf(alice));

        assertEq(expectedAliceVaultsShares[0], aliceVaultShares[0]);
        assertEq(expectedAliceVaultsShares[0], IERC20(vaults[0]).balanceOf(alice));

        assertEq(expectedAliceVaultsShares[1], aliceVaultShares[1]);
        assertEq(expectedAliceVaultsShares[1], IERC20(vaults[1]).balanceOf(alice));

        assertEq(expectedAliceVaultsShares[2], aliceVaultShares[2]);
        assertEq(expectedAliceVaultsShares[2], IERC20(vaults[2]).balanceOf(alice));
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

        assertEq(expectedAliceVaultsShares[0], aliceVaultShares[0]);
        assertEq(expectedAliceVaultsShares[0], IERC20(vaults[0]).balanceOf(alice));

        assertEq(expectedAliceVaultsShares[1], aliceVaultShares[1]);
        assertEq(expectedAliceVaultsShares[1], IERC20(vaults[1]).balanceOf(alice));

        assertEq(expectedAliceVaultsShares[2], aliceVaultShares[2]);
        assertEq(expectedAliceVaultsShares[2], IERC20(vaults[2]).balanceOf(alice));
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

        assertEq(0, aliceVaultShares[0]);
        assertEq(0, IERC20(vaults[0]).balanceOf(alice));

        assertEq(0, aliceVaultShares[1]);
        assertEq(0, IERC20(vaults[1]).balanceOf(alice));

        assertEq(0, aliceVaultShares[2]);
        assertEq(0, IERC20(vaults[2]).balanceOf(alice));
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

        assertEq(expectedAliceVaultsShares[0], aliceVaultShares[0]);
        assertEq(expectedAliceVaultsShares[0], IERC20(vaults[0]).balanceOf(alice));

        assertEq(expectedAliceVaultsShares[1], aliceVaultShares[1]);
        assertEq(expectedAliceVaultsShares[1], IERC20(vaults[1]).balanceOf(alice));

        assertEq(expectedAliceVaultsShares[2], aliceVaultShares[2]);
        assertEq(expectedAliceVaultsShares[2], IERC20(vaults[2]).balanceOf(alice));
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

    function _vaultsAllocation() internal view returns (uint256[VAULT_COUNT] memory allocation) {
        for (uint256 i = 0; i < VAULT_COUNT; i++) {
            allocation[i] = vaults[i].convertToAssets(vaults[i].balanceOf(address(commonAggregator)));
        }
    }

    /// Should be called before `emergencyRedeem`.
    function _expectedUserVaultsShares(uint256 userShares)
        internal
        view
        returns (uint256[VAULT_COUNT] memory expectedUserVaultsShares)
    {
        uint256[VAULT_COUNT] memory aggVaultsShares = _vaultsAllocation();
        uint256 totalShares = commonAggregator.totalSupply();
        for (uint256 i = 0; i < VAULT_COUNT; i++) {
            expectedUserVaultsShares[i] = aggVaultsShares[i].mulDiv(userShares, totalShares);
        }
    }

    /// Should be called before `emergencyRedeem`.
    function _expectedUserAssets(uint256 userShares) internal view returns (uint256) {
        uint256 idleAssets = asset.balanceOf(address(commonAggregator));
        uint256 totalShares = commonAggregator.totalSupply();
        return idleAssets.mulDiv(userShares, totalShares);
    }
}
