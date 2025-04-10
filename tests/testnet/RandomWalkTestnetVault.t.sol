// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {MintableERC20, RandomWalkTestnetVault} from "../../contracts/testnet/RandomWalkTestnetVault.sol";
import {ERC20Mock} from "../mock/ERC20Mock.sol";

contract RandomWalkTestnetVaultExtended is RandomWalkTestnetVault {
    constructor(
        MintableERC20 _asset,
        string memory _name,
        string memory _symbol,
        int256 _aprBps,
        int256 _minAprBps,
        int256 _maxAprBps,
        uint256 _maxAprChangeBps
    ) RandomWalkTestnetVault(_asset, _name, _symbol, _aprBps, _minAprBps, _maxAprBps, _maxAprChangeBps) {}

    function setNonceForRandomness(uint256 newNonce) public {
        nonceForRandomness = newNonce;
    }
}

contract VariablyEarningVaultTest is Test {
    uint256 STARTING_TIMESTAMP = 10 ** 9;
    ERC20Mock public token;
    RandomWalkTestnetVaultExtended public vault;
    RandomWalkTestnetVaultExtended public vault2;

    address user = address(0x123);

    function setUp() public {
        vm.warp(STARTING_TIMESTAMP);
        token = new ERC20Mock();
        vault = new RandomWalkTestnetVaultExtended(
            MintableERC20(address(token)),
            "Random Walk Testnet Vault ",
            "rwtv",
            600, // 6% APR start
            100, // 1% APR min
            1000, // 10% APR max
            25 // 0.25 percentage points APR max change
        );
        vault2 = new RandomWalkTestnetVaultExtended(
            MintableERC20(address(token)), "Random Walk Testnet Vault Mirror", "rwtv2", 600, 100, 1000, 25
        );

        vault.setNonceForRandomness(1);
        vault2.setNonceForRandomness(1);

        token.mint(user, 2000 * 10 ** 6);
        vm.startPrank(user);
        token.approve(address(vault), type(uint256).max);
        token.approve(address(vault2), type(uint256).max);
        vm.stopPrank();
    }

    function testLosses() public {
        RandomWalkTestnetVault losingVault = new RandomWalkTestnetVault(
            MintableERC20(address(token)),
            "Random Walk Testnet Vault ",
            "rwtv",
            50, // 0.5% APR start
            -500, // -5% APR min
            50, // 0.5% APR max
            25 // 0.25 percentage points APR max change
        );
        vm.prank(user);
        token.approve(address(losingVault), type(uint256).max);
        vm.prank(user);
        losingVault.deposit(1000 * 10 ** 6, user);

        vm.warp(STARTING_TIMESTAMP + 10 days);
        assertLe(losingVault.totalAssets(), 1000 * 10 ** 6);

        vm.startPrank(user);
        losingVault.withdraw(losingVault.maxWithdraw(user), address(5), user);

        losingVault.update();
        assertEq(losingVault.totalAssets(), 0);
        assertLe(token.balanceOf(address(5)), 1000 * 10 ** 6);
    }

    function testAprChanges() public {
        vm.prank(user);
        vault.deposit(1000 * 10 ** 6, user);

        assertEq(vault.getAprBps(), 600);

        vault.update();
        assertEq(vault.getAprBps(), 600);

        vm.warp(STARTING_TIMESTAMP + 5 seconds);
        vault.update();
        assertEq(vault.getAprBps(), 600);

        vm.warp(STARTING_TIMESTAMP + 30 minutes - 1);
        vault.update();
        assertEq(vault.getAprBps(), 600);

        vm.warp(STARTING_TIMESTAMP + 30 minutes);
        vault.update();
        // with some probability
        assertNotEq(vault.getAprBps(), 600);
    }

    uint256 constant MAX_FUZZ_ITERS = 16;
    /// forge-config: default.fuzz.runs = 1000

    function testFuzz_AprChanges(uint256[MAX_FUZZ_ITERS] calldata timeIntervals, uint8[MAX_FUZZ_ITERS] calldata updates)
        public
    {
        vm.prank(user);
        vault.deposit(1000 * 10 ** 6, user);
        vm.prank(user);
        vault2.deposit(1000 * 10 ** 6, user);

        uint256 currentTimestamp = STARTING_TIMESTAMP;
        for (uint256 i = 0; i < MAX_FUZZ_ITERS; i++) {
            uint256 u = bound(updates[i], 0, 2);
            uint256 timeInterval = bound(timeIntervals[i], 1, 5 hours);

            currentTimestamp += timeInterval;
            vm.warp(currentTimestamp);

            if (u == 0 || u == 2) {
                vault.update();
            }
            if (u == 1 || u == 2) {
                vault2.update();
            }

            assertEq(vault.getAprBps(), vault2.getAprBps());
        }
    }

    function testLongTimeNoUpdate() public {
        vm.prank(user);
        vault.deposit(1000 * 10 ** 6, user);

        assertEq(vault.getAprBps(), 600);
        assertEq(vault.totalAssets(), 1000 * 10 ** 6);

        vm.warp(STARTING_TIMESTAMP + 6 days);
        uint256 totalAssetsA = vault.totalAssets();

        vm.warp(STARTING_TIMESTAMP + 16 days);
        uint256 totalAssetsB = vault.totalAssets();

        vm.warp(STARTING_TIMESTAMP + 206 days);
        vault.update();

        assertGe((vault.totalAssets() - totalAssetsA), (totalAssetsB - totalAssetsA) * 20 - 20, ">=");
        assertLe((vault.totalAssets() - totalAssetsA), (totalAssetsB - totalAssetsA) * 20 + 20, "<=");
    }

    function testDeposit() public {
        vm.prank(user);
        vault.deposit(1000 * 10 ** 6, user);

        assertEq(vault.getAprBps(), 600);
        assertEq(vault.totalAssets(), 1000 * 10 ** 6);

        vm.warp(STARTING_TIMESTAMP + 5 minutes);
        assertEq(vault.getAprBps(), 600);
        assertEq(vault.totalAssets(), 1000001140);

        vm.warp(STARTING_TIMESTAMP + 15 minutes);
        assertEq(vault.getAprBps(), 600);

        // Value slightly larger than initialDeposit + 1140*3 due to compounding
        assertEq(vault.totalAssets(), 1000003424);
    }

    function testMeanAfterManyUpdates() public {
        uint256 initial = 1000 * 10 ** 6;
        vm.prank(user);
        vault.deposit(initial, user);

        uint256 expectedMean = initial;
        for (uint256 i = 0; i < 365; i++) {
            vm.warp(STARTING_TIMESTAMP + i * uint256(1 days));
            vault.update();
            assertGe(vault.getAprBps(), 100);
            assertLe(vault.getAprBps(), 1000);
            expectedMean = expectedMean + (expectedMean * 55 * 1 days) / (1000 * 365 days);
        }

        assertGe(vault.totalAssets(), expectedMean * 9 / 10);
        assertLe(vault.totalAssets(), expectedMean * 11 / 10);
    }
}
