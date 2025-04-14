// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {
    ERC20Upgradeable,
    Initializable,
    IERC20,
    IERC20Metadata,
    IERC4626,
    Math,
    SafeERC20
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {checkedAdd, checkedSub, MAX_BPS, weightedAvg} from "./Math.sol";

/// @title Vault implementation based on OpenZeppelin's ERC4626Upgradeable.
/// It adds buffering to any asset rewards/airdrops received.
abstract contract ERC4626BufferedUpgradeable is Initializable, ERC20Upgradeable, IERC4626 {
    event HoldingsStateUpdated(uint256 oldTotalAssets, uint256 newTotalAssets);

    error IncorrectProtocolFee();
    error ZeroProtocolFeeReceiver();

    using Math for uint256;

    struct ERC4626BufferedStorage {
        uint256 assetsCached;
        uint256 bufferedShares;
        uint256 lastUpdate;
        uint256 currentBufferEnd;
        uint256 protocolFeeBps;
        address protocolFeeReceiver;
        uint8 underlyingDecimals;
        IERC20 asset;
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

    // solhint-disable-next-line func-name-mixedcase
    function __ERC4626Buffered_init(IERC20 _asset) internal onlyInitializing {
        ERC4626BufferedStorage storage $ = _getERC4626BufferedStorage();
        $.lastUpdate = block.timestamp;
        $.currentBufferEnd = block.timestamp;
        $.protocolFeeReceiver = address(1);

        (bool success, uint8 assetDecimals) = _tryGetAssetDecimals(_asset);
        $.underlyingDecimals = success ? assetDecimals : 18;
        $.asset = _asset;
    }

    // ----- Buffering logic -----

    /// @dev Increases the buffer's `assetsCached` field.
    /// Used when deposit or mint has been made to the vault.
    function _increaseAssets(uint256 assets) internal {
        _getERC4626BufferedStorage().assetsCached += assets;
    }

    /// @dev Increases the buffer's `assetsCached` field.
    /// Used when withdrawal or redemption has been made to the vault.
    function _decreaseAssets(uint256 assets) internal {
        _getERC4626BufferedStorage().assetsCached -= assets;
    }

    /// @notice Updates holdings state based on currently held assets and time elapsed from last update.
    /// Profits are smoothed out by the reward buffer, and distributed to the holders.
    /// Protocol fee is taken from the profits. Potential losses are first covered by the buffer.
    /// @dev Updates the buffer based on the current vault's state.
    /// Should be called before any state mutating methods that depend on price-per-share.
    ///
    /// Alternatively (or additionally), it may be called by an off-chain component at times
    /// when difference between `assetsCached` and `totalAssets()` becomes significant.
    function _updateHoldingsState() internal {
        ERC4626BufferedStorage storage $ = _getERC4626BufferedStorage();
        uint256 oldTotalAssets = $.assetsCached;

        (uint256 newTotalAssets, uint256 sharesToBurn, uint256 sharesToMint) = _holdingsUpdate();

        $.currentBufferEnd = $.currentBufferEnd.max(block.timestamp);

        // Account for released shares and any potential losses in the further calculations
        $.bufferedShares -= sharesToBurn; // (#1)

        // Apply fee and compute new buffer end timestamp, if there was any gain
        // Note that `sharesToMint > 0` means there are no losses
        if (sharesToMint > 0) {
            uint256 fee = sharesToMint.mulDiv($.protocolFeeBps, MAX_BPS, Math.Rounding.Ceil);
            _mint($.protocolFeeReceiver, fee);
            sharesToMint -= fee;

            // compute new buffer end timestamp
            uint256 newUnlockEnd = block.timestamp + _defaultBufferingDuration();
            $.currentBufferEnd = weightedAvg($.currentBufferEnd, $.bufferedShares, newUnlockEnd, sharesToMint);

            $.bufferedShares = checkedAdd($.bufferedShares, sharesToMint, 1); // (#2)
        }

        // Mint or burn buffer shares ( to reflect #1 and #2)
        if (sharesToMint > sharesToBurn) {
            _mint(address(this), sharesToMint - sharesToBurn);
        } else {
            _burn(address(this), sharesToBurn - sharesToMint);
        }

        $.lastUpdate = block.timestamp;
        $.assetsCached = newTotalAssets;
        emit HoldingsStateUpdated(oldTotalAssets, newTotalAssets);
    }

    /// @notice Preview the holdings state update, without actually updating it.
    /// Returns `totalAssets` and `totalSupply` that there would be after the update.
    function _previewUpdateHoldingsState() internal view returns (uint256, uint256) {
        (uint256 newTotalAssets, uint256 sharesToBurn, uint256 sharesToMint) = _holdingsUpdate();
        return (newTotalAssets, super.totalSupply() - sharesToBurn + sharesToMint);
    }

    function _holdingsUpdate()
        internal
        view
        returns (uint256 newTotalAssets, uint256 sharesToBurn, uint256 sharesToMint)
    {
        ERC4626BufferedStorage storage $ = _getERC4626BufferedStorage();
        newTotalAssets = _totalAssetsNotCached();
        uint256 oldTotalShares = super.totalSupply();

        sharesToBurn = _releasedShares();
        uint256 newBufferedShares = $.bufferedShares - sharesToBurn;

        if ($.assetsCached <= newTotalAssets) {
            sharesToMint = _sharesToMintOnGain($.assetsCached, newTotalAssets, oldTotalShares - sharesToBurn);
        } else {
            sharesToBurn +=
                _sharesToBurnOnLoss($.assetsCached, newTotalAssets, oldTotalShares - sharesToBurn, newBufferedShares);
        }
    }

    /// @dev Number of shares that should be burned to account for rewards to be released by the buffer.
    function _releasedShares() private view returns (uint256 sharesReleased) {
        ERC4626BufferedStorage storage $ = _getERC4626BufferedStorage();

        uint256 timestampNow = block.timestamp;
        uint256 start = $.lastUpdate;
        uint256 end = $.currentBufferEnd;

        if (end == start || timestampNow == start) {
            return 0;
        }

        uint256 duration = checkedSub(end, start, 2);
        uint256 elapsed = checkedSub(timestampNow, start, 3);

        if (elapsed >= duration) {
            sharesReleased = $.bufferedShares;
        } else {
            sharesReleased = $.bufferedShares.mulDiv(elapsed, duration);
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
        return super.totalSupply() - _releasedShares();
    }

    function balanceOf(address account) public view override(ERC20Upgradeable, IERC20) returns (uint256 balance) {
        balance = super.balanceOf(account);
        if (account == address(this)) {
            balance -= _releasedShares();
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

    /// @notice Returns decimals of the underlying share token.
    /// @dev Decimals are computed by adding the decimal offset on top of the underlying asset's decimals. This
    /// "original" value is cached during construction of the vault contract. If this read operation fails (e.g., the
    /// asset has not been created yet), a default of 18 is used to represent the underlying asset's decimals.
    function decimals() public view virtual override(IERC20Metadata, ERC20Upgradeable) returns (uint8) {
        return _getERC4626BufferedStorage().underlyingDecimals + _decimalsOffset();
    }

    /// @notice Returns the address of the underlying ERC-20 token used for the vault for accounting, depositing, and withdrawing.
    function asset() public view virtual returns (address) {
        return address(_getERC4626BufferedStorage().asset);
    }

    /// @notice Returns cached assets from the last holdings state update.
    function totalAssets() public view override(IERC4626) returns (uint256) {
        return _getERC4626BufferedStorage().assetsCached;
    }

    /// @notice Allows an on-chain or off-chain user to simulate the effects of their deposit at the current block, given
    /// current on-chain conditions. Simulates holdings state update before the preview.
    /// @dev Doesn't account for deposit limits given by `maxDeposit()`.
    function previewDeposit(uint256 assets) public view override(IERC4626) returns (uint256) {
        (uint256 newTotalAssets, uint256 newTotalSupply) = _previewUpdateHoldingsState();
        return assets.mulDiv(newTotalSupply + 10 ** _decimalsOffset(), newTotalAssets + 1, Math.Rounding.Floor);
    }

    /// @notice Allows an on-chain or off-chain user to simulate the effects of their mint at the current block, given
    /// current on-chain conditions. Simulates holdings state update before the preview.
    /// @dev Doesn't account for mint limits given by `maxMint()`.
    function previewMint(uint256 shares) public view override(IERC4626) returns (uint256) {
        (uint256 newTotalAssets, uint256 newTotalSupply) = _previewUpdateHoldingsState();
        return shares.mulDiv(newTotalAssets + 1, newTotalSupply + 10 ** _decimalsOffset(), Math.Rounding.Ceil);
    }

    /// @notice Allows an on-chain or off-chain user to simulate the effects of their withdraw at the current block, given
    /// current on-chain conditions. Simulates holdings state update before the preview.
    /// @dev Doesn't account for withdraw limits given by `maxWithdraw()`.
    function previewWithdraw(uint256 assets) public view override(IERC4626) returns (uint256) {
        (uint256 newTotalAssets, uint256 newTotalSupply) = _previewUpdateHoldingsState();
        return assets.mulDiv(newTotalSupply + 10 ** _decimalsOffset(), newTotalAssets + 1, Math.Rounding.Ceil);
    }

    /// @notice Allows an on-chain or off-chain user to simulate the effects of their redeem at the current block, given
    /// current on-chain conditions. Simulates holdings state update before the preview.
    /// @dev Doesn't account for redeem limits given by `maxRedeem()`.
    function previewRedeem(uint256 shares) public view override(IERC4626) returns (uint256) {
        (uint256 newTotalAssets, uint256 newTotalSupply) = _previewUpdateHoldingsState();
        return shares.mulDiv(newTotalAssets + 1, newTotalSupply + 10 ** _decimalsOffset(), Math.Rounding.Floor);
    }

    /// @notice Returns the amount of shares that the vault would exchange for the amount of assets provided, in an ideal
    /// scenario where all the conditions are met.
    /// @dev Accounts for shares burned in the reward buffer, but doesn't preview holdings state update.
    function convertToShares(uint256 assets) public view virtual returns (uint256) {
        return assets.mulDiv(totalSupply() + 10 ** _decimalsOffset(), totalAssets() + 1);
    }

    /// @notice Returns the amount of assets that the vault would exchange for the amount of shares provided, in an ideal
    /// scenario where all the conditions are met.
    /// @dev Accounts for shares burned in the reward buffer, but doesn't preview holdings state update.
    function convertToAssets(uint256 shares) public view virtual returns (uint256) {
        return shares.mulDiv(totalAssets() + 1, totalSupply() + 10 ** _decimalsOffset());
    }

    /// @notice Returns the maximum amount of the underlying asset that can be deposited into the vault for the receiver,
    /// through a deposit call.
    function maxDeposit(address) public view virtual returns (uint256) {
        return type(uint256).max;
    }

    /// @notice Returns the maximum amount of the underlying asset that can be minted for the receiver, through a mint call.
    function maxMint(address) public view virtual returns (uint256) {
        return type(uint256).max;
    }

    /// @notice Returns the maximum amount of the underlying asset that can be withdrawn from the owner balance in the
    /// vault, through a withdraw call. Accounts for shares burned in the reward buffer, but doesn't preview holdings
    /// state update.
    /// If `owner` is `protocolFeeReceiver`, this function might underestimate when there are pending protocol fees.
    /// In that case, call the `updateHoldingsState()` right before calling this function,
    /// to ensure that the value of `maxWithdraw` is exact.
    function maxWithdraw(address owner) public view virtual returns (uint256) {
        return convertToAssets(balanceOf(owner));
    }

    /// @notice Returns the maximum amount of vault shares that can be redeemed from the owner balance in the vault,
    /// through a redeem call.
    /// If `owner` is `protocolFeeReceiver`, this function might underestimate when there are pending protocol fees.
    /// In that case, call the `updateHoldingsState()` right before calling this function,
    /// to ensure that the value of `maxRedeem` is exact.
    function maxRedeem(address owner) public view virtual returns (uint256) {
        return balanceOf(owner);
    }

    /// @notice Mints vault shares to `receiver` by depositing exactly `assets` of underlying tokens.
    /// Returns the amount of shares that were minted.
    /// @dev Updates the holdings state before the deposit, so that any pending gain or loss report is recent.
    function deposit(uint256 assets, address receiver) public virtual override(IERC4626) returns (uint256) {
        _updateHoldingsState();

        uint256 maxAssets = maxDeposit(receiver);
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxDeposit(receiver, assets, maxAssets);
        }

        uint256 shares =
            assets.mulDiv(super.totalSupply() + 10 ** _decimalsOffset(), totalAssets() + 1, Math.Rounding.Floor);
        _deposit(_msgSender(), receiver, assets, shares);

        return shares;
    }

    /// @notice Mints exactly `shares` of vault's shares to `receiver` by depositing amount of underlying tokens.
    /// Returns the amount of assets that were deposited.
    /// @dev Updates the holdings state before the deposit,
    /// so that any pending gain or loss report is recent. If caller and receiver is `protocolFeeReceiver`,
    /// the balance of the `protocolFeeReceiver` might change by more than `shares`, as there might be
    /// some pending protocol fees to be collected.
    function mint(uint256 shares, address receiver) public virtual override(IERC4626) returns (uint256) {
        _updateHoldingsState();
        uint256 maxShares = maxMint(receiver);
        if (shares > maxShares) {
            revert ERC4626ExceededMaxMint(receiver, shares, maxShares);
        }

        uint256 assets =
            shares.mulDiv(totalAssets() + 1, super.totalSupply() + 10 ** _decimalsOffset(), Math.Rounding.Ceil);
        _deposit(_msgSender(), receiver, assets, shares);

        return assets;
    }

    /// @notice Burns shares from `owner` and sends exactly `assets` of underlying tokens to `receiver`.
    /// Returns the amount of shares that were burnt.
    /// @dev Updates the holdings state before the deposit, so that any pending gain or loss report is recent.
    function withdraw(uint256 assets, address receiver, address owner)
        public
        virtual
        override(IERC4626)
        returns (uint256)
    {
        _updateHoldingsState();
        uint256 maxAssets = maxWithdraw(owner);
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxWithdraw(owner, assets, maxAssets);
        }

        uint256 shares =
            assets.mulDiv(super.totalSupply() + 10 ** _decimalsOffset(), totalAssets() + 1, Math.Rounding.Ceil);
        _withdraw(_msgSender(), receiver, owner, assets, shares);

        return shares;
    }

    /// @notice  Burns exactly `shares` from `owner` and sends assets of underlying tokens to `receiver`.
    /// Returns the amount of sent assets.
    /// @dev Updates the holdings state before the deposit, so that any pending gain or loss report is recent.
    function redeem(uint256 shares, address receiver, address owner)
        public
        virtual
        override(IERC4626)
        returns (uint256)
    {
        _updateHoldingsState();
        uint256 maxShares = maxRedeem(owner);
        if (shares > maxShares) {
            revert ERC4626ExceededMaxRedeem(owner, shares, maxShares);
        }

        uint256 assets =
            shares.mulDiv(totalAssets() + 1, super.totalSupply() + 10 ** _decimalsOffset(), Math.Rounding.Floor);
        _withdraw(_msgSender(), receiver, owner, assets, shares);

        return assets;
    }

    /// @dev Deposit/mint common workflow.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal virtual {
        SafeERC20.safeTransferFrom(_getERC4626BufferedStorage().asset, caller, address(this), assets);
        _mint(receiver, shares);
        _increaseAssets(assets);
        _postDeposit(assets);

        emit Deposit(caller, receiver, assets, shares);
    }

    /// @dev Withdraw/redeem common workflow.
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        virtual
    {
        _preWithdrawal(assets);

        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }
        _burn(owner, shares);
        _decreaseAssets(assets);
        SafeERC20.safeTransfer(_getERC4626BufferedStorage().asset, receiver, assets);

        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    /// @notice Sets bps-wise protocol fee.
    /// The protocol fee is applied on the profit made, with each holdings state update.
    function setProtocolFee(uint256 feeBps) public virtual {
        require(feeBps <= MAX_BPS, IncorrectProtocolFee());
        _getERC4626BufferedStorage().protocolFeeBps = feeBps;
    }

    function setProtocolFeeReceiver(address receiver) public virtual {
        require(receiver != address(0), ZeroProtocolFeeReceiver());
        _getERC4626BufferedStorage().protocolFeeReceiver = receiver;
    }

    /// @notice Returns the protocol fee, in basis points (1 bps = 0.01%).
    function getProtocolFee() public view returns (uint256) {
        return _getERC4626BufferedStorage().protocolFeeBps;
    }

    /// @notice Returns the protocol fee receiver address.
    function getProtocolFeeReceiver() public view returns (address) {
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
