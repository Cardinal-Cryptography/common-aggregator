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
contract ERC4626BufferedUpgradeable is ERC4626Upgradeable {
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

    // ----- Initialization -----

    function initialize(IERC20 asset, address protocolFeeReceiver) public initializer {
        __ERC4626Buffered_init(asset, protocolFeeReceiver);
    }

    function __ERC4626Buffered_init(IERC20 asset, address protocolFeeReceiver) internal onlyInitializing {
        __ERC4626_init(asset);

        BufferStorage storage $ = _getBufferStorage();
        $.lastUpdate = block.timestamp;
        $.currentBufferEnd = block.timestamp;
        $.protocolFeeBps = 0;
        $.protocolFeeReceiver = protocolFeeReceiver;
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

    /// @notice Updates holdinds state, by reporting on every vault how many assets it has.
    /// Profits are smoothed out by the reward buffer, and ditributed to the holders.
    /// Protocol fee is taken from the profits. Potential losses are first covered by the buffer.
    function updateHoldingsState() public {
        BufferStorage storage $ = _getBufferStorage();
        uint256 oldCachedAssets = $.assetsCached;

        if (oldCachedAssets == 0) {
            // We have to wait for the deposit to happen
            return;
        } else {
            uint256 newAssets = _totalAssetsNotCached();
            (uint256 sharesToMint, uint256 sharesToBurn) = _updateBuffer(newAssets, super.totalSupply());
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

        if ($.assetsCached == 0) {
            return (0, super.totalSupply());
        }

        newTotalAssets = _totalAssetsNotCached();
        (uint256 sharesToMint, uint256 sharesToBurn) = _simulateBufferUpdate(newTotalAssets, super.totalSupply());
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
    function _updateBuffer(uint256 _totalAssets, uint256 totalShares)
        private
        returns (uint256 sharesToMint, uint256 sharesToBurn)
    {
        BufferStorage memory memBuf = _getBufferStorage();
        (sharesToMint, sharesToBurn) = __updateBuffer(memBuf, _totalAssets, totalShares);
        _toStorage(memBuf);
    }

    /// @dev Simulates buffer update.
    function _simulateBufferUpdate(uint256 _totalAssets, uint256 totalShares)
        private
        view
        returns (uint256 sharesToMint, uint256 sharesToBurn)
    {
        (sharesToMint, sharesToBurn) = __updateBuffer(_getBufferStorage(), _totalAssets, totalShares);
    }

    /// @dev Copies `memory` buffer into storage.
    function _toStorage(BufferStorage memory buffer) internal {
        BufferStorage storage $ = _getBufferStorage();
        $.assetsCached = buffer.assetsCached;
        $.bufferedShares = buffer.bufferedShares;
        $.lastUpdate = buffer.lastUpdate;
        $.currentBufferEnd = buffer.currentBufferEnd;
    }

    function __updateBuffer(BufferStorage memory buffer, uint256 _totalAssets, uint256 totalShares)
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
            buffer.bufferedShares -= sharesToMint.mulDiv(buffer.protocolFeeBps, MAX_BPS, Math.Rounding.Ceil);
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
        return _getBufferStorage().assetsCached;
    }

    /// @inheritdoc IERC4626
    /// @dev Updates holdings state before the preview.
    function previewDeposit(uint256 assets) public view override(ERC4626Upgradeable) returns (uint256) {
        (uint256 newTotalAssets, uint256 newTotalSupply) = _previewUpdateHoldingsState();
        return assets.mulDiv(newTotalSupply + 10 ** _decimalsOffset(), newTotalAssets + 1, Math.Rounding.Floor);
    }

    /// @inheritdoc IERC4626
    /// @dev Updates holdings state before the preview.
    function previewMint(uint256 shares) public view override(ERC4626Upgradeable) returns (uint256) {
        (uint256 newTotalAssets, uint256 newTotalSupply) = _previewUpdateHoldingsState();
        return shares.mulDiv(newTotalAssets + 1, newTotalSupply + 10 ** _decimalsOffset(), Math.Rounding.Ceil);
    }

    /// @inheritdoc IERC4626
    /// @dev Updates holdings state before the preview.
    function previewWithdraw(uint256 assets) public view override(ERC4626Upgradeable) returns (uint256) {
        (uint256 newTotalAssets, uint256 newTotalSupply) = _previewUpdateHoldingsState();
        return assets.mulDiv(newTotalSupply + 10 ** _decimalsOffset(), newTotalAssets + 1, Math.Rounding.Ceil);
    }

    /// @inheritdoc IERC4626
    /// @dev Updates holdings state before the preview.
    function previewRedeem(uint256 shares) public view override(ERC4626Upgradeable) returns (uint256) {
        (uint256 newTotalAssets, uint256 newTotalSupply) = _previewUpdateHoldingsState();
        return shares.mulDiv(newTotalAssets + 1, newTotalSupply + 10 ** _decimalsOffset(), Math.Rounding.Floor);
    }

    /// TODO: Add pausing back to deposit
    /// @inheritdoc IERC4626
    /// @notice Updates holdings state before depositing.
    function deposit(uint256 assets, address account) public override(ERC4626Upgradeable) returns (uint256) {
        updateHoldingsState();
        uint256 shares = super.deposit(assets, account);

        _postDeposit(assets);
        _increaseAssets(assets);

        return shares;
    }

    /// @inheritdoc IERC4626
    /// @notice Updates holdings state before minting.
    function mint(uint256 shares, address account) public override(ERC4626Upgradeable) returns (uint256) {
        updateHoldingsState();
        uint256 assets = super.mint(shares, account);

        _postDeposit(assets);
        _increaseAssets(assets);

        return assets;
    }

    /// @inheritdoc IERC4626
    /// @notice Updates holdings state before withdrawing.
    function withdraw(uint256 assets, address account, address owner)
        public
        override(ERC4626Upgradeable)
        returns (uint256)
    {
        updateHoldingsState();
        _preWithdrawal(assets);
        uint256 shares = super.withdraw(assets, account, owner);

        _decreaseAssets(assets);

        return shares;
    }

    /// @inheritdoc IERC4626
    /// @notice Updates holdings state before redeeming.
    function redeem(uint256 shares, address account, address owner)
        public
        override(ERC4626Upgradeable)
        returns (uint256)
    {
        updateHoldingsState();
        uint256 assetsNeeded = convertToAssets(shares);
        _preWithdrawal(assetsNeeded);
        uint256 assets = super.redeem(shares, account, owner);

        _decreaseAssets(assets);

        return assets;
    }

    function _postDeposit(uint256 assets) internal virtual {}
    function _preWithdrawal(uint256 assets) internal virtual {}

    // ----- Etc -----

    constructor() {
        _disableInitializers();
    }

    function _getBufferStorage() internal pure returns (BufferStorage storage $) {
        assembly {
            $.slot := BUFFER_STORAGE_LOCATION
        }
    }
}
