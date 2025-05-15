// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {CommonAggregator} from "contracts/CommonAggregator.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC4626Mock} from "tests/mock/ERC4626Mock.sol";
import {ERC20Mock} from "tests/mock/ERC20Mock.sol";

contract CommonAggregatorTest is Test {
    uint256 constant STARTING_TIMESTAMP = 100_000_000;
    uint256 constant VAULT_COUNT = 8;
    uint256 constant BASE_AMOUNT = 1_000_000;
    uint256 constant DROP_AMOUNT = 1_000;

    CommonAggregator commonAggregator;
    address owner = address(0x123);
    address protocolFeeRecevier = address(1);
    ERC20Mock asset = new ERC20Mock();
    ERC4626Mock[] vaults = new ERC4626Mock[](VAULT_COUNT);

    address alice = address(0x456);
    address bob = address(0x678);

    function testBenchmarkRelevantMethods() public {
        vm.warp(STARTING_TIMESTAMP);
        CommonAggregator implementation = new CommonAggregator();

        for (uint256 i = 0; i < VAULT_COUNT; ++i) {
            vaults[i] = new ERC4626Mock(address(asset));
        }

        bytes memory initializeData =
            abi.encodeWithSelector(CommonAggregator.initialize.selector, owner, asset, protocolFeeRecevier, vaults);

        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initializeData);
        commonAggregator = CommonAggregator(address(proxy));

        uint256 amountToDeposit = BASE_AMOUNT;
        for (uint256 i = 0; i < VAULT_COUNT; ++i) {
            amountToDeposit += (i + 1) * BASE_AMOUNT;
        }

        // Deposits to idle
        vm.startPrank(alice);
        asset.mint(alice, amountToDeposit + BASE_AMOUNT);
        asset.approve(address(commonAggregator), type(uint256).max);

        advanceTimeWithGain();
        commonAggregator.deposit(amountToDeposit, alice);

        advanceTimeWithGain();
        uint256 sharesToMint = commonAggregator.previewDeposit(BASE_AMOUNT);
        commonAggregator.mint(sharesToMint, alice);
        vm.stopPrank();

        for (uint256 i = 0; i < VAULT_COUNT; ++i) {
            vm.prank(owner);
            // Pushing funds
            commonAggregator.pushFunds((i + 1) * BASE_AMOUNT, vaults[i]);
        }

        // Deposits to strategies
        vm.startPrank(alice);
        asset.mint(alice, amountToDeposit + BASE_AMOUNT);
        asset.approve(address(commonAggregator), type(uint256).max);

        advanceTimeWithGain();
        commonAggregator.deposit(amountToDeposit, alice);

        advanceTimeWithGain();
        sharesToMint = commonAggregator.previewDeposit(BASE_AMOUNT);
        commonAggregator.mint(sharesToMint, alice);
        vm.stopPrank();

        // Pulling funds
        advanceTimeWithGain();
        vm.prank(owner);
        commonAggregator.pullFunds(BASE_AMOUNT, vaults[2]);

        // Withdrawals
        vm.startPrank(alice);
        advanceTimeWithGain();
        commonAggregator.withdraw(BASE_AMOUNT, alice, alice);

        advanceTimeWithGain();
        uint256 sharesToWithdraw = commonAggregator.previewWithdraw(BASE_AMOUNT);
        commonAggregator.redeem(sharesToWithdraw, alice, alice);
        vm.stopPrank();

        // Update holdings state
        for (uint256 i = 0; i < 5; i++) {
            advanceTimeWithGain();
            commonAggregator.updateHoldingsState();
        }
    }

    function advanceTimeWithGain() internal {
        // Drop some funds to have a meaningful report
        asset.mint(address(commonAggregator), DROP_AMOUNT);
        vm.warp(vm.getBlockTimestamp() + 1 days);
    }
}
