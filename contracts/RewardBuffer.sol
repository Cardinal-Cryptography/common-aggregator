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

    /// @dev Increases the buffer's `assetsCached` field.
    /// Used when deposit or mint has been made to the vault.
    function _increaseAssets(Buffer storage buffer, uint256 assets) internal {
        buffer.assetsCached += assets;
    }

    /// @dev Increases the buffer's `assetsCached` field.
    /// Used when withdrawal or redemption has been made to the vault.
    function _decreaseAssets(Buffer storage buffer, uint256 assets) internal {
        buffer.assetsCached -= assets;
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
    /// @return sharesToMint Amount of shares to mint to account for new rewards, and protocol fee.
    /// (sharesToMint * feeBps).ceilDiv(10000) of these shares should be minted to the protocol fee receiver,
    /// and the rest to the aggergator.
    /// @return sharesToBurn Amount of shares to burn to account for rewards that have been released.
    function _updateBuffer(Buffer storage buffer, uint256 totalAssets, uint256 totalShares, uint256 feeBps)
        internal
        returns (uint256 sharesToMint, uint256 sharesToBurn)
    {
        Buffer memory memBuf = _toMemory(buffer);
        (sharesToMint, sharesToBurn) = __updateBuffer(memBuf, totalAssets, totalShares, feeBps);
        _toStorage(memBuf, buffer);
    }

    /// @dev Simulates buffer update, returning the memory representation of an updated buffer.
    function _simulateBufferUpdate(Buffer storage buffer, uint256 totalAssets, uint256 totalShares, uint256 feeBps)
        internal
        view
        returns (Buffer memory updatedBuffer, uint256 sharesToMint, uint256 sharesToBurn)
    {
        updatedBuffer = _toMemory(buffer);
        (sharesToMint, sharesToBurn) = __updateBuffer(updatedBuffer, totalAssets, totalShares, feeBps);
    }

    /// @dev Creates a `memory` copy of a buffer.
    function _toMemory(Buffer storage buffer) internal view returns (Buffer memory memBuffer) {
        memBuffer.assetsCached = buffer.assetsCached;
        memBuffer.bufferedShares = buffer.bufferedShares;
        memBuffer.lastUpdate = buffer.lastUpdate;
        memBuffer.currentBufferEnd = buffer.currentBufferEnd;
    }

    /// @dev Copies `memory` buffer into storage.
    function _toStorage(Buffer memory buffer, Buffer storage storageBuffer) internal {
        storageBuffer.assetsCached = buffer.assetsCached;
        storageBuffer.bufferedShares = buffer.bufferedShares;
        storageBuffer.lastUpdate = buffer.lastUpdate;
        storageBuffer.currentBufferEnd = buffer.currentBufferEnd;
    }

    function __updateBuffer(Buffer memory buffer, uint256 totalAssets, uint256 totalShares, uint256 feeBps)
        private
        view
        returns (uint256 sharesToMint, uint256 sharesToBurn)
    {
        if (buffer.assetsCached == 0) revert AssetsCachedIsZero();

        // -- Rewards unlock --

        sharesToBurn = _sharesToBurn(buffer);
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
        if (sharesToMint > 0) {
            buffer.bufferedShares -= (sharesToMint * feeBps).ceilDiv(10000);
        }

        buffer.assetsCached = totalAssets;
    }

    /// @dev Number of shares that should be burned to account for rewards to be released by the buffer.
    /// Use it to implement `totalSupply()`.
    function _sharesToBurn(Buffer memory buffer) internal view returns (uint256 sharesReleased) {
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

    function _handleGain(Buffer memory buffer, uint256 totalShares, uint256 totalAssets)
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

    function _handleLoss(Buffer memory buffer, uint256 totalShares, uint256 totalAssets)
        private
        pure
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
        uint256 weightSum = _checkedAdd(w1, w2, 12);

        (uint256 a, uint256 rA) = mulDivWithRest(v1, w1, weightSum);
        (uint256 b, uint256 rB) = mulDivWithRest(v2, w2, weightSum);

        result = _checkedAdd(a, b, 13);

        if (_checkedSub(weightSum, rA, 14) <= rB) {
            result = _checkedAdd(result, 1, 15);
        }
    }

    /// @notice Computes a.mulDiv(b,c) and returns also the remainder.
    function mulDivWithRest(uint256 a, uint256 b, uint256 c) private pure returns (uint256 result, uint256 rest) {
        result = a.mulDiv(b, c);
        unchecked {
            uint256 x = a * b;
            uint256 y = result * c;
            rest = x - y;
        }
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
