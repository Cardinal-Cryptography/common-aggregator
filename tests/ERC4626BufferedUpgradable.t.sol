// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC4626BufferedUpgradeable} from "../contracts/ERC4626BufferedUpgradeable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MAX_BPS} from "../contracts/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ERC20Mock} from "tests/mock/ERC20Mock.sol";

contract ERC4626BufferedUpgradeableConcrete is ERC4626BufferedUpgradeable {
    constructor() {
        _disableInitializers();
    }

    function initialize(IERC20 _asset, address protocolFeeReceiver) public initializer {
        __ERC4626Buffered_init(_asset, protocolFeeReceiver);
    }
}

contract ERC4626BufferedUpgradeableTest is Test {
    using Math for uint256;

    uint256 constant STARTING_TIMESTAMP = 100;
    uint256 constant STARTING_BALANCE = 10;

    ERC4626BufferedUpgradeable bufferedVault;
    ERC20Mock asset = new ERC20Mock();

    address alice = address(0x456);
    address bob = address(0x678);

    function setUp() public {
        vm.warp(STARTING_TIMESTAMP);
        ERC4626BufferedUpgradeable implementation = new ERC4626BufferedUpgradeableConcrete();

        bytes memory initializeData =
            abi.encodeWithSelector(ERC4626BufferedUpgradeableConcrete.initialize.selector, asset, bob);

        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initializeData);
        bufferedVault = ERC4626BufferedUpgradeable(address(proxy));
    }

    function testAssetsAfterInit() public view {
        assertEq(bufferedVault.totalAssets(), 0);
    }

    function testAssetsAfterDropAndBufferUpdate() public {
        _dropToVault(100);
        bufferedVault.updateHoldingsState();
        assertEq(bufferedVault.totalAssets(), 0);
    }

    function testCachedAssetsAfterBufferUpdateAndTimeElapsed() public {
        // TODO: remove this when we have impl using virtual shares
        _depositToVault(1);
        _dropToVault(20);
        bufferedVault.updateHoldingsState();
        vm.warp(STARTING_TIMESTAMP + 10 days);
        assertEq(bufferedVault.totalAssets(), 21);
    }

    function testSharesBurntAfterBufferUpdate() public {
        _depositToVault(1);
        _dropToVault(20);
        bufferedVault.updateHoldingsState();
        assertEq(bufferedVault.totalSupply(), 21);
    }

    function testSharesBurntAfterBufferUpdateAndTimeElapsed() public {
        _depositToVault(1);
        _dropToVault(20);
        bufferedVault.updateHoldingsState();
        vm.warp(STARTING_TIMESTAMP + 2 days);
        assertEq(bufferedVault.totalSupply(), 19);
    }

    function testSharesBurntAfterBufferUpdateAndTimeElapsed2() public {
        _depositToVault(10);
        _dropToVault(7);
        bufferedVault.updateHoldingsState();
        vm.warp(STARTING_TIMESTAMP + 7 days);
        assertEq(bufferedVault.totalSupply(), 15);
    }

    function testSharesBurntAfterFullPeriodHasPassed() public {
        _depositToVault(5);
        _dropToVault(10);
        bufferedVault.updateHoldingsState();
        vm.warp(STARTING_TIMESTAMP + 20 days);
        assertEq(bufferedVault.totalSupply(), 5);
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

    // function testFeeOnGain() public {
    //     (uint256 _toMint,) = buffer._updateBuffer(12, 100, MAX_BPS / 10);
    //     assertEq(_toMint, 20);

    //     uint256 mintedMinusFee = 18;

    //     vm.warp(STARTING_TIMESTAMP + 20 days);
    //     (, uint256 _toBurn) = buffer._updateBuffer(12, 100 + mintedMinusFee, MAX_BPS / 10);
    //     assertEq(_toBurn, 18);
    // }

    // function testFeeOnLoss() public {
    //     buffer._updateBuffer(100, 100, MAX_BPS / 10);
    //     (uint256 _toMint, uint256 _toBurn) = buffer._updateBuffer(70, 1000, MAX_BPS / 10);
    //     assertEq(_toMint, 0);
    //     assertEq(_toBurn, 300);
    // }

    /*function testBufferEndFirstUpdate() public {
        buffer._updateBuffer(100, 100, 0);
        assertEq(buffer.currentBufferEnd, STARTING_TIMESTAMP + 20 days);
    }

    function testBufferEndSecondUpdateOldActive() public {
        buffer._updateBuffer(20, 100, 0);
        vm.warp(STARTING_TIMESTAMP + 4 days);
        buffer._updateBuffer(40, 200, 0);

        assertEq(buffer.currentBufferEnd, STARTING_TIMESTAMP + 4 days + uint256((16 days * 2 + 20 days * 5)) / 7);
    }

    function testBufferEndSecondUpdateElapsed() public {
        buffer._updateBuffer(20, 100, 0);
        vm.warp(STARTING_TIMESTAMP + 40 days);
        buffer._updateBuffer(40, 200, 0);

        assertEq(buffer.currentBufferEnd, STARTING_TIMESTAMP + 40 days + 20 days);
    }

    function testBigNumbers() public {
        (uint256 _toMint, uint256 _toBurn) = buffer._updateBuffer(10 + (1 << 120), (1 << 5), 0);
        assertEq(_toMint, uint256(1 << 125) / 10);
        assertEq(_toBurn, 0);
    }

    uint256 constant UPDATE_NUM = 10;

    function testFuzz_BufferEndIsNeverLowerThanLastUpdate(
        uint120[UPDATE_NUM] calldata _timeElapsed,
        uint120[UPDATE_NUM] calldata _gain
    ) public {
        uint256 _currentTime = STARTING_TIMESTAMP;
        uint256 _totalAssets = STARTING_BALANCE;
        uint256 _totalShares = 100;

        for (uint256 i = 0; i < UPDATE_NUM; ++i) {
            _currentTime += _timeElapsed[i];
            vm.warp(_currentTime);

            _totalAssets += _gain[i];
            (uint256 _toMint, uint256 _toBurn) = buffer._updateBuffer(_totalAssets, _totalShares, 0);

            assertLe(_toBurn, _totalShares);

            _totalShares += _toMint;
            _totalShares -= _toBurn;

            assertLe(buffer.lastUpdate, buffer.currentBufferEnd);
        }
    }

    function testFuzz_MonotonicPricePerShare(
        uint120[UPDATE_NUM] calldata _timeElapsed,
        uint120[UPDATE_NUM] calldata _gain
    ) public {
        uint256 _currentTime = STARTING_TIMESTAMP;
        uint256 _totalAssets = STARTING_BALANCE;
        uint256 _totalShares = 100;

        uint256 _lastAssets = _totalAssets;
        uint256 _lastShares = _totalShares;

        for (uint256 i = 0; i < UPDATE_NUM; ++i) {
            _currentTime += _timeElapsed[i];
            vm.warp(_currentTime);

            _totalAssets += _gain[i];
            (uint256 _toMint, uint256 _toBurn) = buffer._updateBuffer(_totalAssets, _totalShares, 0);

            assertLe(_toBurn, _totalShares);

            _totalShares += _toMint;
            _totalShares -= _toBurn;

            assertLe(_lastAssets * _totalShares, _totalAssets * _lastShares);

            _lastAssets = _totalAssets;
            _lastShares = _totalShares;
        }
    }

    function testFuzz_BigValues(
        uint120[UPDATE_NUM] calldata _timeElapsed,
        uint128[UPDATE_NUM] calldata _gain,
        uint120 _offset
    ) public {
        uint256 _totalGain = 0;
        for (uint256 i = 0; i < UPDATE_NUM; ++i) {
            _totalGain += _gain[i];
        }

        vm.assume(_totalGain * _offset < (1 << 128));

        uint256 _currentTime = STARTING_TIMESTAMP;
        uint256 _totalAssets = STARTING_BALANCE;
        uint256 _totalShares = STARTING_BALANCE * _offset;

        for (uint256 i = 0; i < UPDATE_NUM; ++i) {
            _currentTime += _timeElapsed[i];
            vm.warp(_currentTime);

            _totalAssets += _gain[i];
            (uint256 _toMint, uint256 _toBurn) = buffer._updateBuffer(_totalAssets, _totalShares, 0);

            assertLe(_toBurn, _totalShares);

            _totalShares += _toMint;
            _totalShares -= _toBurn;
        }
    }

    function testFuzz_WithUserActions(
        uint120[UPDATE_NUM] calldata _timeElapsed,
        uint120[UPDATE_NUM] calldata _gain,
        uint120[UPDATE_NUM] calldata _deposit,
        uint120[UPDATE_NUM] calldata _withdraw
    ) public {
        uint256 _currentTime = STARTING_TIMESTAMP;
        uint256 _totalAssets = STARTING_BALANCE;
        uint256 _totalShares = 10000;

        for (uint256 i = 0; i < UPDATE_NUM; ++i) {
            _currentTime += _timeElapsed[i];
            vm.warp(_currentTime);

            _totalAssets += _gain[i];
            (uint256 _toMint, uint256 _toBurn) = buffer._updateBuffer(_totalAssets, _totalShares, 0);

            assertLe(_toBurn, _totalShares);

            _totalShares += _toMint;
            _totalShares -= _toBurn;

            uint256 _depositShares = uint256(_deposit[i]).mulDiv(_totalShares, _totalAssets);
            _totalAssets += _deposit[i];
            _totalShares += _depositShares;
            buffer.assetsCached += _deposit[i];

            uint256 _withdrawShares = uint256(_withdraw[i]).mulDiv(_totalShares, _totalAssets);
            vm.assume(_withdrawShares < _totalShares - buffer.bufferedShares);
            _totalAssets -= _withdraw[i];
            _totalShares -= _withdrawShares;
            buffer.assetsCached -= _withdraw[i];
        }
    }*/

    function _dropToVault(uint256 amount) private {
        asset.mint(address(bufferedVault), amount);
    }

    function _depositToVault(uint256 amount) private {
        vm.startPrank(alice);
        asset.mint(alice, amount);
        asset.approve(address(bufferedVault), amount);
        bufferedVault.deposit(amount, alice);
        vm.stopPrank();
    }
}
