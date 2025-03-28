// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IERC4626Buffered} from "./interfaces/IERC4626Buffered.sol";
import {checkedAdd, checkedDiv, checkedMul, checkedSub, MAX_BPS, weightedAvg} from "./Math.sol";

// TODO: Consider moving rewards trading to this contract - it might make this contract useful on it's own.

// TODO: Update hash
/// @dev Id for checked function identification: uint256(keccak256("RewardBuffer"));
uint256 constant FILE_ID = 100448831994295041095109645825544697016842216820228479017213834858332751627035;

// TODO: This probably should be an abstract contract. Also, we might want to define interface for it.
/// @title Vault implementation based on OpenZeppelin's ERC4626Upgradeable.
/// It adds buffering to any asset rewards/airdrops received.
contract ERC4626BufferedUpgradeable is Initializable, ERC20Upgradeable, IERC4626Buffered {
    using Math for uint256;

    // TODO: consider making it an immutable variable or a virtual function so that
    // it's possible to set different values per instance/concrete contract implementation.
    uint256 public constant DEFAULT_BUFFERING_DURATION = 20 days;

    // TODO: It might be worth it to have a separate struct for buffering-related vars, consider it.
    struct ERC4626BufferedStorage {
        uint256 assetsCached;
        uint256 bufferedShares;
        uint256 lastUpdate;
        uint256 currentBufferEnd;
        address protocolFeeReceiver;
        uint256 protocolFeeBps;
        IERC20 _asset;
        uint8 _underlyingDecimals;
        uint8 _decimalsOffset;
    }

    // TODO: consider changing the string from which we derive the hash.
    // keccak256(abi.encode(uint256(keccak256("common.storage.buffer")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant BUFFER_STORAGE_LOCATION =
        0xef5481445e9fe7b0c63b33af7a02ad6f9d34b7cb55d1e3d76cff004354e0e400;

    function _getERC4626BufferedStorage() internal pure returns (ERC4626BufferedStorage storage $) {
        assembly {
            $.slot := BUFFER_STORAGE_LOCATION
        }
    }

    // ----- Initialization -----

    constructor() {
        _disableInitializers();
    }

    function initialize(IERC20 _asset, address protocolFeeReceiver) public initializer {
        __ERC4626Buffered_init(_asset, protocolFeeReceiver);
    }

    function __ERC4626Buffered_init(IERC20 _asset, address protocolFeeReceiver) internal onlyInitializing {
        ERC4626BufferedStorage storage $ = _getERC4626BufferedStorage();
        $.lastUpdate = block.timestamp;
        $.currentBufferEnd = block.timestamp;
        $.protocolFeeBps = 0;
        $.protocolFeeReceiver = protocolFeeReceiver;

        (bool success, uint8 assetDecimals) = _tryGetAssetDecimals(_asset);
        $._underlyingDecimals = success ? assetDecimals : 18;
        $._asset = _asset;
    }

    // ----- Buffering logic -----

    /// @dev Increases the buffer's `assetsCached` field.
    /// Used when deposit or mint has been made to the vault.
    function _increaseAssets(uint256 assets) internal {
        ERC4626BufferedStorage storage $ = _getERC4626BufferedStorage();
        $.assetsCached += assets;
    }

    /// @dev Increases the buffer's `assetsCached` field.
    /// Used when withdrawal or redemption has been made to the vault.
    function _decreaseAssets(uint256 assets) internal {
        ERC4626BufferedStorage storage $ = _getERC4626BufferedStorage();
        $.assetsCached -= assets;
    }

    /// @notice Updates holdings state based on currently held assets and time elapsed from last update.
    /// Profits are smoothed out by the reward buffer, and ditributed to the holders.
    /// Protocol fee is taken from the profits. Potential losses are first covered by the buffer.
    /// @dev Updates the buffer based on the current vault's state.
    /// Should be called before any state mutating methods that depend on price-per-share.
    ///
    /// Alternatively (or additionally), it may be called by an off-chain component at times
    /// when difference between `assetsCached` and `totalAssets()` becomes significant.
    function updateHoldingsState() public {
        ERC4626BufferedStorage storage $ = _getERC4626BufferedStorage();
        uint256 oldCachedAssets = $.assetsCached;

        if (oldCachedAssets == 0) {
            // We have to wait for the deposit to happen
            return;
        } else {
            uint256 _totalAssets = _totalAssetsNotCached();
            uint256 _totalShares = super.totalSupply();

            // -- Rewards unlock --

            // TODO: This section my use a slight refactor (?)
            uint256 sharesToMint;
            uint256 sharesToBurn = _sharesToBurn($);
            $.bufferedShares = checkedSub($.bufferedShares, sharesToBurn, FILE_ID, 1);
            $.lastUpdate = block.timestamp;
            $.currentBufferEnd = $.currentBufferEnd.max(block.timestamp);

            // -- Buffer update (new rewards/loss) --

            if ($.assetsCached <= _totalAssets) {
                sharesToMint = _handleGain($, _totalShares, _totalAssets);
                $.bufferedShares = checkedAdd($.bufferedShares, sharesToMint, FILE_ID, 2);
            } else {
                uint256 lossInShares = _sharesToBurnOnLoss($, _totalShares, _totalAssets);
                sharesToBurn = checkedAdd(sharesToBurn, lossInShares, FILE_ID, 3);
                $.bufferedShares = checkedSub($.bufferedShares, lossInShares, FILE_ID, 4);
            }

            // It's possible that we will have `sharesToBurn > 0 && sharesToMint > 0`.
            // We still want to perform both mint and burn, since fee is calculated based on minted shares.
            // If only the difference would be minted/burned then, with steady inflow of rewards, vault would take almost no fees.

            if (sharesToBurn > 0) {
                // Burn fees from the buffer
                _burn(address(this), sharesToBurn);
            }

            if (sharesToMint > 0) {
                uint256 fee = sharesToMint.mulDiv($.protocolFeeBps, MAX_BPS, Math.Rounding.Ceil);

                // TODO: Make fees optional.
                // Mint performance fee
                $.bufferedShares -= fee;
                _mint(address(this), sharesToMint - fee);

                // Mint shares for rewards buffering
                _mint($.protocolFeeReceiver, fee);
            }

            $.assetsCached = _totalAssets;

            emit HoldingsStateUpdated(oldCachedAssets, _totalAssets);
        }
    }

    /// @notice Preview the holdings state update, without actually updating it.
    /// Returns `totalAssets` and `totalSupply` that there would be after the update.
    function _previewUpdateHoldingsState() internal view returns (uint256, uint256) {
        ERC4626BufferedStorage storage $ = _getERC4626BufferedStorage();
        if ($.assetsCached == 0) {
            return (0, super.totalSupply());
        }

        uint256 currentTotalSupply = super.totalSupply();
        uint256 newTotalAssets = _totalAssetsNotCached();

        // TODO: This is slightly controversial since we don't return the same exact values as those set by mutating version.
        // We only ensure that price-per-share is the same. Make sure that it's OK. Update function doc afterwards.

        // We don't sync `bufferedShares` between methods here, so we could get that we need to burn more that is in the buffer.
        // We need a guard against that.
        uint256 sharesToBurn =
            $.bufferedShares.min(_sharesToBurn($) + _sharesToBurnOnLoss($, currentTotalSupply, newTotalAssets));

        // We can omit share gain update, since it doesn't change the price-per-share.
        // This means that we don't update assets if there was gain + we don't mint shares.
        return ($.assetsCached.min(newTotalAssets), currentTotalSupply - sharesToBurn);
    }

    /// @dev Number of shares that should be burned to account for rewards to be released by the buffer.
    /// Use it to implement `totalSupply()`.
    function _sharesToBurn(ERC4626BufferedStorage memory buffer) private view returns (uint256 sharesReleased) {
        uint256 timestampNow = block.timestamp;
        uint256 start = buffer.lastUpdate;
        uint256 end = buffer.currentBufferEnd;
        uint256 bufferedShares = buffer.bufferedShares;

        if (end == start || timestampNow == start) {
            return 0;
        }

        uint256 duration = checkedSub(end, start, FILE_ID, 5);
        uint256 elapsed = checkedSub(timestampNow, start, FILE_ID, 6);

        if (elapsed >= duration) {
            sharesReleased = bufferedShares;
        } else {
            sharesReleased = bufferedShares.mulDiv(elapsed, duration);
        }
    }

    function _handleGain(ERC4626BufferedStorage storage $, uint256 totalShares, uint256 _totalAssets)
        private
        returns (uint256 sharesToMint)
    {
        uint256 gain = checkedSub(_totalAssets, $.assetsCached, FILE_ID, 7);
        sharesToMint = gain.mulDiv(totalShares, $.assetsCached);

        if (sharesToMint == 0) {
            return 0;
        }

        uint256 newUnlockEnd = checkedAdd(block.timestamp, DEFAULT_BUFFERING_DURATION, FILE_ID, 8);
        $.currentBufferEnd = weightedAvg($.currentBufferEnd, $.bufferedShares, newUnlockEnd, sharesToMint);
    }

    function _sharesToBurnOnLoss(
        ERC4626BufferedStorage memory buffer,
        uint256 currentTotalShares,
        uint256 currentTotalAssets
    ) private pure returns (uint256 sharesToBurn) {
        if (buffer.assetsCached <= currentTotalAssets) {
            return 0;
        }

        uint256 loss = checkedSub(buffer.assetsCached, currentTotalAssets, FILE_ID, 9);
        uint256 lossInShares = loss.mulDiv(currentTotalShares, buffer.assetsCached, Math.Rounding.Ceil);

        // If we need to burn more than `buffer.bufferedShares` shares to retain price-per-share,
        // then it's impossible to cover that from the buffer, and sharp PPS drop is to be expected.
        sharesToBurn = lossInShares.min(buffer.bufferedShares);
    }

    // ----- ERC20 -----

    function totalSupply() public view override(ERC20Upgradeable, IERC20) returns (uint256) {
        return super.totalSupply() - _sharesToBurn(_getERC4626BufferedStorage());
    }

    function balanceOf(address account) public view override(ERC20Upgradeable, IERC20) returns (uint256 balance) {
        balance = super.balanceOf(account);
        if (account == address(this)) {
            balance -= _sharesToBurn(_getERC4626BufferedStorage());
        }
    }

    // ----- ERC-4626 -----

    /// @dev Attempted to deposit more assets than the max amount for `receiver`.
    error ERC4626ExceededMaxDeposit(address receiver, uint256 assets, uint256 max);

    /// @dev Attempted to mint more shares than the max amount for `receiver`.
    error ERC4626ExceededMaxMint(address receiver, uint256 shares, uint256 max);

    /// @dev Attempted to withdraw more assets than the max amount for `receiver`.
    error ERC4626ExceededMaxWithdraw(address owner, uint256 assets, uint256 max);

    /// @dev Attempted to redeem more shares than the max amount for `receiver`.
    error ERC4626ExceededMaxRedeem(address owner, uint256 shares, uint256 max);

    // TODO: It might be better to simply pass this value in the constructor (if we care about bytecode size).
    /**
     * @dev Attempts to fetch the asset decimals. A return value of false indicates that the attempt failed in some way.
     */
    function _tryGetAssetDecimals(IERC20 asset_) private view returns (bool ok, uint8 assetDecimals) {
        (bool success, bytes memory encodedDecimals) =
            address(asset_).staticcall(abi.encodeCall(IERC20Metadata.decimals, ()));
        if (success && encodedDecimals.length >= 32) {
            uint256 returnedDecimals = abi.decode(encodedDecimals, (uint256));
            if (returnedDecimals <= type(uint8).max) {
                return (true, uint8(returnedDecimals));
            }
        }
        return (false, 0);
    }

    // TODO: update doc
    /**
     * @dev Decimals are computed by adding the decimal offset on top of the underlying asset's decimals. This
     * "original" value is cached during construction of the vault contract. If this read operation fails (e.g., the
     * asset has not been created yet), a default of 18 is used to represent the underlying asset's decimals.
     *
     * See {IERC20Metadata-decimals}.
     */
    function decimals() public view virtual override(IERC20Metadata, ERC20Upgradeable) returns (uint8) {
        ERC4626BufferedStorage storage $ = _getERC4626BufferedStorage();
        return $._underlyingDecimals + _decimalsOffset();
    }

    /// @inheritdoc IERC4626
    function asset() public view virtual returns (address) {
        ERC4626BufferedStorage storage $ = _getERC4626BufferedStorage();
        return address($._asset);
    }

    /// @notice Returns cached assets from the last holdings state update.
    function totalAssets() public view override(IERC4626) returns (uint256) {
        return _getERC4626BufferedStorage().assetsCached;
    }

    /// @inheritdoc IERC4626
    /// @dev Updates holdings state before the preview.
    function previewDeposit(uint256 assets) public view override(IERC4626) returns (uint256) {
        (uint256 newTotalAssets, uint256 newTotalSupply) = _previewUpdateHoldingsState();
        return assets.mulDiv(newTotalSupply + 10 ** _decimalsOffset(), newTotalAssets + 1, Math.Rounding.Floor);
    }

    /// @inheritdoc IERC4626
    /// @dev Updates holdings state before the preview.
    function previewMint(uint256 shares) public view override(IERC4626) returns (uint256) {
        (uint256 newTotalAssets, uint256 newTotalSupply) = _previewUpdateHoldingsState();
        return shares.mulDiv(newTotalAssets + 1, newTotalSupply + 10 ** _decimalsOffset(), Math.Rounding.Ceil);
    }

    /// @inheritdoc IERC4626
    /// @dev Updates holdings state before the preview.
    function previewWithdraw(uint256 assets) public view override(IERC4626) returns (uint256) {
        (uint256 newTotalAssets, uint256 newTotalSupply) = _previewUpdateHoldingsState();
        return assets.mulDiv(newTotalSupply + 10 ** _decimalsOffset(), newTotalAssets + 1, Math.Rounding.Ceil);
    }

    /// @inheritdoc IERC4626
    /// @dev Updates holdings state before the preview.
    function previewRedeem(uint256 shares) public view override(IERC4626) returns (uint256) {
        (uint256 newTotalAssets, uint256 newTotalSupply) = _previewUpdateHoldingsState();
        return shares.mulDiv(newTotalAssets + 1, newTotalSupply + 10 ** _decimalsOffset(), Math.Rounding.Floor);
    }

    /// @inheritdoc IERC4626
    function convertToShares(uint256 assets) public view virtual returns (uint256) {
        return assets.mulDiv(totalSupply() + 10 ** _decimalsOffset(), totalAssets() + 1);
    }

    /// @inheritdoc IERC4626
    function convertToAssets(uint256 shares) public view virtual returns (uint256) {
        return shares.mulDiv(totalAssets() + 1, totalSupply() + 10 ** _decimalsOffset());
    }

    /// @inheritdoc IERC4626
    function maxDeposit(address) public view virtual returns (uint256) {
        return type(uint256).max;
    }

    /// @inheritdoc IERC4626
    function maxMint(address) public view virtual returns (uint256) {
        return type(uint256).max;
    }

    /// @inheritdoc IERC4626
    function maxWithdraw(address owner) public view virtual returns (uint256) {
        return convertToAssets(balanceOf(owner));
    }

    /// @inheritdoc IERC4626
    function maxRedeem(address owner) public view virtual returns (uint256) {
        return balanceOf(owner);
    }

    /// @inheritdoc IERC4626
    function deposit(uint256 assets, address receiver) public virtual override(IERC4626) returns (uint256) {
        updateHoldingsState();

        uint256 maxAssets = maxDeposit(receiver);
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxDeposit(receiver, assets, maxAssets);
        }

        uint256 shares = previewDeposit(assets);
        _deposit(_msgSender(), receiver, assets, shares);

        return shares;
    }

    /// @inheritdoc IERC4626
    function mint(uint256 shares, address receiver) public virtual override(IERC4626) returns (uint256) {
        updateHoldingsState();
        uint256 maxShares = maxMint(receiver);
        if (shares > maxShares) {
            revert ERC4626ExceededMaxMint(receiver, shares, maxShares);
        }

        uint256 assets = previewMint(shares);
        _deposit(_msgSender(), receiver, assets, shares);

        return assets;
    }

    /// @inheritdoc IERC4626
    function withdraw(uint256 assets, address receiver, address owner)
        public
        virtual
        override(IERC4626)
        returns (uint256)
    {
        updateHoldingsState();
        uint256 maxAssets = maxWithdraw(owner);
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxWithdraw(owner, assets, maxAssets);
        }

        uint256 shares = previewWithdraw(assets);
        _withdraw(_msgSender(), receiver, owner, assets, shares);

        return shares;
    }

    /// @inheritdoc IERC4626
    function redeem(uint256 shares, address receiver, address owner)
        public
        virtual
        override(IERC4626)
        returns (uint256)
    {
        updateHoldingsState();
        uint256 maxShares = maxRedeem(owner);
        if (shares > maxShares) {
            revert ERC4626ExceededMaxRedeem(owner, shares, maxShares);
        }

        uint256 assets = previewRedeem(shares);
        _withdraw(_msgSender(), receiver, owner, assets, shares);

        return assets;
    }

    /// @dev Deposit/mint common workflow.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal virtual {
        ERC4626BufferedStorage storage $ = _getERC4626BufferedStorage();

        SafeERC20.safeTransferFrom($._asset, caller, address(this), assets);
        _mint(receiver, shares);
        _postDeposit(assets);
        _increaseAssets(assets);

        emit Deposit(caller, receiver, assets, shares);
    }

    /// @dev Withdraw/redeem common workflow.
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        virtual
    {
        ERC4626BufferedStorage storage $ = _getERC4626BufferedStorage();
        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }

        _preWithdrawal(assets);
        _burn(owner, shares);
        _decreaseAssets(assets);
        SafeERC20.safeTransfer($._asset, receiver, assets);

        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    function _decimalsOffset() internal view virtual returns (uint8) {
        return 0;
    }

    // ----- Hooks -----

    /// @dev Defines calculation for amount of assets currently held by the vault (disregarding cache).
    function _totalAssetsNotCached() internal view virtual returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    /// @dev Can be used to define action that should be run after each deposit/mint.
    function _postDeposit(uint256 assets) internal virtual {}

    /// @dev Can be used to define action that should be run before each withdraw/redeem.
    function _preWithdrawal(uint256 assets) internal virtual {}
}
