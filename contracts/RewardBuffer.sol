// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title Buffer structure implementation for gradual reward release.
/// Intended for usage within ERC-4626 vault implementations.
library RewardBuffer {
    using Math for uint256;

    uint256 public constant DEFAULT_BUFFERING_DURATION = 20 days;

    /// @dev This omits info about buffered shares as, for an ERC-4626 contract, we can use
    /// `balanceOf(address(this))` instead - this will also distribute "airdroped" shares of `this`.
    struct Buffer {
        uint256 assetsCached;
        uint256 lastUpdate;
        uint256 currentBufferEnd;
    }

    /// @dev Use this to implement `totalAssets()`.
    function _getAssetsCache(Buffer storage _buffer) internal view returns (uint256 assets) {
        return _buffer.assetsCached;
    }

    /// @dev Updates the buffer based on the current vault's state.
    /// Should be called before any state mutating methods that depend on price-per-share.
    ///
    /// Alternatively (or additionally), it may be called by an off-chain component at times
    /// when difference between `assetsCached` and `totalAssets()` becomes significant.
    function _updateBuffer(
        Buffer storage _buffer,
        uint256 _totalAssets,
        uint256 _bufferedShares,
        uint256 _totalShares
    ) internal returns (uint256 sharesToMint, uint256 sharesToBurn) {
        sharesToBurn = _sharesToRelease(_buffer, _bufferedShares);
        _bufferedShares -= sharesToBurn;

        if (_buffer.assetsCached <= _totalAssets) {
            sharesToMint = _handleGain(_buffer, _bufferedShares, _totalShares, _totalAssets);
        } else {
            sharesToBurn += _handleLoss(_buffer, _bufferedShares, _totalShares, _totalAssets);
        }

        _buffer.assetsCached = _totalAssets;
        _buffer.lastUpdate = block.timestamp;
    }

    /// @dev Number of shares that should be burned to account for rewards to be released by the buffer.
    /// Use it to implement `totalSupply()`.
    function _sharesToRelease(
        Buffer storage _buffer,
        uint256 _bufferedShares
    ) internal view returns (uint256 sharesReleased) {
        uint256 _now = block.timestamp;
        uint256 _start = _buffer.lastUpdate;
        uint256 _end = _buffer.currentBufferEnd;

        if (_end == _start || _now == _start) {
            return 0;
        }

        uint256 _duration = _end - _start;
        uint256 _elapsed = _now - _start;

        if (_elapsed >= _duration) {
            sharesReleased = _bufferedShares;
        } else {
            sharesReleased = _bufferedShares.mulDiv(_elapsed, _duration);
        }
    }

    function _handleGain(
        Buffer storage _buffer,
        uint256 _bufferedShares,
        uint256 _totalShares,
        uint256 _totalAssets
    ) private returns (uint256 sharesToMint) {
        uint256 _gain = _totalAssets - _buffer.assetsCached;
        sharesToMint = _gain.mulDiv(_totalShares, _buffer.assetsCached);

        uint256 _weightedOldEnd = _buffer.currentBufferEnd * _bufferedShares;
        uint256 _weightedNewEnd = (block.timestamp + DEFAULT_BUFFERING_DURATION) * sharesToMint;
        uint256 _weightsCombined = sharesToMint + _bufferedShares;

        _buffer.currentBufferEnd = (_weightedOldEnd + _weightedNewEnd) / _weightsCombined;
    }

    function _handleLoss(
        Buffer storage _buffer,
        uint256 _bufferedShares,
        uint256 _totalShares,
        uint256 _totalAssets
    ) private returns (uint256 sharesToBurn) {
        uint256 _loss = _buffer.assetsCached - _totalAssets;
        uint256 _lossInShares = _loss.mulDiv(_totalShares, _buffer.assetsCached);
        sharesToBurn = _lossInShares.min(_bufferedShares);

        _buffer.currentBufferEnd = _buffer.currentBufferEnd.max(block.timestamp);
    }
}
