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

        asset.mint(bob, type(uint128).max);
    }

    function testFirstDepositCanBeMade() public {
        uint256 initialDeposit = 10000;
        _firstDeposit(initialDeposit);
        assertEq(commonAggregator.totalAssets(), initialDeposit);
    }

    function testTinyProportionalDeposit() public {
        _firstDeposit(10000);
        _prepareDistribution([uint256(1000), 100, 1]);

        _bobDeposit(10);

        assertEq(_vaultsAllocation(vaults[0]), 1001);
        assertEq(_vaultsAllocation(vaults[1]), 100);
        assertEq(_vaultsAllocation(vaults[2]), 1);
    }

    function testSmallProportionalDeposit() public {
        _firstDeposit(10000);
        _prepareDistribution([uint256(6000), 500, 2]);

        _bobDeposit(10000);

        assertEq(_vaultsAllocation(vaults[0]), 12000);
        assertEq(_vaultsAllocation(vaults[1]), 1000);
        assertEq(_vaultsAllocation(vaults[2]), 4);
    }

    function testFuzz_ProportionalDeposit(uint16[VAULT_COUNT] calldata initialDistribution, uint128 depositSize)
        public
    {
        uint256 initDistributionSum = 0;
        for (uint256 i = 0; i < VAULT_COUNT; ++i) {
            initDistributionSum += initialDistribution[i];
        }

        vm.assume(initDistributionSum <= 10000);

        _firstDeposit(10000);

        uint256[VAULT_COUNT] memory initDistributionArg;
        for (uint256 i = 0; i < VAULT_COUNT; ++i) {
            initDistributionArg[i] = uint256(initialDistribution[i]);
        }

        _prepareDistribution(initDistributionArg);

        _bobDeposit(depositSize);

        for (uint256 i = 0; i < VAULT_COUNT; ++i) {
            assertEq(
                _vaultsAllocation(vaults[i]),
                uint256(depositSize).mulDiv(initialDistribution[i], 10000) + initialDistribution[i]
            );
        }
    }

    function testProportionalMint() public {
        uint256 shares = _firstDeposit(10000);
        _prepareDistribution([uint256(1000), 100, 1]);

        assert(shares % 10 == 0);
        _bobMint(shares / 10);

        assertEq(_vaultsAllocation(vaults[0]), 1100);
        assertEq(_vaultsAllocation(vaults[1]), 110);
        assertEq(_vaultsAllocation(vaults[2]), 1);
    }

    function testFuzz_ProportionalMint(uint16[VAULT_COUNT] calldata initialDistribution, uint128 mintSize) public {
        uint256 initDistributionSum = 0;
        for (uint256 i = 0; i < VAULT_COUNT; ++i) {
            initDistributionSum += initialDistribution[i];
        }

        vm.assume(initDistributionSum <= 10000);

        _firstDeposit(10000);

        uint256[VAULT_COUNT] memory initDistributionArg;
        for (uint256 i = 0; i < VAULT_COUNT; ++i) {
            initDistributionArg[i] = uint256(initialDistribution[i]);
        }

        _prepareDistribution(initDistributionArg);

        _bobMint(mintSize);

        for (uint256 i = 0; i < VAULT_COUNT; ++i) {
            assertEq(
                _vaultsAllocation(vaults[i]),
                commonAggregator.previewMint(mintSize).mulDiv(initialDistribution[i], 10000) + initialDistribution[i]
            );
        }
    }

    function _firstDeposit(uint256 initialDeposit) internal returns (uint256) {
        asset.mint(alice, initialDeposit);

        vm.prank(alice);
        asset.approve(address(commonAggregator), initialDeposit);
        vm.prank(alice);
        return commonAggregator.deposit(initialDeposit, alice);
    }

    function _prepareDistribution(uint256[VAULT_COUNT] memory vaultFunds) internal {
        for (uint256 i = 0; i < VAULT_COUNT; ++i) {
            vm.prank(owner);
            commonAggregator.pushFunds(vaultFunds[i], vaults[i]);
        }
    }

    function _bobDeposit(uint256 amount) internal {
        vm.prank(bob);
        asset.approve(address(commonAggregator), amount);
        vm.prank(bob);
        commonAggregator.deposit(amount, bob);
    }

    function _bobMint(uint256 shares) internal {
        uint256 requiredAssets = commonAggregator.previewMint(shares);
        vm.prank(bob);
        asset.approve(address(commonAggregator), requiredAssets);
        vm.prank(bob);
        commonAggregator.mint(shares, bob);
    }

    function _vaultsAllocation(IERC4626 vault) internal view returns (uint256) {
        uint256 sharesInAggregator = vault.balanceOf(address(commonAggregator));
        return vault.convertToAssets(sharesInAggregator);
    }
}
