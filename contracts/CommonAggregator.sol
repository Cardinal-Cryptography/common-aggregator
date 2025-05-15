// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardTransientUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {
    ERC4626BufferedUpgradeable,
    IERC20,
    IERC4626,
    IERC4626Buffered,
    IERC20Metadata,
    Math,
    SafeERC20
} from "./ERC4626BufferedUpgradeable.sol";
import {ICommonAggregator} from "./interfaces/ICommonAggregator.sol";
import {MAX_BPS, saturatingAdd} from "./Math.sol";

/// @notice Common Aggregator contract, extending the `ERC4626BufferedUpgradeable`. Provides all the necessary logic for
/// the aggregation, leaving the role management to the `CommonManagement` contract.
contract CommonAggregator is
    ICommonAggregator,
    UUPSUpgradeable,
    ERC4626BufferedUpgradeable,
    ReentrancyGuardTransientUpgradeable,
    PausableUpgradeable
{
    using Math for uint256;
    using SafeERC20 for IERC20;

    /// @notice The maximum number of vaults that can be present at the same time in the aggregator.
    uint256 public constant MAX_VAULTS = 8;

    /// @notice The maximum protocol fee, in basis points, that can be set by the *Management*.
    uint256 public constant MAX_PROTOCOL_FEE_BPS = MAX_BPS / 2;

    /// @custom:storage-location erc7201:common.storage.aggregator
    struct AggregatorStorage {
        IERC4626[] vaults; // Both for iterating and a fallback queue.
        mapping(address vault => uint256 limit) allocationLimitBps;
        address management;
    }

    /// @notice ERC-7201 storage location for the `CommonAggregator`: the `AggregatorStorage` struct.
    // keccak256(abi.encode(uint256(keccak256("common.storage.aggregator")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant AGGREGATOR_STORAGE_LOCATION =
        0x1344fc1d9208ab003bf22755fd527b5337aabe73460e3f8720ef6cfd49b61d00;

    /// @notice Modifier ensuring only the *Management* contract can call the function.
    modifier onlyManagement() {
        AggregatorStorage storage $ = _getAggregatorStorage();
        require(msg.sender == $.management, CallerNotManagement());
        _;
    }

    /// @dev Constructor disabling the initializer, as per OpenZeppelin's UUPS pattern.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializer for the `CommonAggregator` contract, called by the proxy.
    /// @param management The address of the *Management* - usually the `CommonManagement` contract.
    /// @param asset The address of the underlying ERC20 token. It must implement the `IERC20Metadata` interface.
    /// @param vaults The list of ERC4626 vaults to be aggregated initially. Vaults must aggregate the same `asset`,
    /// and be already initialized.
    function initialize(address management, IERC20Metadata asset, IERC4626[] memory vaults) public initializer {
        __UUPSUpgradeable_init();
        __ERC20_init(string.concat("Common-Aggregator-", asset.name()), string.concat("ca", asset.symbol()));
        __ERC4626Buffered_init(asset);
        __ReentrancyGuardTransient_init();
        __Pausable_init();

        AggregatorStorage storage $ = _getAggregatorStorage();
        $.management = management;

        for (uint256 i = 0; i < vaults.length; ++i) {
            ensureVaultCanBeAdded(vaults[i]);
            $.vaults.push(vaults[i]);
            $.allocationLimitBps[address(vaults[i])] = MAX_BPS;
        }
    }

    /// @notice Ensures that the vault can be added to the aggregator, checking if the `asset` is the same,
    /// if the vault is not already present on the list, and if the maximum number of vaults wouldn't be exceeded.
    function ensureVaultCanBeAdded(IERC4626 vault) public view {
        require(asset() == vault.asset(), IncorrectAsset(asset(), vault.asset()));
        require(_getAggregatorStorage().vaults.length < MAX_VAULTS, VaultLimitExceeded());
        require(address(vault) != address(this), VaultIsAggregator());
        require(!isVaultOnTheList(vault), VaultAlreadyAdded(vault));
    }

    /// @notice Called by the proxy to authorize the upgrade. Reverts if the caller is not the *Management*.
    function _authorizeUpgrade(address newImplementation) internal override onlyManagement {}

    // ----- ERC4626 -----

    /// @inheritdoc ERC4626BufferedUpgradeable
    /// @dev Returns 0 when the contract is paused.
    function maxDeposit(address owner) public view override(ERC4626BufferedUpgradeable, IERC4626) returns (uint256) {
        if (paused()) {
            return 0;
        }
        return super.maxDeposit(owner);
    }

    /// @inheritdoc ERC4626BufferedUpgradeable
    /// @dev Returns 0 when the contract is paused.
    function maxMint(address owner) public view override(ERC4626BufferedUpgradeable, IERC4626) returns (uint256) {
        if (paused()) {
            return 0;
        }
        return super.maxMint(owner);
    }

    /// @inheritdoc ERC4626BufferedUpgradeable
    /// @dev Returns 0 when the contract is paused. Users can use `emergencyRedeem` to exit the aggregator instead.
    function maxWithdraw(address owner) public view override(ERC4626BufferedUpgradeable, IERC4626) returns (uint256) {
        if (paused()) {
            return 0;
        }
        return super.maxWithdraw(owner);
    }

    /// @inheritdoc ERC4626BufferedUpgradeable
    /// @dev Returns 0 when the contract is paused. Users can use `emergencyRedeem` to exit the aggregator instead.
    function maxRedeem(address owner) public view override(ERC4626BufferedUpgradeable, IERC4626) returns (uint256) {
        if (paused()) {
            return 0;
        }
        return super.maxRedeem(owner);
    }

    /// @inheritdoc ERC4626BufferedUpgradeable
    /// @dev Assumes that the `maxWithdraw` amounts in each vaults are independent of each other.
    function _totalMaxWithdraw() internal view override returns (uint256) {
        AggregatorStorage storage $ = _getAggregatorStorage();
        uint256 availableFunds = IERC20(asset()).balanceOf(address(this));

        for (uint256 i = 0; i < $.vaults.length; ++i) {
            // ERC-4626 requires `maxWithdraw` and `maxRedeem` to be non-reverting.
            // We want to ensure that this requirement is fulfilled, even if one of the
            // aggregated vaults does not respect it and reverts on `maxWithdraw`.
            try $.vaults[i].maxWithdraw(address(this)) returns (uint256 pullableFunds) {
                availableFunds = saturatingAdd(availableFunds, pullableFunds);
            } catch {}
        }

        return availableFunds;
    }

    /// @inheritdoc ERC4626BufferedUpgradeable
    function deposit(uint256 assets, address receiver)
        public
        override(ERC4626BufferedUpgradeable, IERC4626)
        whenNotPaused
        nonReentrant
        returns (uint256)
    {
        return super.deposit(assets, receiver);
    }

    /// @inheritdoc ERC4626BufferedUpgradeable
    function mint(uint256 shares, address receiver)
        public
        override(ERC4626BufferedUpgradeable, IERC4626)
        whenNotPaused
        nonReentrant
        returns (uint256)
    {
        return super.mint(shares, receiver);
    }

    /// @inheritdoc ERC4626BufferedUpgradeable
    function withdraw(uint256 assets, address receiver, address owner)
        public
        override(ERC4626BufferedUpgradeable, IERC4626)
        whenNotPaused
        nonReentrant
        returns (uint256)
    {
        return super.withdraw(assets, receiver, owner);
    }

    /// @inheritdoc ERC4626BufferedUpgradeable
    function redeem(uint256 shares, address receiver, address owner)
        public
        override(ERC4626BufferedUpgradeable, IERC4626)
        whenNotPaused
        nonReentrant
        returns (uint256)
    {
        return super.redeem(shares, receiver, owner);
    }

    /// @notice ERC4626BufferedUpgradeable's hook called after the deposit is made,
    /// depositing the assets to aggregated vaults, proportionally to their current allocation.
    /// @dev If one of the aggregated vault's `maxDeposit` prevents depositing the full amount,
    /// the rest is left in the aggregator.
    function _postDeposit(uint256 assets) internal override {
        AggregatorStorage storage $ = _getAggregatorStorage();
        uint256 totalAssetsWithoutDeposit = totalAssets() - assets;
        if (totalAssetsWithoutDeposit > 0) {
            for (uint256 i = 0; i < $.vaults.length; ++i) {
                IERC4626 vault = $.vaults[i];
                uint256 assetsToDepositToVault = assets.mulDiv(_aggregatedVaultAssets(vault), totalAssetsWithoutDeposit);
                uint256 maxVaultDeposit = vault.maxDeposit(address(this));
                uint256 depositAmount = assetsToDepositToVault.min(maxVaultDeposit);
                IERC20(asset()).approve(address(vault), depositAmount);
                vault.deposit(depositAmount, address(this));
                emit DepositedToVault(address(vault), assetsToDepositToVault, depositAmount);
            }
        }
    }

    /// @notice ERC4626BufferedUpgradeable's hook called before the withdrawal is made
    /// (but after updating the holdings state). It tries to withdraw the assets from aggregated vaults
    /// proportionally to their current allocation. If it fails, it falls back to sequential withdrawal,
    /// starting from idle assets.
    function _preWithdrawal(uint256 assets) internal override {
        try CommonAggregator(address(this)).pullFundsProportional(assets) {}
        catch {
            emit ProportionalWithdrawalFailed(assets);
            _pullFundsSequential(assets);
        }
    }

    /// @notice Withdraws `assetsRequired` from aggregated vaults and from the aggregator's balance,
    /// proportionally to their current allocation. Reverts if any of the withdrawals revert for any reason.
    /// @dev Can pull one more asset than needed from each vault, due to the rounding.
    /// Function is exposed as external but only callable by aggregator, because we want to be able
    /// to easily revert all changes in case of it's failure - it is not possible for internal functions.
    function pullFundsProportional(uint256 assetsRequired) external {
        require(msg.sender == address(this), CallerNotAggregator());
        require(totalAssets() != 0, NotEnoughFunds());

        AggregatorStorage storage $ = _getAggregatorStorage();

        for (uint256 i = 0; i < $.vaults.length; ++i) {
            uint256 pullAmount =
                assetsRequired.mulDiv(_aggregatedVaultAssets($.vaults[i]), totalAssets(), Math.Rounding.Ceil);
            $.vaults[i].withdraw(pullAmount, address(this), address(this));
        }
    }

    /// @notice Withdraws assets from aggregated vaults sequentially, making sure there are at least
    /// `assetsRequired` assets in the aggregator's balance.
    /// @dev Upon error on withdrawal from one of the aggregated vaults,
    /// the error is logged and the withdrawal continues.
    function _pullFundsSequential(uint256 assetsRequired) internal {
        AggregatorStorage storage $ = _getAggregatorStorage();

        uint256 currentIdle = IERC20(asset()).balanceOf(address(this));
        uint256 assetsToPull = assetsRequired - assetsRequired.min(currentIdle);

        for (uint256 i = 0; i < $.vaults.length && assetsToPull > 0; ++i) {
            IERC4626 vault = $.vaults[i];
            uint256 vaultMaxWithdraw = vault.maxWithdraw(address(this));
            uint256 assetsToPullFromVault = assetsToPull.min(vaultMaxWithdraw);
            try vault.withdraw(assetsToPullFromVault, address(this), address(this)) {
                assetsToPull -= assetsToPullFromVault;
            } catch {
                emit VaultWithdrawFailed(vault);
            }
        }

        // Fail if too little assets were withdrawn.
        if (assetsToPull > 0) {
            revert InsufficientAssetsForWithdrawal(assetsToPull);
        }
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return 4;
    }

    // ----- Emergency redeem -----

    /// @notice Burns exactly `shares` from `owner` and sends proportional amounts of aggregated vaults' shares
    /// and idle assets to `account`. This function can be called even if the contract is paused.
    ///
    /// @param shares Amount of shares to be redeemed.
    /// @param account Account that will receive the assets and the aggregated vaults' shares.
    /// @param owner Owner of the shares that will be burnt.
    ///
    /// @return assets Amount of the underlying assets transferred to the `receiver`
    /// @return vaultsShares List of the aggregated vaults' shares amounts that were transferred to the `receiver`.
    function emergencyRedeem(uint256 shares, address account, address owner)
        external
        nonReentrant
        returns (uint256 assets, uint256[] memory vaultsShares)
    {
        _updateHoldingsState();
        uint256 maxShares = maxEmergencyRedeem(owner);
        if (shares > maxShares) {
            revert ERC4626ExceededMaxRedeem(owner, shares, maxShares);
        }
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        uint256 totalShares = totalSupply();
        _burn(owner, shares);

        assets = shares.mulDiv(IERC20(asset()).balanceOf(address(this)), totalShares);

        AggregatorStorage storage $ = _getAggregatorStorage();
        vaultsShares = new uint256[]($.vaults.length);
        uint256 valueInAssets = assets;

        for (uint256 i = 0; i < $.vaults.length; ++i) {
            IERC4626 vault = $.vaults[i];
            vaultsShares[i] = shares.mulDiv(vault.balanceOf(address(this)), totalShares);
            valueInAssets += vault.convertToAssets(vaultsShares[i]);
            // Reentracy could happen, so reentrant lock is needed.
            // This should also include locking adding and removing vaults.
            IERC20(vault).safeTransfer(account, vaultsShares[i]);
        }

        _decreaseAssets(valueInAssets);

        IERC20(asset()).safeTransfer(account, assets);

        emit EmergencyWithdraw(msg.sender, account, owner, assets, shares, vaultsShares);
    }

    /// @notice Returns the maximum amount of shares that can be emergency-redeemed by the given owner.
    function maxEmergencyRedeem(address owner) public view returns (uint256) {
        return balanceOf(owner);
    }

    // ----- Reporting -----

    /// @notice Updates holdings state of the aggregator, accounting for any gains or losses in vaults,
    /// as well as for any possible donations. Profits are smoothed out by the reward buffer,
    /// and distributed to the holders over time.
    /// Protocol fee is taken from the profits. Potential losses are first covered by the buffer.
    /// @dev Makes sure `_totalAssetsNotCached()` and `totalAssets()` are equal, and the correct
    /// amount of aggregator's shares are minted or burned in the reward buffer.
    /// Additionally, it may be called by an off-chain component at times
    /// when difference between `totalAssets()` and `_totalAssetsNotCached()` becomes significant.
    function updateHoldingsState() external override nonReentrant {
        _updateHoldingsState();
    }

    /// @notice Hook called to get the actual number of assets held by the aggregator,
    /// both in idle assets and in aggregated vaults.
    function _totalAssetsNotCached() internal view override returns (uint256) {
        AggregatorStorage storage $ = _getAggregatorStorage();

        uint256 assets = IERC20(asset()).balanceOf(address(this));
        for (uint256 i = 0; i < $.vaults.length; ++i) {
            assets += _aggregatedVaultAssets(IERC4626($.vaults[i]));
        }
        return assets;
    }

    /// @notice Returns the value in `asset` of the shares of `vault` held by the aggregator.
    function _aggregatedVaultAssets(IERC4626 vault) internal view returns (uint256) {
        uint256 shares = vault.balanceOf(address(this));
        return vault.convertToAssets(shares);
    }

    // ----- Aggregated vaults management -----

    /// @notice Adds `vault` to the list of aggregated vaults, with the allocation
    /// limit set to 0.
    /// @dev Reverts if the vault is already present on the list, or if the
    /// `MAX_VAULTS` limit would be exceeded.
    function addVault(IERC4626 vault) external override onlyManagement nonReentrant {
        ensureVaultCanBeAdded(vault);
        AggregatorStorage storage $ = _getAggregatorStorage();
        $.vaults.push(vault);
        _updateHoldingsState();

        emit VaultAdded(address(vault));
    }

    /// @notice Removes `vault` from the list, redeeming all of its shares held by the aggregator.
    /// @dev Reverts if redeeming all of the shares can't be done.
    function removeVault(IERC4626 vault) external override onlyManagement nonReentrant {
        uint256 index = ensureVaultIsPresent(vault);

        // No need to updateHoldingsState, as we're not operating on assets.
        vault.redeem(vault.balanceOf(address(this)), address(this), address(this));
        _removeVault(index);

        emit VaultRemoved(address(vault));
    }

    /// @notice Removes `vault` from the list, losing all non-redeemed assets.
    /// @dev Management contract should implement extra checks and timelocks to prevent
    /// unwanted force removals.
    function forceRemoveVault(IERC4626 vault) external override onlyManagement nonReentrant {
        uint256 index = ensureVaultIsPresent(vault);
        _removeVault(index);

        // Some assets were lost, so we have to update the holdings state.
        _updateHoldingsState();

        emit VaultForceRemoved(address(vault));
    }

    /// @notice Removes vault from the list by the given index in the vaults array, without any checks.
    /// Updates the storage and removes the vault from mappings.
    function _removeVault(uint256 index) internal {
        AggregatorStorage storage $ = _getAggregatorStorage();

        delete $.allocationLimitBps[address($.vaults[index])];

        // Remove the vault from the list, shifting the rest of the array.
        for (uint256 i = index; i < $.vaults.length - 1; ++i) {
            $.vaults[i] = $.vaults[i + 1];
        }

        $.vaults.pop();
    }

    /// @notice Tries to redeem as many shares as possible from the given vault.
    /// @dev Reverts only if the vault is not present on the list, including the case
    /// when the `vault` can revert on any of the calls.
    function tryExitVault(IERC4626 vault) external override onlyManagement nonReentrant {
        ensureVaultIsPresent(vault);

        // Try redeeming as much shares of the removed vault as possible
        try vault.maxRedeem(address(this)) returns (uint256 redeemableShares) {
            try vault.redeem(redeemableShares, address(this), address(this)) {} catch {}
        } catch {}
    }

    /// @notice Checks if the vault is on the list of (fully-added) aggregated vaults currently. Reverts if it isn't.
    /// Returns the index of the vault in the list.
    function ensureVaultIsPresent(IERC4626 vault) public view returns (uint256) {
        (bool onTheList, uint256 index) = _getVaultIndex(vault);
        require(onTheList, VaultNotOnTheList(vault));
        return index;
    }

    /// @notice Returns true iff the vault is on the list of (fully-added) aggregated vaults currently.
    function isVaultOnTheList(IERC4626 vault) public view override returns (bool) {
        (bool vaultOnTheList,) = _getVaultIndex(vault);
        return vaultOnTheList;
    }

    function _getVaultIndex(IERC4626 vault) internal view returns (bool onTheList, uint256 index) {
        AggregatorStorage storage $ = _getAggregatorStorage();

        for (uint256 i = 0; i < $.vaults.length; ++i) {
            if ($.vaults[i] == vault) {
                return (true, i);
            }
        }
        return (false, 0);
    }

    // ----- Rebalancing -----

    /// @notice Rebalances assets by depositing `assets` from aggregator's own balance into `vault`.
    /// Vault must be present on the vault list. Allocation limits are checked.
    function pushFunds(uint256 assets, IERC4626 vault) external onlyManagement whenNotPaused nonReentrant {
        _updateHoldingsState();
        ensureVaultIsPresent(vault);
        IERC20(asset()).approve(address(vault), assets);
        vault.deposit(assets, address(this));
        _checkLimit(IERC4626(vault));

        emit AssetsRebalanced(address(this), address(vault), assets);
    }

    /// @notice Rebalances assets by withdrawing `assets` from `vault` into aggregator's own balance.
    /// Vault must be present on the vault list.
    /// @dev Doesn't check the allocation limits, as even if they are still
    /// exceeded, the total excess will be lowered.
    function pullFunds(uint256 assets, IERC4626 vault) external onlyManagement nonReentrant {
        ensureVaultIsPresent(vault);
        IERC4626(vault).withdraw(assets, address(this), address(this));

        emit AssetsRebalanced(address(vault), address(this), assets);
    }

    /// @notice Rebalances assets by redeeming `shares` from `vault`, returning assets into
    /// aggregator's own balance. Vault must be present on the vault list.
    /// @dev Similarly to `pullFunds`, doesn't check the allocation limits.
    function pullFundsByShares(uint256 shares, IERC4626 vault) external onlyManagement nonReentrant {
        ensureVaultIsPresent(vault);
        uint256 assets = vault.redeem(shares, address(this), address(this));

        emit AssetsRebalanced(address(vault), address(this), assets);
    }

    // ----- Allocation Limits -----

    /// @notice Sets allocation limit of `vault` to `newLimitBps`.
    /// The limit is expressed in bps, and is applied to the assets.
    /// @dev It's a no-op if `newLimitBps` is the same as the current limit.
    /// Reverts if `newLimitBps` is higher MAX_BPS, or if `vault` is not present
    /// on the vault list.
    /// Doesn't rebalance the assets, after the action limits may be exceeded.
    function setLimit(IERC4626 vault, uint256 newLimitBps) external override onlyManagement nonReentrant {
        require(newLimitBps <= MAX_BPS, IncorrectMaxAllocationLimit());
        ensureVaultIsPresent(vault);

        AggregatorStorage storage $ = _getAggregatorStorage();
        uint256 oldLimit = $.allocationLimitBps[address(vault)];

        if (oldLimit == newLimitBps) return;

        $.allocationLimitBps[address(vault)] = newLimitBps;

        emit AllocationLimitSet(address(vault), newLimitBps);
    }

    /// @notice Checks if the allocation limit is not exceeded for the given vault.
    /// Doesn't update the holdings state - the caller should decide when to do it.
    /// @dev Results in undefined behavior if the vault is not on the list.
    function _checkLimit(IERC4626 vault) internal view {
        AggregatorStorage storage $ = _getAggregatorStorage();
        uint256 assets = vault.convertToAssets(vault.balanceOf(address(this)));
        uint256 total = totalAssets();

        require(assets <= total.mulDiv($.allocationLimitBps[address(vault)], MAX_BPS), AllocationLimitExceeded(vault));
    }

    // ----- Fee management -----

    /// @notice Sets bps-wise protocol fee.
    /// The protocol fee is applied on the profit made, with each holdings state update.
    function setProtocolFee(uint256 protocolFeeBps)
        public
        override(ERC4626BufferedUpgradeable, IERC4626Buffered)
        onlyManagement
        nonReentrant
    {
        require(protocolFeeBps <= MAX_PROTOCOL_FEE_BPS, ProtocolFeeTooHigh());

        uint256 oldProtocolFee = getProtocolFee();
        if (oldProtocolFee == protocolFeeBps) return;

        super.setProtocolFee(protocolFeeBps);

        emit ProtocolFeeChanged(oldProtocolFee, protocolFeeBps);
    }

    /// @notice Sets the protocol fee receiver.
    /// Has to be different from the aggregator itself, and from the zero address.
    function setProtocolFeeReceiver(address protocolFeeReceiver)
        public
        override(ERC4626BufferedUpgradeable, IERC4626Buffered)
        onlyManagement
        nonReentrant
    {
        require(protocolFeeReceiver != address(this), SelfProtocolFeeReceiver());

        address oldProtocolFeeReceiver = getProtocolFeeReceiver();
        if (oldProtocolFeeReceiver == protocolFeeReceiver) return;

        super.setProtocolFeeReceiver(protocolFeeReceiver);

        emit ProtocolFeeReceiverChanged(oldProtocolFeeReceiver, protocolFeeReceiver);
    }

    // ----- Non-asset rewards trading -----

    /// @notice Transfers all `rewardToken`s held in the aggregator to `rewardTrader`.
    /// @dev The `rewardTrader` should handle trading the given token for asset and
    /// send it back to the aggregator. The communication between these two contracts
    /// is done simply via an async ERC20's transfer calls.
    function transferRewardsForSale(address rewardToken, address rewardTrader) external onlyManagement nonReentrant {
        ensureTokenIsNotInherentlyUsed(rewardToken);
        IERC20 transferrableToken = IERC20(rewardToken);
        uint256 amount = transferrableToken.balanceOf(address(this));
        transferrableToken.safeTransfer(rewardTrader, amount);

        emit RewardsTransferred(rewardToken, amount, rewardTrader);
    }

    /// @notice Reverts if `token` is the asset, one of the aggregated vaults share,
    /// or the aggregator share itself.
    function ensureTokenIsNotInherentlyUsed(address token) public view override {
        require(token != asset(), InvalidRewardToken(token));
        require(!isVaultOnTheList(IERC4626(token)), InvalidRewardToken(token));
        require(token != address(this), InvalidRewardToken(token));
    }

    // ----- Pausing user interactions -----

    /// @notice Pauses user interactions including `deposit`, `mint`, `withdraw`, `redeem`,
    /// and also management's `pushFunds`.
    /// To be used in case of an emergency. Users can still use `emergencyRedeem`
    /// to exit the aggregator.
    function pauseUserInteractions() public override onlyManagement {
        _pause();
    }

    /// @notice Unpauses user interactions. To be used after mitigating a potential emergency.
    function unpauseUserInteractions() public override onlyManagement {
        _unpause();
    }

    function paused() public view override(ICommonAggregator, PausableUpgradeable) returns (bool) {
        return super.paused();
    }

    // ----- Etc -----

    /// @notice Returns the list of aggregated vaults.
    function getVaults() external view returns (IERC4626[] memory) {
        return _getAggregatorStorage().vaults;
    }

    /// @notice Returns the allocation limit of the given vault, in basis points.
    function getMaxAllocationLimit(IERC4626 vault) external view returns (uint256) {
        return _getAggregatorStorage().allocationLimitBps[address(vault)];
    }

    function getManagement() external view returns (address) {
        return _getAggregatorStorage().management;
    }

    function _getAggregatorStorage() private pure returns (AggregatorStorage storage $) {
        assembly {
            $.slot := AGGREGATOR_STORAGE_LOCATION
        }
    }
}
