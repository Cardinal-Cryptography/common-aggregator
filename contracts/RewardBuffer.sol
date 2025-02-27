// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {checkedAdd, checkedDiv, checkedMul, checkedSub, MAX_BPS, weightedAvg} from "./Math.sol";

/// @dev Id for checked function identification
uint256 constant FILE_ID = uint256(keccak256("RewardBuffer"));

/// @title Buffer structure implementation for gradual reward release.
/// Intended for usage within ERC-4626 vault implementations.
library RewardBuffer {
    using Math for uint256;

    error AssetsCachedIsZero();

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
    /// Out of these shares, `sharesToMint.mulDiv(feeBps, 10_000, Math.Rounding.Ceil)` should be minted to
    /// the fee receiver, and the rest to the aggergator.
    /// @return sharesToBurn Amount of shares to burn to account for rewards that have been released.
    function _updateBuffer(Buffer storage buffer, uint256 totalAssets, uint256 totalShares, uint256 feeBps)
        internal
        returns (uint256 sharesToMint, uint256 sharesToBurn)
    {
        Buffer memory memBuf = _toMemory(buffer);
        (sharesToMint, sharesToBurn) = __updateBuffer(memBuf, totalAssets, totalShares, feeBps);
        _toStorage(memBuf, buffer);
    }

    /// @dev Simulates buffer update.
    function _simulateBufferUpdate(Buffer storage buffer, uint256 totalAssets, uint256 totalShares, uint256 feeBps)
        internal
        view
        returns (uint256 sharesToMint, uint256 sharesToBurn)
    {
        Buffer memory updatedBuffer = _toMemory(buffer);
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
        buffer.bufferedShares = checkedSub(buffer.bufferedShares, sharesToBurn, FILE_ID, 1);
        buffer.lastUpdate = block.timestamp;
        buffer.currentBufferEnd = buffer.currentBufferEnd.max(block.timestamp);

        // -- Buffer update (new rewards/loss) --

        if (buffer.assetsCached <= totalAssets) {
            (sharesToMint, buffer.currentBufferEnd) = _handleGain(buffer, totalShares, totalAssets);
            buffer.bufferedShares = checkedAdd(buffer.bufferedShares, sharesToMint, FILE_ID, 2);
        } else {
            uint256 lossInShares = _handleLoss(buffer, totalShares, totalAssets);
            sharesToBurn = checkedAdd(sharesToBurn, lossInShares, FILE_ID, 3);
            buffer.bufferedShares = checkedSub(buffer.bufferedShares, lossInShares, FILE_ID, 4);
        }

        uint256 cancelledOut = sharesToBurn.min(sharesToMint);
        sharesToBurn = checkedSub(sharesToBurn, cancelledOut, FILE_ID, 5);
        sharesToMint = checkedSub(sharesToMint, cancelledOut, FILE_ID, 6);
        if (sharesToMint > 0) {
            buffer.bufferedShares -= sharesToMint.mulDiv(feeBps, MAX_BPS, Math.Rounding.Ceil);
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

        uint256 duration = checkedSub(end, start, FILE_ID, 7);
        uint256 elapsed = checkedSub(timestampNow, start, FILE_ID, 8);

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
        uint256 gain = checkedSub(totalAssets, buffer.assetsCached, FILE_ID, 9);
        sharesToMint = gain.mulDiv(totalShares, buffer.assetsCached);

        if (sharesToMint == 0) {
            return (0, buffer.currentBufferEnd);
        }

        uint256 newUnlockEnd = checkedAdd(block.timestamp, DEFAULT_BUFFERING_DURATION, FILE_ID, 10);
        newBufferEnd = weightedAvg(buffer.currentBufferEnd, buffer.bufferedShares, newUnlockEnd, sharesToMint);
    }

    function _handleLoss(Buffer memory buffer, uint256 totalShares, uint256 totalAssets)
        private
        pure
        returns (uint256 sharesToBurn)
    {
        uint256 loss = checkedSub(buffer.assetsCached, totalAssets, FILE_ID, 11);
        if (loss == 0) {
            return 0;
        }

        uint256 lossInShares = loss.mulDiv(totalShares, buffer.assetsCached, Math.Rounding.Ceil);

        // If we need to burn more than `buffer.bufferedShares` shares to retain price-per-share,
        // then it's impossible to cover that from the buffer, and sharp PPS drop is to be expected.
        sharesToBurn = lossInShares.min(buffer.bufferedShares);
    }
}
