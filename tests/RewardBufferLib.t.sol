// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {RewardBuffer} from "../contracts/RewardBuffer.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {console} from "forge-std/console.sol";

contract RewardBufferTest is Test {
    using RewardBuffer for RewardBuffer.Buffer;
    using Math for uint256;

    uint256 constant STARTING_TIMESTAMP = 100;
    uint256 constant STARTING_BALANCE = 10;

    RewardBuffer.Buffer buffer;

    function setUp() public {
        vm.warp(STARTING_TIMESTAMP);
        buffer = RewardBuffer._newBuffer(STARTING_BALANCE);
    }

    function testCachedAssetsAfterInit() public view {
        assertEq(buffer._getAssetsCached(), STARTING_BALANCE);
    }

    function testCachedAssetsAfterBufferUpdate() public {
        buffer._updateBuffer(20, 200);
        assertEq(buffer._getAssetsCached(), 20);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testUpdateRevertsWhenZeroStartingAssets() public {
        buffer.assetsCached = 0;
        vm.expectRevert(RewardBuffer.AssetsCachedIsZero.selector);
        buffer._updateBuffer(20, 1000);
    }

    function testCachedAssetsAfterBufferUpdateAndTimeElapsed() public {
        buffer._updateBuffer(20, 200);
        vm.warp(STARTING_TIMESTAMP + 10 days);
        assertEq(buffer._getAssetsCached(), 20);
    }

    function testSharesReleasedAfterBufferUpdate() public {
        buffer._updateBuffer(20, 100);
        assertEq(buffer._sharesToRelease(), 0);
    }

    function testSharesReleasedAfterBufferUpdateAndTimeElapsed() public {
        buffer._updateBuffer(20, 100);
        vm.warp(STARTING_TIMESTAMP + 2 days);
        assertEq(buffer._sharesToRelease(), 10);
    }

    function testSharesReleasedAfterBufferUpdateAndTimeElapsed2() public {
        buffer._updateBuffer(17, 100);
        vm.warp(STARTING_TIMESTAMP + 7 days);
        assertEq(buffer._sharesToRelease(), 24);
    }

    function testBufferUpdateResultOnGain() public {
        (uint256 _toMint, uint256 _toBurn) = buffer._updateBuffer(12, 100);
        assertEq(_toMint, 20);
        assertEq(_toBurn, 0);
    }

    function testBufferUpdateResultOnLoss() public {
        (uint256 _toMint, uint256 _toBurn) = buffer._updateBuffer(4, 100);
        assertEq(_toMint, 0);
        assertEq(_toBurn, 0);
    }

    function testBufferUpdateResultOnLoss2() public {
        buffer._updateBuffer(100, 100);
        (uint256 _toMint, uint256 _toBurn) = buffer._updateBuffer(70, 1000);
        assertEq(_toMint, 0);
        assertEq(_toBurn, 300);
    }

    function testBufferEndFirstUpdate() public {
        buffer._updateBuffer(100, 100);
        assertEq(buffer.currentBufferEnd, STARTING_TIMESTAMP + 20 days);
    }

    function testBufferEndSecondUpdateOldActive() public {
        buffer._updateBuffer(20, 100);
        vm.warp(STARTING_TIMESTAMP + 4 days);
        buffer._updateBuffer(40, 200);

        assertEq(buffer.currentBufferEnd, STARTING_TIMESTAMP + 4 days + uint256((16 days * 2 + 20 days * 5)) / 7);
    }

    function testBufferEndSecondUpdateElapsed() public {
        buffer._updateBuffer(20, 100);
        vm.warp(STARTING_TIMESTAMP + 40 days);
        buffer._updateBuffer(40, 200);

        assertEq(buffer.currentBufferEnd, STARTING_TIMESTAMP + 40 days + 20 days);
    }

    function testBigNumbers() public {
        (uint256 _toMint, uint256 _toBurn) = buffer._updateBuffer(10 + (1 << 120), (1 << 5));
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
            (uint256 _toMint, uint256 _toBurn) = buffer._updateBuffer(_totalAssets, _totalShares);

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
            (uint256 _toMint, uint256 _toBurn) = buffer._updateBuffer(_totalAssets, _totalShares);

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
            (uint256 _toMint, uint256 _toBurn) = buffer._updateBuffer(_totalAssets, _totalShares);

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
            (uint256 _toMint, uint256 _toBurn) = buffer._updateBuffer(_totalAssets, _totalShares);

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
    }
}
