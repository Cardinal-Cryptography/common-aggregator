// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC4626BufferedUpgradeable, IERC4626Buffered} from "../contracts/ERC4626BufferedUpgradeable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MAX_BPS} from "../contracts/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC20Mock} from "tests/mock/ERC20Mock.sol";

contract ERC4626BufferedUpgradeableConcrete is ERC4626BufferedUpgradeable {
    function initialize(IERC20 _asset) public initializer {
        __ERC4626Buffered_init(_asset);
    }

    function currentBufferEnd() external view returns (uint256) {
        return _getERC4626BufferedStorage().currentBufferEnd;
    }

    function lastUpdate() external view returns (uint256) {
        return _getERC4626BufferedStorage().lastUpdate;
    }

    function previewUpdateHoldingsState() external view returns (uint256, uint256) {
        return _previewUpdateHoldingsState();
    }

    function updateHoldingsState() external {
        _updateHoldingsState();
    }
}

contract ERC4626BufferedUpgradeableTest is Test {
    using Math for uint256;

    uint256 constant STARTING_TIMESTAMP = 100;
    uint256 constant STARTING_BALANCE = 10;

    ERC4626BufferedUpgradeableConcrete bufferedVault;
    ERC20Mock asset = new ERC20Mock();

    address alice = address(0x456);
    address bob = address(0x678);

    function setUp() public {
        vm.warp(STARTING_TIMESTAMP);
        ERC4626BufferedUpgradeable implementation = new ERC4626BufferedUpgradeableConcrete();

        bytes memory initializeData =
            abi.encodeWithSelector(ERC4626BufferedUpgradeableConcrete.initialize.selector, asset, bob);

        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initializeData);
        bufferedVault = ERC4626BufferedUpgradeableConcrete(address(proxy));
    }

    function testAssetsAfterInit() public view {
        assertEq(bufferedVault.asset(), address(asset));
        assertEq(bufferedVault.totalAssets(), 0);
    }

    function testZeroDepositsAndDrops() public {
        _dropToVault(0);
        bufferedVault.updateHoldingsState();

        _depositToVault(0);

        vm.warp(STARTING_TIMESTAMP + 4 days);
        assertEq(bufferedVault.totalAssets(), 0);
        assertEq(bufferedVault.totalSupply(), 0);
    }

    function testAssetsAfterDrop() public {
        _dropToVault(100);
        bufferedVault.updateHoldingsState();
        assertEq(bufferedVault.totalAssets(), 100);
    }

    function testAssetsAfterDropAndTimeElapsed() public {
        _dropToVault(20);
        bufferedVault.updateHoldingsState();
        vm.warp(STARTING_TIMESTAMP + 10 days);
        assertEq(bufferedVault.totalAssets(), 20);
    }

    function testSharesAfterDrop() public {
        _dropToVault(20);
        bufferedVault.updateHoldingsState();
        assertEq(bufferedVault.totalSupply(), 20);
    }

    function testSharesAfterDropAndTimeElapsed() public {
        _dropToVault(20);
        bufferedVault.updateHoldingsState();
        vm.warp(STARTING_TIMESTAMP + 2 days);
        assertEq(bufferedVault.totalSupply(), 18);
    }

    function testSharesAfterDropAndTimeElapsed2() public {
        _dropToVault(7);
        bufferedVault.updateHoldingsState();
        vm.warp(STARTING_TIMESTAMP + 7 days);
        assertEq(bufferedVault.totalSupply(), 5);
    }

    function testSharesAfterFullPeriodHasPassed() public {
        _dropToVault(10);
        bufferedVault.updateHoldingsState();
        vm.warp(STARTING_TIMESTAMP + 20 days);
        assertEq(bufferedVault.totalSupply(), 0);
    }

    function testSharesAfterDepositAndDrop() public {
        _depositToVault(10);
        _dropToVault(10);
        bufferedVault.updateHoldingsState();

        assertEq(bufferedVault.totalSupply(), 20);
    }

    function testSharesAfterDepositAndDropAndTimeElapsed() public {
        _depositToVault(10);
        _dropToVault(10);
        bufferedVault.updateHoldingsState();

        vm.warp(STARTING_TIMESTAMP + 4 days);
        assertEq(bufferedVault.totalSupply(), 18);
    }

    function testSharesAfterDropAndDepositAndTimeElapsed() public {
        _dropToVault(10);
        _depositToVault(10);
        bufferedVault.updateHoldingsState();

        vm.warp(STARTING_TIMESTAMP + 4 days);
        assertEq(bufferedVault.totalSupply(), 18);
    }

    function testBufferUpdateResultOnLoss() public {
        _depositToVault(10);
        asset.burn(address(bufferedVault), 6);
        bufferedVault.updateHoldingsState();

        assertEq(bufferedVault.totalAssets(), 4);
        assertEq(bufferedVault.totalSupply(), 10);
    }

    function testBufferUpdateResultOnLoss2() public {
        _depositToVault(5);
        _dropToVault(10);
        bufferedVault.updateHoldingsState();
        asset.burn(address(bufferedVault), 4);
        bufferedVault.updateHoldingsState();
        assertEq(bufferedVault.totalAssets(), 11);
        assertEq(bufferedVault.totalSupply(), 11);
    }

    function testBufferUpdateResultOnLoss3() public {
        _depositToVault(5);
        _dropToVault(2);
        bufferedVault.updateHoldingsState();
        asset.burn(address(bufferedVault), 4);
        bufferedVault.updateHoldingsState();
        assertEq(bufferedVault.totalAssets(), 3);
        assertEq(bufferedVault.totalSupply(), 5);
    }

    function testFeeOnGain() public {
        bufferedVault.setProtocolFee(MAX_BPS / 10);

        _depositToVault(200);
        _dropToVault(100);
        bufferedVault.updateHoldingsState();

        assertEq(asset.balanceOf(address(1)), 0);
        assertEq(bufferedVault.balanceOf(address(1)), 10);
        assertEq(bufferedVault.balanceOf(address(bufferedVault)), 90);

        vm.warp(STARTING_TIMESTAMP + 20 days);
        bufferedVault.updateHoldingsState();

        assertEq(asset.balanceOf(address(1)), 0);
        assertEq(bufferedVault.balanceOf(address(1)), 10);
        assertEq(bufferedVault.balanceOf(address(bufferedVault)), 0);
    }

    function testFeeOnSmallLoss() public {
        bufferedVault.setProtocolFee(MAX_BPS / 20);

        _depositToVault(300);
        _dropToVault(100);
        bufferedVault.updateHoldingsState();

        _takeFromVault(80);
        bufferedVault.updateHoldingsState();

        assertEq(bufferedVault.balanceOf(address(1)), 5);
        assertEq(bufferedVault.balanceOf(address(bufferedVault)), 95 - 80);

        vm.warp(STARTING_TIMESTAMP + 20 days);
        assertEq(bufferedVault.balanceOf(address(1)), 5);
        assertEq(bufferedVault.balanceOf(address(bufferedVault)), 0);
    }

    function testFeeOnLargeLoss() public {
        bufferedVault.setProtocolFee(MAX_BPS / 2);

        _depositToVault(300);
        _dropToVault(100);
        bufferedVault.updateHoldingsState();

        _takeFromVault(150);
        bufferedVault.updateHoldingsState();

        assertEq(bufferedVault.balanceOf(address(1)), 50);
        assertEq(bufferedVault.balanceOf(address(bufferedVault)), 0);
        assertEq(bufferedVault.totalSupply(), 350);
        assertEq(bufferedVault.maxWithdraw(alice), 214);
    }

    function testFeeWithBufferEnd() public {
        bufferedVault.setProtocolFee(MAX_BPS / 2);

        _dropToVault(250);
        bufferedVault.updateHoldingsState();

        vm.warp(STARTING_TIMESTAMP + 4 days);

        assertEq(bufferedVault.balanceOf(address(bufferedVault)), 100);

        _dropToVault(500);

        bufferedVault.updateHoldingsState();
        assertEq(bufferedVault.balanceOf(address(bufferedVault)), 100 + 225, "buffer");
        assertEq(bufferedVault.balanceOf(address(1)), 125 + 225, "feeReceiver");
        assertEq(
            bufferedVault.currentBufferEnd(),
            STARTING_TIMESTAMP + 4 days + uint256((16 days * 100 + 20 days * 225)) / (100 + 225),
            "bufferEnd"
        );

        vm.warp(STARTING_TIMESTAMP + 24 days);

        assertEq(bufferedVault.balanceOf(address(bufferedVault)), 0, "no shares in buffer at the end");
    }

    function testBufferEndFirstUpdate() public {
        _depositToVault(1);
        _dropToVault(90);
        bufferedVault.updateHoldingsState();
        assertEq(bufferedVault.currentBufferEnd(), STARTING_TIMESTAMP + 20 days);
    }

    function testBufferEndSecondUpdateOldActive() public {
        _depositToVault(10);
        _dropToVault(10);
        bufferedVault.updateHoldingsState();
        vm.warp(STARTING_TIMESTAMP + 4 days);
        _dropToVault(20);
        bufferedVault.updateHoldingsState();
        assertEq(bufferedVault.balanceOf(address(bufferedVault)), 8 + 18);
        assertEq(
            bufferedVault.currentBufferEnd(), STARTING_TIMESTAMP + 4 days + uint256((16 days * 8 + 20 days * 18)) / 26
        );
    }

    function testBufferEndSecondUpdateElapsed() public {
        _depositToVault(10);
        _dropToVault(10);
        bufferedVault.updateHoldingsState();
        vm.warp(STARTING_TIMESTAMP + 40 days);
        _dropToVault(20);
        bufferedVault.updateHoldingsState();

        assertEq(bufferedVault.currentBufferEnd(), STARTING_TIMESTAMP + 40 days + 20 days);
    }

    function testBigNumbers() public {
        _depositToVault((1 << 5) - 1); // minus 1 to account for virtual asset and shares
        _takeFromVault(1 << 4);
        bufferedVault.updateHoldingsState();

        uint256 startingShares = bufferedVault.totalSupply();
        assertEq(bufferedVault.convertToAssets(2000), 1000);

        _dropToVault(1 << 125);
        bufferedVault.updateHoldingsState();

        uint256 sharesMinted = bufferedVault.totalSupply() - startingShares;
        assertEq(sharesMinted, 1 << 126);
    }

    function testShareTransferDoesntAffectBuffer() public {
        _depositToVault(10);
        _dropToVault(10);
        bufferedVault.updateHoldingsState();

        vm.warp(STARTING_TIMESTAMP + 4 days);
        vm.prank(alice);
        bufferedVault.transfer(address(bufferedVault), 5);
        bufferedVault.updateHoldingsState();

        assertEq(bufferedVault.balanceOf(alice), 5);
        assertEq(bufferedVault.balanceOf(address(bufferedVault)), 13);

        vm.warp(STARTING_TIMESTAMP + 20 days);
        assertEq(bufferedVault.balanceOf(alice), 5);
        assertEq(bufferedVault.balanceOf(address(bufferedVault)), 5);

        vm.warp(STARTING_TIMESTAMP + 100 days);
        assertEq(bufferedVault.balanceOf(alice), 5);
        assertEq(bufferedVault.balanceOf(address(bufferedVault)), 5);
    }

    function testProtocolFeeSetters() public {
        assertEq(bufferedVault.getProtocolFee(), 0);
        assertEq(bufferedVault.getProtocolFeeReceiver(), address(1));

        vm.expectRevert(IERC4626Buffered.IncorrectProtocolFee.selector);
        bufferedVault.setProtocolFee(MAX_BPS + 1);

        bufferedVault.setProtocolFee(0);
        assertEq(bufferedVault.getProtocolFee(), 0);
        bufferedVault.setProtocolFee(MAX_BPS);
        assertEq(bufferedVault.getProtocolFee(), MAX_BPS);

        vm.expectRevert(IERC4626Buffered.ZeroProtocolFeeReceiver.selector);
        bufferedVault.setProtocolFeeReceiver(address(0));

        bufferedVault.setProtocolFeeReceiver(alice);
        assertEq(bufferedVault.getProtocolFeeReceiver(), alice);
    }

    function testWithdrawSpendAllowance() public {
        _depositToVault(100);

        vm.prank(alice);
        bufferedVault.approve(bob, 50);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 50, 51));
        bufferedVault.withdraw(51, bob, alice);

        vm.prank(bob);
        bufferedVault.withdraw(49, bob, alice);

        vm.prank(bob);
        bufferedVault.withdraw(1, alice, alice);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        bufferedVault.withdraw(1, bob, alice);

        assertEq(asset.balanceOf(bob), 49);
        assertEq(asset.balanceOf(alice), 1);
        assertEq(bufferedVault.balanceOf(alice), 50);
    }

    function testMaxRedeemProtocolFeeReceiverWithHoldingsStateUpdate() public {
        bufferedVault.setProtocolFee(MAX_BPS / 10);
        bufferedVault.setProtocolFeeReceiver(alice);

        uint256 initialDeposit = 10 ** 6;

        _depositToVault(initialDeposit);
        uint256 initialShares = bufferedVault.totalSupply();

        assertEq(bufferedVault.maxRedeem(alice), initialShares, "maxRedeem #0");
        assertEq(bufferedVault.maxWithdraw(alice), initialDeposit, "maxWithdraw #0");

        _dropToVault(initialDeposit);
        bufferedVault.updateHoldingsState();

        assertEq(bufferedVault.maxRedeem(alice), initialShares * 11 / 10, "maxRedeem #1");
        assertEq(bufferedVault.maxWithdraw(alice), initialDeposit * 11 / 10, "maxWithdraw #1");

        vm.warp(STARTING_TIMESTAMP + 10 days);
        assertEq(bufferedVault.maxRedeem(alice), initialShares * 11 / 10, "maxRedeem #2");
        assertEq(bufferedVault.totalSupply(), initialShares * 11 / 10 + initialShares * 9 / 20, "totalSupply #2");
        assertEq(
            bufferedVault.maxWithdraw(alice),
            bufferedVault.convertToAssets(bufferedVault.maxRedeem(alice)),
            "maxWithdraw #2"
        );

        uint256 expectedAssetsWithdrawn = bufferedVault.maxWithdraw(alice);
        uint256 maxRedeem = bufferedVault.maxRedeem(alice);

        vm.prank(alice);
        uint256 callResult = bufferedVault.redeem(maxRedeem, alice, alice);

        assertEq(bufferedVault.balanceOf(alice), 0, "alice shares");
        assertEq(callResult, expectedAssetsWithdrawn, "call result");
        assertEq(asset.balanceOf(alice), expectedAssetsWithdrawn, "alice assets");
    }

    function testMaxRedeemUnderestimatesForProtocolFeeReceiver() public {
        bufferedVault.setProtocolFee(MAX_BPS / 10);
        bufferedVault.setProtocolFeeReceiver(alice);

        uint256 initialDeposit = 10 ** 6;

        _depositToVault(initialDeposit);

        _dropToVault(initialDeposit);

        uint256 sharesBefore = bufferedVault.balanceOf(alice);

        assertEq(bufferedVault.maxRedeem(alice), sharesBefore);
        vm.prank(alice);
        uint256 assetsWithdrawn = bufferedVault.redeem(sharesBefore * 11 / 10, alice, alice);

        assertEq(assetsWithdrawn, initialDeposit * 11 / 10);
        assertEq(asset.balanceOf(alice), initialDeposit * 11 / 10);
    }

    function testMintProtocolFeeReceiver() public {
        bufferedVault.setProtocolFee(MAX_BPS / 10);
        bufferedVault.setProtocolFeeReceiver(alice);

        asset.mint(alice, 10 ** 6);
        vm.prank(alice);
        asset.approve(address(bufferedVault), 10 ** 6);

        _dropToVault(10 ** 6);

        uint256 offset = (bufferedVault.decimals() / asset.decimals());

        vm.prank(alice);
        bufferedVault.mint(10 ** 6 * offset, alice);
        assertEq(bufferedVault.balanceOf(alice), 10 ** 6 * offset * 11 / 10);
    }

    uint256 constant UPDATE_NUM = 10;

    function testFuzz_BufferEndIsNeverLowerThanLastUpdate(
        uint120[UPDATE_NUM] calldata _timeElapsed,
        uint120[UPDATE_NUM] calldata _gain
    ) public {
        uint256 _currentTime = STARTING_TIMESTAMP;

        _depositToVault(STARTING_BALANCE);
        for (uint256 i = 0; i < UPDATE_NUM; ++i) {
            _currentTime += _timeElapsed[i];
            vm.warp(_currentTime);

            _dropToVault(_gain[i]);
            bufferedVault.updateHoldingsState();

            assertEq(bufferedVault.lastUpdate(), _currentTime);
            assertLe(bufferedVault.lastUpdate(), bufferedVault.currentBufferEnd());
        }
    }

    function testFuzz_MonotonicPricePerShare(
        uint120[UPDATE_NUM] calldata _timeElapsed,
        uint120[UPDATE_NUM] calldata _gain
    ) public {
        uint256 _currentTime = STARTING_TIMESTAMP;
        _depositToVault(STARTING_BALANCE);

        for (uint256 i = 0; i < UPDATE_NUM; ++i) {
            uint256 pricePerShare1 = bufferedVault.convertToAssets(1);
            _currentTime += _timeElapsed[i];

            vm.warp(_currentTime);
            uint256 pricePerShare2 = bufferedVault.convertToAssets(1);
            _dropToVault(_gain[i]);
            bufferedVault.updateHoldingsState();

            assertLe(pricePerShare1, pricePerShare2);
            assertLe(pricePerShare2, bufferedVault.convertToAssets(1));
        }
    }

    function testFuzz_twoStepHoldingUpdateIsSameAsOneStep(
        uint120[UPDATE_NUM] calldata _timeElapsed,
        uint120[UPDATE_NUM] calldata _gain,
        uint120[UPDATE_NUM] calldata _loss
    ) public {
        uint256 _currentTime = STARTING_TIMESTAMP;
        _depositToVault(STARTING_BALANCE);

        for (uint256 i = 0; i < UPDATE_NUM; ++i) {
            _currentTime += _timeElapsed[i];

            // one-step update
            vm.warp(_currentTime);
            _dropToVault(_gain[i]);
            uint256 loss = bound(_loss[i], 0, asset.balanceOf(address(bufferedVault)));
            _takeFromVault(loss);

            (uint256 newTotalAssetsOneStep, uint256 newTotalSharesOneStep) = bufferedVault.previewUpdateHoldingsState();

            // rollback
            asset.mint(address(bufferedVault), loss);
            asset.burn(address(bufferedVault), _gain[i]);

            // two-step update
            bufferedVault.updateHoldingsState();
            _dropToVault(_gain[i]);
            _takeFromVault(loss);
            bufferedVault.updateHoldingsState();

            assertEq(bufferedVault.totalAssets(), newTotalAssetsOneStep);
            assertEq(bufferedVault.totalSupply(), newTotalSharesOneStep);
        }
    }

    function testFuzz_BigValues(
        uint120[UPDATE_NUM] calldata _timeElapsed,
        uint128[UPDATE_NUM] calldata _gain,
        uint120 _offset
    ) public {
        uint256 offset = bound(_offset, 1, type(uint128).max);
        uint256 _totalGain = 0;
        for (uint256 i = 0; i < UPDATE_NUM; ++i) {
            _totalGain += _gain[i];
        }

        uint256 _currentTime = STARTING_TIMESTAMP;

        _depositToVault(offset);
        _takeFromVault(offset - 1);

        for (uint256 i = 0; i < UPDATE_NUM; ++i) {
            _currentTime += _timeElapsed[i];
            vm.warp(_currentTime);

            _dropToVault(_gain[i]);
            bufferedVault.updateHoldingsState();
        }
    }

    function testFuzz_WithUserActions(
        uint120[UPDATE_NUM] calldata _timeElapsed,
        uint120[UPDATE_NUM] calldata _gain,
        uint120[UPDATE_NUM] calldata _deposit,
        uint120[UPDATE_NUM] calldata _withdraw
    ) public {
        uint256 _currentTime = STARTING_TIMESTAMP;

        _depositToVault(STARTING_BALANCE);
        uint256 _totalAssets = STARTING_BALANCE;

        for (uint256 i = 0; i < UPDATE_NUM; ++i) {
            _currentTime += _timeElapsed[i];
            vm.warp(_currentTime);

            _dropToVault(_gain[i]);
            _depositToVault(_deposit[i]);

            uint256 toWithdraw = bound(_withdraw[i], 0, bufferedVault.maxWithdraw(alice));

            vm.prank(alice);
            bufferedVault.withdraw(toWithdraw, alice, alice);

            _totalAssets += _gain[i];
            _totalAssets += _deposit[i];
            _totalAssets -= toWithdraw;
        }
        _currentTime += 20 days;
        vm.warp(_currentTime);
        bufferedVault.updateHoldingsState();

        uint256 oneSharePrice = bufferedVault.convertToAssets(1) + 1;
        assertEq(bufferedVault.totalAssets(), _totalAssets, "totalAssets");
        assertLe(bufferedVault.totalAssets(), bufferedVault.maxWithdraw(alice) + oneSharePrice, "maxWithdraw");
    }

    function testFuzz_TotalSupply(
        uint120[UPDATE_NUM] calldata _timeElapsed,
        uint120[UPDATE_NUM] calldata _gain,
        uint120[UPDATE_NUM] calldata _loss
    ) public {
        uint256 _currentTime = STARTING_TIMESTAMP;
        _depositToVault(STARTING_BALANCE);

        for (uint256 i = 0; i < UPDATE_NUM; ++i) {
            _currentTime += _timeElapsed[i];
            vm.warp(_currentTime);

            uint256 newTotalAssets = bufferedVault.totalAssets();
            uint256 newTotalShares = bufferedVault.totalSupply();
            uint256 newBufferShares = bufferedVault.balanceOf(address(bufferedVault));

            (, uint256 previewNewTotalShares) = bufferedVault.previewUpdateHoldingsState();
            assertEq(newTotalShares, previewNewTotalShares, "previewUpdateHoldingsState");

            bufferedVault.updateHoldingsState();

            assertEq(bufferedVault.totalAssets(), newTotalAssets, "totalAssets");
            assertEq(bufferedVault.totalSupply(), newTotalShares, "totalSupply");
            assertEq(bufferedVault.balanceOf(address(bufferedVault)), newBufferShares, "buffer shares");

            _dropToVault(_gain[i]);
            uint256 loss = bound(_loss[i], 0, bufferedVault.totalAssets());
            _takeFromVault(loss);
            bufferedVault.updateHoldingsState();
        }
    }

    function testFuzz_PreviewBufferUpdate(
        uint120[UPDATE_NUM] calldata _timeElapsed,
        uint120[UPDATE_NUM] calldata _gain,
        uint120[UPDATE_NUM] calldata _loss
    ) public {
        uint256 _currentTime = STARTING_TIMESTAMP;
        _depositToVault(STARTING_BALANCE);

        for (uint256 i = 0; i < UPDATE_NUM; ++i) {
            _currentTime += _timeElapsed[i];
            vm.warp(_currentTime);

            _dropToVault(_gain[i]);
            uint256 loss = bound(_loss[i], 0, asset.balanceOf(address(bufferedVault)));
            _takeFromVault(loss);

            (uint256 newTotalAssets, uint256 newTotalShares) = bufferedVault.previewUpdateHoldingsState();
            bufferedVault.updateHoldingsState();
            assertEq(bufferedVault.totalAssets(), newTotalAssets);
            assertEq(bufferedVault.totalSupply(), newTotalShares);
        }
    }

    function _dropToVault(uint256 amount) private {
        asset.mint(address(bufferedVault), amount);
    }

    function _takeFromVault(uint256 amount) private {
        asset.burn(address(bufferedVault), amount);
    }

    function _depositToVault(uint256 amount) private {
        vm.startPrank(alice);
        asset.mint(alice, amount);
        asset.approve(address(bufferedVault), amount);
        bufferedVault.deposit(amount, alice);
        vm.stopPrank();
    }
}
