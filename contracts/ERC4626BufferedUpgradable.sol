// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {
    IERC20,
    IERC4626,
    ERC20Upgradeable,
    ERC4626Upgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {checkedAdd, checkedDiv, checkedMul, checkedSub, MAX_BPS, weightedAvg} from "./Math.sol";

/// @dev Id for checked function identification: uint256(keccak256("RewardBuffer"));
uint256 constant FILE_ID = 100448831994295041095109645825544697016842216820228479017213834858332751627035;

/// @title Buffer structure implementation for gradual reward release.
/// Intended for usage within ERC-4626 vault implementations.
contract ERC4626BufferedUpgradable is ERC4626Upgradeable {
    using Math for uint256;

    error AssetsCachedIsZero();

    uint256 public constant DEFAULT_BUFFERING_DURATION = 20 days;

    // keccak256(abi.encode(uint256(keccak256("common.storage.buffer")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant BUFFER_STORAGE_LOCATION =
        0xef5481445e9fe7b0c63b33af7a02ad6f9d34b7cb55d1e3d76cff004354e0e400;

    /// @dev MUST be initialized with non-zero value of `assetsCached` - vault should send some
    /// assets (together with corresponding shares) to an unreachable address (in the constructor).
    ///
    /// Use `_newBuffer` in order to create new buffer instance.
    struct BufferStorage {
        uint256 assetsCached;
        uint256 bufferedShares;
        uint256 lastUpdate;
        uint256 currentBufferEnd;
        address protocolFeeReceiver;
        uint256 protocolFeeBps;
    }

    /// @dev Increases the buffer's `assetsCached` field.
    /// Used when deposit or mint has been made to the vault.
    function _increaseAssets(uint256 assets) internal {
        BufferStorage storage $ = _getBufferStorage();
        $.assetsCached += assets;
    }

    /// @dev Increases the buffer's `assetsCached` field.
    /// Used when withdrawal or redemption has been made to the vault.
    function _decreaseAssets(uint256 assets) internal {
        BufferStorage storage $ = _getBufferStorage();
        $.assetsCached -= assets;
    }

    // function _newBuffer(uint256 initialAssets) private view returns (Buffer memory buffer) {
    //     if (initialAssets == 0) revert AssetsCachedIsZero();
    //     return Buffer(initialAssets, 0, block.timestamp, block.timestamp);
    // }

    /// @dev Use this to implement `totalAssets()`.
    function _getAssetsCached() private view returns (uint256 assets) {
        BufferStorage storage $ = _getBufferStorage();
        return $.assetsCached;
    }

    /// @notice Updates holdinds state, by reporting on every vault how many assets it has.
    /// Profits are smoothed out by the reward buffer, and ditributed to the holders.
    /// Protocol fee is taken from the profits. Potential losses are first covered by the buffer.
    function updateHoldingsState() public {
        BufferStorage storage $ = _getBufferStorage();
        uint256 oldCachedAssets = _getAssetsCached();

        if (oldCachedAssets == 0) {
            // We have to wait for the deposit to happen
            return;
        } else {
            uint256 newAssets = _totalAssetsNotCached();
            (uint256 sharesToMint, uint256 sharesToBurn) =
                _updateBuffer(newAssets, super.totalSupply(), $.protocolFeeBps);
            if (sharesToMint > 0) {
                uint256 feePartOfMintedShares = sharesToMint.mulDiv($.protocolFeeBps, MAX_BPS, Math.Rounding.Ceil);
                _mint(address(this), sharesToMint - feePartOfMintedShares);
                _mint($.protocolFeeReceiver, feePartOfMintedShares);
            }
            if (sharesToBurn > 0) {
                _burn(address(this), sharesToBurn);
            }
            // TODO: emit HoldingsStateUpdated(oldCachedAssets, newAssets);
        }
    }

    /// @notice Preview the holdings state update, without actually updating it.
    /// Returns `totalAssets` and `totalSupply` that there would be after the update.
    function _previewUpdateHoldingsState() internal view returns (uint256 newTotalAssets, uint256 newTotalSupply) {
        BufferStorage storage $ = _getBufferStorage();

        if (_getAssetsCached() == 0) {
            return (0, super.totalSupply());
        }

        newTotalAssets = _totalAssetsNotCached();
        (uint256 sharesToMint, uint256 sharesToBurn) =
            _simulateBufferUpdate(newTotalAssets, super.totalSupply(), $.protocolFeeBps);
        return (newTotalAssets, super.totalSupply() + sharesToMint - sharesToBurn);
    }

    /// @dev TODO: write
    function _totalAssetsNotCached() internal view virtual returns (uint256) {
        uint256 assets = IERC20(asset()).balanceOf(address(this));
        return assets;
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
    function _updateBuffer(uint256 _totalAssets, uint256 totalShares, uint256 feeBps)
        private
        returns (uint256 sharesToMint, uint256 sharesToBurn)
    {
        BufferStorage storage $ = _getBufferStorage();
        BufferStorage memory memBuf = $;
        (sharesToMint, sharesToBurn) = _updateBuffer(memBuf, _totalAssets, totalShares, feeBps);
        _toStorage(memBuf);
    }

    /// @dev Simulates buffer update.
    function _simulateBufferUpdate(uint256 _totalAssets, uint256 totalShares, uint256 feeBps)
        private
        view
        returns (uint256 sharesToMint, uint256 sharesToBurn)
    {
        BufferStorage memory updatedBuffer = _toMemory();
        (sharesToMint, sharesToBurn) = _updateBuffer(updatedBuffer, _totalAssets, totalShares, feeBps);
    }

    /// @dev Creates a `memory` copy of a buffer.
    function _toMemory() internal view returns (BufferStorage memory memBuffer) {
        BufferStorage storage $ = _getBufferStorage();
        memBuffer.assetsCached = $.assetsCached;
        memBuffer.bufferedShares = $.bufferedShares;
        memBuffer.lastUpdate = $.lastUpdate;
        memBuffer.currentBufferEnd = $.currentBufferEnd;
    }

    /// @dev Copies `memory` buffer into storage.
    function _toStorage(BufferStorage memory buffer) internal {
        BufferStorage storage $ = _getBufferStorage();
        $.assetsCached = buffer.assetsCached;
        $.bufferedShares = buffer.bufferedShares;
        $.lastUpdate = buffer.lastUpdate;
        $.currentBufferEnd = buffer.currentBufferEnd;
    }

    function _updateBuffer(BufferStorage memory buffer, uint256 _totalAssets, uint256 totalShares, uint256 feeBps)
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

        if (buffer.assetsCached <= _totalAssets) {
            (sharesToMint, buffer.currentBufferEnd) = _handleGain(buffer, totalShares, _totalAssets);
            buffer.bufferedShares = checkedAdd(buffer.bufferedShares, sharesToMint, FILE_ID, 2);
        } else {
            uint256 lossInShares = _handleLoss(buffer, totalShares, _totalAssets);
            sharesToBurn = checkedAdd(sharesToBurn, lossInShares, FILE_ID, 3);
            buffer.bufferedShares = checkedSub(buffer.bufferedShares, lossInShares, FILE_ID, 4);
        }

        uint256 cancelledOut = sharesToBurn.min(sharesToMint);
        sharesToBurn = checkedSub(sharesToBurn, cancelledOut, FILE_ID, 5);
        sharesToMint = checkedSub(sharesToMint, cancelledOut, FILE_ID, 6);
        if (sharesToMint > 0) {
            buffer.bufferedShares -= sharesToMint.mulDiv(feeBps, MAX_BPS, Math.Rounding.Ceil);
        }

        buffer.assetsCached = _totalAssets;
    }

    /// @dev Number of shares that should be burned to account for rewards to be released by the $.
    /// Use it to implement `totalSupply()`.
    function _sharesToBurn(BufferStorage memory buffer) private view returns (uint256 sharesReleased) {
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

    function _handleGain(BufferStorage memory buffer, uint256 totalShares, uint256 _totalAssets)
        private
        view
        returns (uint256 sharesToMint, uint256 newBufferEnd)
    {
        uint256 gain = checkedSub(_totalAssets, buffer.assetsCached, FILE_ID, 9);
        sharesToMint = gain.mulDiv(totalShares, buffer.assetsCached);

        if (sharesToMint == 0) {
            return (0, buffer.currentBufferEnd);
        }

        uint256 newUnlockEnd = checkedAdd(block.timestamp, DEFAULT_BUFFERING_DURATION, FILE_ID, 10);
        newBufferEnd = weightedAvg(buffer.currentBufferEnd, buffer.bufferedShares, newUnlockEnd, sharesToMint);
    }

    function _handleLoss(BufferStorage memory buffer, uint256 totalShares, uint256 _totalAssets)
        private
        pure
        returns (uint256 sharesToBurn)
    {
        uint256 loss = checkedSub(buffer.assetsCached, _totalAssets, FILE_ID, 11);
        if (loss == 0) {
            return 0;
        }

        uint256 lossInShares = loss.mulDiv(totalShares, buffer.assetsCached, Math.Rounding.Ceil);

        // If we need to burn more than `buffer.bufferedShares` shares to retain price-per-share,
        // then it's impossible to cover that from the buffer, and sharp PPS drop is to be expected.
        sharesToBurn = lossInShares.min(buffer.bufferedShares);
    }

    // ----- ERC20 -----

    function totalSupply() public view override(ERC20Upgradeable, IERC20) returns (uint256) {
        return super.totalSupply() - _sharesToBurn(_getBufferStorage());
    }

    function balanceOf(address account) public view override(ERC20Upgradeable, IERC20) returns (uint256 balance) {
        balance = super.balanceOf(account);
        if (account == address(this)) {
            balance -= _sharesToBurn(_getBufferStorage());
        }
    }

    // ----- ERC4626 -----

    /// @notice Returns cached assets from the last holdings state update.
    function totalAssets() public view override(ERC4626Upgradeable) returns (uint256) {
        return _getAssetsCached();
    }

    function _getBufferStorage() private pure returns (BufferStorage storage $) {
        assembly {
            $.slot := BUFFER_STORAGE_LOCATION
        }
    }
}
