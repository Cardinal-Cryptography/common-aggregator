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
import {checkedAdd, checkedSub, MAX_BPS, weightedAvg} from "./Math.sol";

/// @title Vault implementation based on OpenZeppelin's ERC4626Upgradeable.
/// It adds buffering to any asset rewards/airdrops received.
abstract contract ERC4626BufferedUpgradeable is Initializable, ERC20Upgradeable, IERC4626Buffered {
    using Math for uint256;

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

    // keccak256(abi.encode(uint256(keccak256("common.storage.erc4626buffered")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant BUFFER_STORAGE_LOCATION =
        0x0235e80c5858f4ebad04d9b77f76c15ea730f2e16f4abf26dfa455f5a2f93f00;

    function _getERC4626BufferedStorage() internal pure returns (ERC4626BufferedStorage storage $) {
        assembly {
            $.slot := BUFFER_STORAGE_LOCATION
        }
    }

    // ----- Initialization -----

    function __ERC4626Buffered_init(IERC20 _asset) internal onlyInitializing {
        ERC4626BufferedStorage storage $ = _getERC4626BufferedStorage();
        $.lastUpdate = block.timestamp;
        $.currentBufferEnd = block.timestamp;
        $.protocolFeeReceiver = address(1);

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
        uint256 oldTotalAssets = $.assetsCached;

        (uint256 newTotalAssets, uint256 releasedShares, uint256 lostShares, uint256 sharesToMint) = _holdingsUpdate();

        $.currentBufferEnd = $.currentBufferEnd.max(block.timestamp);

        // It's possible that we will have `sharesToBurn > 0 && sharesToMint > 0`.
        // We still want to perform both mint and burn, since fee is calculated based on minted shares.
        // If only the difference would be minted/burned then, with steady inflow of rewards, vault would take almost no fees.
        uint256 sharesToBurn = releasedShares + lostShares;
        if (sharesToBurn > 0) {
            // Burn fees from the buffer
            _burn(address(this), sharesToBurn);
            $.bufferedShares = $.bufferedShares - sharesToBurn;
        }

        if (sharesToMint > 0) {
            uint256 fee = sharesToMint.mulDiv($.protocolFeeBps, MAX_BPS, Math.Rounding.Ceil);

            _mint(address(this), sharesToMint - fee);
            _mint($.protocolFeeReceiver, fee);

            uint256 newUnlockEnd = block.timestamp + _defaultBufferingDuration();
            $.currentBufferEnd = weightedAvg($.currentBufferEnd, $.bufferedShares, newUnlockEnd, sharesToMint - fee);
            $.bufferedShares = checkedAdd($.bufferedShares, sharesToMint - fee, 1);
        }

        $.lastUpdate = block.timestamp;
        $.assetsCached = newTotalAssets;
        emit HoldingsStateUpdated(oldTotalAssets, newTotalAssets);
    }

    /// @notice Preview the holdings state update, without actually updating it.
    /// Returns `totalAssets` and `totalSupply` that there would be after the update.
    function _previewUpdateHoldingsState() internal view returns (uint256, uint256) {
        (uint256 newTotalAssets, uint256 releasedShares, uint256 lostShares, uint256 sharesToMint) = _holdingsUpdate();
        return (newTotalAssets, super.totalSupply() - releasedShares - lostShares + sharesToMint);
    }

    function _holdingsUpdate()
        internal
        view
        returns (uint256 newTotalAssets, uint256 releasedShares, uint256 lostShares, uint256 sharesToMint)
    {
        ERC4626BufferedStorage storage $ = _getERC4626BufferedStorage();
        newTotalAssets = _totalAssetsNotCached();
        uint256 oldTotalShares = super.totalSupply();

        releasedShares = _releasedShares($);
        uint256 newBufferedShares = $.bufferedShares - releasedShares;

        if ($.assetsCached <= newTotalAssets) {
            sharesToMint = _sharesToMintOnGain($.assetsCached, newTotalAssets, oldTotalShares - releasedShares);
        } else {
            lostShares =
                _sharesToBurnOnLoss($.assetsCached, newTotalAssets, oldTotalShares - releasedShares, newBufferedShares);
        }
    }

    /// @dev Number of shares that should be burned to account for rewards to be released by the buffer.
    function _releasedShares(ERC4626BufferedStorage memory buffer) private view returns (uint256 sharesReleased) {
        uint256 timestampNow = block.timestamp;
        uint256 start = buffer.lastUpdate;
        uint256 end = buffer.currentBufferEnd;
        uint256 bufferedShares = buffer.bufferedShares;

        if (end == start || timestampNow == start) {
            return 0;
        }

        uint256 duration = checkedSub(end, start, 2);
        uint256 elapsed = checkedSub(timestampNow, start, 3);

        if (elapsed >= duration) {
            sharesReleased = bufferedShares;
        } else {
            sharesReleased = bufferedShares.mulDiv(elapsed, duration);
        }
    }

    function _sharesToMintOnGain(uint256 oldTotalAssets, uint256 newTotalAssets, uint256 totalSharesPriorToGain)
        private
        view
        returns (uint256 sharesToMint)
    {
        uint256 gain = newTotalAssets - oldTotalAssets;
        return gain.mulDiv(totalSharesPriorToGain + 10 ** _decimalsOffset(), oldTotalAssets + 1);
    }

    function _sharesToBurnOnLoss(
        uint256 oldTotalAssets,
        uint256 newTotalAssets,
        uint256 totalSharesPriorToLoss,
        uint256 bufferedShares
    ) private view returns (uint256 sharesToBurn) {
        uint256 loss = oldTotalAssets - newTotalAssets;
        uint256 lossInShares =
            loss.mulDiv(totalSharesPriorToLoss + 10 ** _decimalsOffset(), oldTotalAssets + 1, Math.Rounding.Ceil);

        // If we need to burn more than `buffer.bufferedShares` shares to retain price-per-share,
        // then it's impossible to cover that from the buffer, and sharp PPS drop is to be expected.
        sharesToBurn = lossInShares.min(bufferedShares);
    }

    // ----- ERC20 -----

    function totalSupply() public view override(ERC20Upgradeable, IERC20) returns (uint256) {
        return super.totalSupply() - _releasedShares(_getERC4626BufferedStorage());
    }

    function balanceOf(address account) public view override(ERC20Upgradeable, IERC20) returns (uint256 balance) {
        balance = super.balanceOf(account);
        if (account == address(this)) {
            balance -= _releasedShares(_getERC4626BufferedStorage());
        }
    }

    // ----- ERC-4626 -----

    error ERC4626ExceededMaxDeposit(address receiver, uint256 assets, uint256 max);
    error ERC4626ExceededMaxMint(address receiver, uint256 shares, uint256 max);
    error ERC4626ExceededMaxWithdraw(address owner, uint256 assets, uint256 max);
    error ERC4626ExceededMaxRedeem(address owner, uint256 shares, uint256 max);

    /// @dev Attempts to fetch the asset decimals. A return value of false indicates that the attempt failed in some way.
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

    /// @inheritdoc IERC20Metadata
    /// @dev Decimals are computed by adding the decimal offset on top of the underlying asset's decimals. This
    /// "original" value is cached during construction of the vault contract. If this read operation fails (e.g., the
    /// asset has not been created yet), a default of 18 is used to represent the underlying asset's decimals.
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

    function setProtocolFee(uint256 feeBps) public virtual override(IERC4626Buffered) {
        ERC4626BufferedStorage storage $ = _getERC4626BufferedStorage();
        require($.protocolFeeBps <= MAX_BPS, IncorrectProtocolFee());
        $.protocolFeeBps = feeBps;
    }

    function setProtocolFeeReceiver(address receiver) public virtual override(IERC4626Buffered) {
        require(receiver != address(0), ZeroProtocolFeeReceiver());
        _getERC4626BufferedStorage().protocolFeeReceiver = receiver;
    }

    function getProtocolFee() public view override(IERC4626Buffered) returns (uint256) {
        return _getERC4626BufferedStorage().protocolFeeBps;
    }

    function getProtocolFeeReceiver() public view override(IERC4626Buffered) returns (address) {
        return _getERC4626BufferedStorage().protocolFeeReceiver;
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

    /// @dev Specifies number of additional (compared to `asset`) decimal places of the share token.
    function _decimalsOffset() internal view virtual returns (uint8) {
        return 0;
    }

    /// @dev Specifies time interval over which the new rewards are supposed to be distributed (before taking the mean).
    function _defaultBufferingDuration() internal view virtual returns (uint256) {
        return 20 days;
    }
}
