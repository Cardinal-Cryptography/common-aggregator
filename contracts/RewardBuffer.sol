// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title Buffer structure implementation for gradual reward release.
/// Intended for usage within ERC-4626 vault implementations.
library RewardBuffer {
    using Math for uint256;

    error AssetsCachedIsZero();

    error AdditionOverflow(uint256 id);
    error MultiplicationOverflow(uint256 id);
    error DivisionByZero(uint256 id);
    error SubtractionOverflow(uint256 id);

    uint256 public constant DEFAULT_BUFFERING_DURATION = 20 days;

    /// @dev MUST be initialized with non-zero value of `assetsCached` - vault should send some
    /// assets (together with corresponding shares) to an unreachable address (in the constructor).
    ///
    /// Use `_newBuffer` in order to create new buffer instance.
    struct Buffer {
        uint256 assetsCached;
        uint256 bufferedShares;
        uint256 lastUpdate;
        uint256 currentBufferEnd;
    }

    function _newBuffer(uint256 initialAssets) internal view returns (Buffer memory buffer) {
        if (initialAssets == 0) revert AssetsCachedIsZero();
        return Buffer(initialAssets, 0, block.timestamp, block.timestamp);
    }

    /// @dev Use this to implement `totalAssets()`.
    function _getAssetsCached(Buffer storage buffer) internal view returns (uint256 assets) {
        return buffer.assetsCached;
    }

    /// @dev Updates the buffer based on the current vault's state.
    /// Should be called before any state mutating methods that depend on price-per-share.
    ///
    /// Alternatively (or additionally), it may be called by an off-chain component at times
    /// when difference between `assetsCached` and `totalAssets()` becomes significant.
    function _updateBuffer(Buffer storage buffer, uint256 totalAssets, uint256 totalShares)
        internal
        returns (uint256 sharesToMint, uint256 sharesToBurn)
    {
        if (buffer.assetsCached == 0) revert AssetsCachedIsZero();

        // -- Rewards unlock --

        sharesToBurn = _sharesToRelease(buffer);
        buffer.bufferedShares = _checkedSub(buffer.bufferedShares, sharesToBurn, 1);
        buffer.lastUpdate = block.timestamp;
        buffer.currentBufferEnd = buffer.currentBufferEnd.max(block.timestamp);

        // -- Buffer update (new rewards/loss) --

        if (buffer.assetsCached <= totalAssets) {
            (sharesToMint, buffer.currentBufferEnd) = _handleGain(buffer, totalShares, totalAssets);
            buffer.bufferedShares = _checkedAdd(buffer.bufferedShares, sharesToMint, 2);
        } else {
            uint256 lossInShares = _handleLoss(buffer, totalShares, totalAssets);
            sharesToBurn = _checkedAdd(sharesToBurn, lossInShares, 3);
            buffer.bufferedShares = _checkedSub(buffer.bufferedShares, lossInShares, 4);
        }

        uint256 cancelledOut = sharesToBurn.min(sharesToMint);
        sharesToBurn = _checkedSub(sharesToBurn, cancelledOut, 5);
        sharesToMint = _checkedSub(sharesToMint, cancelledOut, 6);

        buffer.assetsCached = totalAssets;
    }

    /// @dev Number of shares that should be burned to account for rewards to be released by the buffer.
    /// Use it to implement `totalSupply()`.
    function _sharesToRelease(Buffer storage buffer) internal view returns (uint256 sharesReleased) {
        uint256 timestampNow = block.timestamp;
        uint256 start = buffer.lastUpdate;
        uint256 end = buffer.currentBufferEnd;
        uint256 bufferedShares = buffer.bufferedShares;

        if (end == start || timestampNow == start) {
            return 0;
        }

        uint256 duration = _checkedSub(end, start, 7);
        uint256 elapsed = _checkedSub(timestampNow, start, 8);

        if (elapsed >= duration) {
            sharesReleased = bufferedShares;
        } else {
            sharesReleased = bufferedShares.mulDiv(elapsed, duration);
        }
    }

    function _handleGain(Buffer storage buffer, uint256 totalShares, uint256 totalAssets)
        private
        view
        returns (uint256 sharesToMint, uint256 newBufferEnd)
    {
        uint256 gain = _checkedSub(totalAssets, buffer.assetsCached, 9);
        sharesToMint = gain.mulDiv(totalShares, buffer.assetsCached);

        if (sharesToMint == 0) {
            return (0, buffer.currentBufferEnd);
        }

        uint256 newUnlockEnd = _checkedAdd(block.timestamp, DEFAULT_BUFFERING_DURATION, 10);
        newBufferEnd = _weightedAvg(buffer.currentBufferEnd, buffer.bufferedShares, newUnlockEnd, sharesToMint);
    }

    function _handleLoss(Buffer storage buffer, uint256 totalShares, uint256 totalAssets)
        private
        view
        returns (uint256 sharesToBurn)
    {
        uint256 loss = _checkedSub(buffer.assetsCached, totalAssets, 11);
        if (loss == 0) {
            return 0;
        }

        uint256 lossInShares = loss.mulDiv(totalShares, buffer.assetsCached, Math.Rounding.Ceil);

        // If we need to burn more than `buffer.bufferedShares` shares to retain price-per-share,
        // then it's impossible to cover that from the buffer, and sharp PPS drop is to be expected.
        sharesToBurn = lossInShares.min(buffer.bufferedShares);
    }

    function _weightedAvg(uint256 v1, uint256 w1, uint256 v2, uint256 w2) private pure returns (uint256 result) {
        uint256 weightedVal1 = _checkedMul(w1, v1, 12);
        uint256 weightedVal2 = _checkedMul(w2, v2, 13);

        uint256 weightedSum = _checkedAdd(weightedVal1, weightedVal2, 14);
        uint256 weightSum = _checkedAdd(w1, w2, 15);

        result = _checkedDiv(weightedSum, weightSum, 16);
    }

    function _checkedAdd(uint256 a, uint256 b, uint256 id) private pure returns (uint256 result) {
        bool success;
        (success, result) = a.tryAdd(b);
        if (!success) revert AdditionOverflow(id);
    }

    function _checkedMul(uint256 a, uint256 b, uint256 id) private pure returns (uint256 result) {
        bool success;
        (success, result) = a.tryMul(b);
        if (!success) revert MultiplicationOverflow(id);
    }

    function _checkedDiv(uint256 a, uint256 b, uint256 id) private pure returns (uint256 result) {
        bool success;
        (success, result) = a.tryDiv(b);
        if (!success) revert DivisionByZero(id);
    }

    function _checkedSub(uint256 a, uint256 b, uint256 id) private pure returns (uint256 result) {
        bool success;
        (success, result) = a.trySub(b);
        if (!success) revert SubtractionOverflow(id);
    }
}
