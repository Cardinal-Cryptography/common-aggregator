// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title Buffer structure implementation for gradual reward release.
/// Intended for usage within ERC-4626 vault implementations.
library RewardBuffer {
    using Math for uint256;

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

    function _newBuffer(uint256 _initialAssets) internal view returns (Buffer memory buffer) {
        require(_initialAssets != 0, "Buffer cannot have 0 assets cached.");
        return Buffer(_initialAssets, 0, block.timestamp, block.timestamp);
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
    function _updateBuffer(Buffer storage _buffer, uint256 _totalAssets, uint256 _totalShares)
        internal
        returns (uint256 sharesToMint, uint256 sharesToBurn)
    {
        require(_buffer.assetsCached != 0, "Buffer cannot have 0 assets cached.");

        // -- Rewards unlock --

        sharesToBurn = _sharesToRelease(_buffer);
        _buffer.bufferedShares = _checkedSub(_buffer.bufferedShares, sharesToBurn, 1);
        _buffer.lastUpdate = block.timestamp;
        _buffer.currentBufferEnd = _buffer.currentBufferEnd.max(block.timestamp);

        // -- Buffer update (new rewards/loss) --

        if (_buffer.assetsCached <= _totalAssets) {
            (sharesToMint, _buffer.currentBufferEnd) = _handleGain(_buffer, _totalShares, _totalAssets);
            _buffer.bufferedShares = _checkedAdd(_buffer.bufferedShares, sharesToMint, 2);
        } else {
            uint256 _lossInShares = _handleLoss(_buffer, _totalShares, _totalAssets);
            sharesToBurn = _checkedAdd(sharesToBurn, _lossInShares, 3);
            _buffer.bufferedShares = _checkedSub(_buffer.bufferedShares, _lossInShares, 4);
        }

        uint256 _cancelledOut = sharesToBurn.min(sharesToMint);
        sharesToBurn = _checkedSub(sharesToBurn, _cancelledOut, 5);
        sharesToMint = _checkedSub(sharesToMint, _cancelledOut, 6);

        _buffer.assetsCached = _totalAssets;
    }

    /// @dev Number of shares that should be burned to account for rewards to be released by the buffer.
    /// Use it to implement `totalSupply()`.
    function _sharesToRelease(Buffer storage _buffer) internal view returns (uint256 sharesReleased) {
        uint256 _now = block.timestamp;
        uint256 _start = _buffer.lastUpdate;
        uint256 _end = _buffer.currentBufferEnd;
        uint256 _bufferedShares = _buffer.bufferedShares;

        if (_end == _start || _now == _start) {
            return 0;
        }

        uint256 _duration = _checkedSub(_end, _start, 7);
        uint256 _elapsed = _checkedSub(_now, _start, 8);

        if (_elapsed >= _duration) {
            sharesReleased = _bufferedShares;
        } else {
            sharesReleased = _bufferedShares.mulDiv(_elapsed, _duration);
        }
    }

    function _handleGain(Buffer storage _buffer, uint256 _totalShares, uint256 _totalAssets)
        private
        view
        returns (uint256 sharesToMint, uint256 newBufferEnd)
    {
        uint256 _gain = _checkedSub(_totalAssets, _buffer.assetsCached, 9);
        sharesToMint = _gain.mulDiv(_totalShares, _buffer.assetsCached);

        if (sharesToMint == 0) {
            return (0, _buffer.currentBufferEnd);
        }

        uint256 _weightedOldEnd = _checkedMul(_buffer.currentBufferEnd, _buffer.bufferedShares, 10);

        uint256 _newUnlockEnd = _checkedAdd(block.timestamp, DEFAULT_BUFFERING_DURATION, 11);
        uint256 _weightedNewEnd = _checkedMul(_newUnlockEnd, sharesToMint, 12);
        uint256 _weightsCombined = _checkedAdd(sharesToMint, _buffer.bufferedShares, 13);

        uint256 _weightedSum = _checkedAdd(_weightedOldEnd, _weightedNewEnd, 14);
        newBufferEnd = _checkedDiv(_weightedSum, _weightsCombined, 15);
    }

    function _handleLoss(Buffer storage _buffer, uint256 _totalShares, uint256 _totalAssets)
        private
        view
        returns (uint256 sharesToBurn)
    {
        uint256 _loss = _checkedSub(_buffer.assetsCached, _totalAssets, 16);
        if (_loss == 0) {
            return 0;
        }

        uint256 _lossInShares = _loss.mulDiv(_totalShares, _buffer.assetsCached);
        sharesToBurn = _lossInShares.min(_buffer.bufferedShares);
    }

    function _checkedAdd(uint256 _a, uint256 _b, uint256 _id) private pure returns (uint256 result) {
        bool _success;
        (_success, result) = _a.tryAdd(_b);
        if (!_success) revert AdditionOverflow(_id);
    }

    function _checkedMul(uint256 _a, uint256 _b, uint256 _id) private pure returns (uint256 result) {
        bool _success;
        (_success, result) = _a.tryMul(_b);
        if (!_success) revert MultiplicationOverflow(_id);
    }

    function _checkedDiv(uint256 _a, uint256 _b, uint256 _id) private pure returns (uint256 result) {
        bool _success;
        (_success, result) = _a.tryDiv(_b);
        if (!_success) revert DivisionByZero(_id);
    }

    function _checkedSub(uint256 _a, uint256 _b, uint256 _id) private pure returns (uint256 result) {
        bool _success;
        (_success, result) = _a.trySub(_b);
        if (!_success) revert SubtractionOverflow(_id);
    }
}
