// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {RewardBuffer} from "../contracts/RewardBuffer.sol";

contract RewardBufferTest is Test {
    using RewardBuffer for RewardBuffer.Buffer;

    uint256 constant STARTING_TIMESTAMP = 100;
    uint256 constant STARTING_BALANCE = 10;

    RewardBuffer.Buffer buffer;

    function setUp() public {
        vm.warp(STARTING_TIMESTAMP);
        buffer = RewardBuffer.Buffer(STARTING_BALANCE, 0, STARTING_TIMESTAMP, STARTING_TIMESTAMP);
    }

    function testCachedAssetsAfterInit() public view {
        assertEq(buffer._getAssetsCache(), STARTING_BALANCE);
    }

    function testCachedAssetsAfterBufferUpdate() public {
        buffer._updateBuffer(20, 200);
        assertEq(buffer._getAssetsCache(), 20);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testUpdateRevertsWhenZeroStartingAssets() public {
        buffer.assetsCached = 0;
        vm.expectRevert(bytes("Buffer cannot have 0 assets cached."));
        buffer._updateBuffer(20, 1000);
    }

    function testCachedAssetsAfterBufferUpdateAndTimeElapsed() public {
        buffer._updateBuffer(20, 200);
        vm.warp(STARTING_TIMESTAMP + 10 days);
        assertEq(buffer._getAssetsCache(), 20);
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

        assertEq(buffer.currentBufferEnd, STARTING_TIMESTAMP + 4 days + uint((16 days * 2 + 20 days * 5)) / 7);
    }

    function testBufferEndSecondUpdateElapsed() public {
        buffer._updateBuffer(20, 100);
        vm.warp(STARTING_TIMESTAMP + 40 days);
        buffer._updateBuffer(40, 200);

        assertEq(buffer.currentBufferEnd, STARTING_TIMESTAMP + 40 days + 20 days);
    }

    function testBigNumbers() public {
        (uint256 _toMint, uint256 _toBurn) = buffer._updateBuffer(10 + (1 << 120), (1 << 5));
        assertEq(_toMint, uint(1 << 125) / 10);
        assertEq(_toBurn, 0);
    }
}
