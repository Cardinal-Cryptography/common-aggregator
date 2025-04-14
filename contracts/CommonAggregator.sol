// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {
    ERC4626BufferedUpgradeable,
    IERC20,
    IERC4626,
    IERC20Metadata,
    Math,
    SafeERC20
} from "./ERC4626BufferedUpgradeable.sol";
import {ICommonAggregator} from "./interfaces/ICommonAggregator.sol";
import {MAX_BPS, saturatingAdd, saturatingSub} from "./Math.sol";

/// @notice Common Aggregator contract, extending the `ERC4626BufferedUpgradeable`. Provides all the necessary logic for
/// the aggregation, leaving the role management to the `CommonManagement` contract.
contract CommonAggregator is
    ICommonAggregator,
    UUPSUpgradeable,
    ERC4626BufferedUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    using Math for uint256;
    using SafeERC20 for IERC20;

    /// @notice The maximum number of vaults that can be present at the same time in the aggregator.
    uint256 public constant MAX_VAULTS = 5;

    /// @notice The maximum protocol fee, in basis poins, that can be set by the *Management*.
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
        __ReentrancyGuard_init();
        __Pausable_init();

        AggregatorStorage storage $ = _getAggregatorStorage();
        $.management = management;

        for (uint256 i = 0; i < vaults.length; ++i) {
            ensureVaultCanBeAdded(vaults[i]);
            $.vaults.push(vaults[i]);
            $.allocationLimitBps[address(vaults[i])] = MAX_BPS;
        }
    }

    /// @notice Ensures that the vault can be added to the aggregator. Reverts if it can't.
    function ensureVaultCanBeAdded(IERC4626 vault) public view {
        require(asset() == vault.asset(), IncorrectAsset(asset(), vault.asset()));
        require(_getAggregatorStorage().vaults.length < MAX_VAULTS, VaultLimitExceeded());
        require(!_isVaultOnTheList(vault), VaultAlreadyAdded(vault));
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
        return super.maxWithdraw(owner).min(_availableFunds());
    }

    /// @inheritdoc ERC4626BufferedUpgradeable
    /// @dev Returns 0 when the contract is paused. Users can use `emergencyRedeem` to exit the aggregator instead.
    function maxRedeem(address owner) public view override(ERC4626BufferedUpgradeable, IERC4626) returns (uint256) {
        if (paused()) {
            return 0;
        }
        // Avoid overflow
        uint256 availableConvertedToShares =
            convertToShares(_availableFunds().min(type(uint256).max / 10 ** _decimalsOffset()));
        return super.maxRedeem(owner).min(availableConvertedToShares);
    }

    function _availableFunds() internal view returns (uint256) {
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

    /// @inheritdoc ERC4626BufferedUpgradeable
    function _postDeposit(uint256 assets) internal override {
        AggregatorStorage storage $ = _getAggregatorStorage();
        uint256 cachedTotalAssets = totalAssets();
        if (cachedTotalAssets > 0) {
            for (uint256 i = 0; i < $.vaults.length; ++i) {
                IERC4626 vault = $.vaults[i];
                uint256 assetsToDepositToVault = assets.mulDiv(_aggregatedVaultAssets(vault), cachedTotalAssets);
                uint256 maxVaultDeposit = vault.maxDeposit(address(this));
                uint256 depositAmount = assetsToDepositToVault.min(maxVaultDeposit);
                IERC20(asset()).approve(address(vault), depositAmount);
                vault.deposit(depositAmount, address(this));
                emit DepositedToVault(address(vault), assetsToDepositToVault, depositAmount);
            }
        }
    }

    /// @inheritdoc ERC4626BufferedUpgradeable
    function _preWithdrawal(uint256 assets) internal override {
        try CommonAggregator(address(this)).pullFundsProportional(assets) {}
        catch {
            emit ProportionalWithdrawalFailed(assets);
            _pullFundsSequential(assets);
        }
    }

    /// @dev Function is exposed as external but only callable by aggregator, because we want to be able
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

    function _decimalsOffset() internal view override returns (uint8) {
        return uint8(Math.min(6, saturatingSub(18, _getERC4626BufferedStorage().underlyingDecimals)));
    }

    // ----- Emergency redeem -----

    /// @inheritdoc ICommonAggregator
    function emergencyRedeem(uint256 shares, address account, address owner)
        external
        nonReentrant
        returns (uint256 assets, uint256[] memory vaultShares)
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
        vaultShares = new uint256[]($.vaults.length);
        uint256 valueInAssets = assets;

        for (uint256 i = 0; i < $.vaults.length; ++i) {
            IERC4626 vault = $.vaults[i];
            vaultShares[i] = shares.mulDiv(vault.balanceOf(address(this)), totalShares);
            valueInAssets += vault.convertToAssets(vaultShares[i]);
            // Reentracy could happen, so reentrant lock is needed.
            // This should also include locking adding and removing vaults.
            IERC20(vault).safeTransfer(account, vaultShares[i]);
        }

        _decreaseAssets(valueInAssets);

        IERC20(asset()).safeTransfer(account, assets);

        emit EmergencyWithdraw(msg.sender, account, owner, assets, shares, vaultShares);
    }

    /// @notice Returns the maximum amount of shares that can be emergency-redeemed by the given owner.
    function maxEmergencyRedeem(address owner) public view returns (uint256) {
        return super.maxRedeem(owner);
    }

    // ----- Reporting -----

    /// @notice Updates the holdings state of the aggregator.
    function updateHoldingsState() external nonReentrant {
        _updateHoldingsState();
    }

    function _totalAssetsNotCached() internal view override returns (uint256) {
        AggregatorStorage storage $ = _getAggregatorStorage();

        uint256 assets = IERC20(asset()).balanceOf(address(this));
        for (uint256 i = 0; i < $.vaults.length; ++i) {
            assets += _aggregatedVaultAssets(IERC4626($.vaults[i]));
        }
        return assets;
    }

    function _aggregatedVaultAssets(IERC4626 vault) internal view returns (uint256) {
        uint256 shares = vault.balanceOf(address(this));
        return vault.convertToAssets(shares);
    }

    // ----- Aggregated vaults management -----

    function addVault(IERC4626 vault) external override onlyManagement nonReentrant {
        ensureVaultCanBeAdded(vault);
        AggregatorStorage storage $ = _getAggregatorStorage();
        $.vaults.push(vault);
        _updateHoldingsState();

        emit VaultAdded(address(vault));
    }

    function removeVault(IERC4626 vault) external override onlyManagement nonReentrant {
        uint256 index = ensureVaultIsPresent(vault);

        // No need to updateHoldingsState, as we're not operating on assets.
        vault.redeem(vault.balanceOf(address(this)), address(this), address(this));
        _removeVault(index);

        emit VaultRemoved(address(vault));
    }

    /// @inheritdoc ICommonAggregator
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
    /// @dev Reverts only if the vault is not present on the list.
    function tryExitVault(IERC4626 vault) external onlyManagement nonReentrant {
        ensureVaultIsPresent(vault);

        // Try redeeming as much shares of the removed vault as possible
        try vault.maxRedeem(address(this)) returns (uint256 redeemableShares) {
            try vault.redeem(redeemableShares, address(this), address(this)) {} catch {}
        } catch {}
    }

    /// @notice Checks if the vault is on the list of (fully-added) aggregated vaults currently. Reverts if it isn't.
    /// Returns the index of the vault in the list.
    function ensureVaultIsPresent(IERC4626 vault) public view returns (uint256) {
        (bool isVaultOnTheList, uint256 index) = _getVaultIndex(vault);
        require(isVaultOnTheList, VaultNotOnTheList(vault));
        return index;
    }

    /// @notice Returns true iff the vault is on the list of (fully-added) aggregated vaults currently.
    function _isVaultOnTheList(IERC4626 vault) internal view returns (bool) {
        (bool isVaultOnTheList,) = _getVaultIndex(vault);
        return isVaultOnTheList;
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

    /// @inheritdoc ICommonAggregator
    function pushFunds(uint256 assets, IERC4626 vault) external onlyManagement whenNotPaused nonReentrant {
        _updateHoldingsState();
        ensureVaultIsPresent(vault);
        IERC20(asset()).approve(address(vault), assets);
        vault.deposit(assets, address(this));
        _checkLimit(IERC4626(vault));

        emit AssetsRebalanced(address(this), address(vault), assets);
    }

    /// @inheritdoc ICommonAggregator
    function pullFunds(uint256 assets, IERC4626 vault) external onlyManagement nonReentrant {
        ensureVaultIsPresent(vault);
        IERC4626(vault).withdraw(assets, address(this), address(this));

        emit AssetsRebalanced(address(vault), address(this), assets);
    }

    /// @inheritdoc ICommonAggregator
    function pullFundsByShares(uint256 shares, IERC4626 vault) external onlyManagement nonReentrant {
        ensureVaultIsPresent(vault);
        uint256 assets = vault.redeem(shares, address(this), address(this));

        emit AssetsRebalanced(address(vault), address(this), assets);
    }

    // ----- Allocation Limits -----

    /// @inheritdoc ICommonAggregator
    /// @notice Doesn't rebalance the assets, after the action limits may be exceeded.
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

    /// @inheritdoc ICommonAggregator
    function setProtocolFee(uint256 protocolFeeBps)
        public
        override(ERC4626BufferedUpgradeable, ICommonAggregator)
        onlyManagement
        nonReentrant
    {
        require(protocolFeeBps <= MAX_PROTOCOL_FEE_BPS, ProtocolFeeTooHigh());

        uint256 oldProtocolFee = getProtocolFee();
        if (oldProtocolFee == protocolFeeBps) return;

        super.setProtocolFee(protocolFeeBps);

        emit ProtocolFeeChanged(oldProtocolFee, protocolFeeBps);
    }

    /// @inheritdoc ICommonAggregator
    function setProtocolFeeReceiver(address protocolFeeReceiver)
        public
        override(ERC4626BufferedUpgradeable, ICommonAggregator)
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

    /// @inheritdoc ICommonAggregator
    function transferRewardsForSale(address rewardToken, address rewardTrader) external onlyManagement nonReentrant {
        ensureTokenSafeToTransfer(rewardToken);
        IERC20 transferrableToken = IERC20(rewardToken);
        uint256 amount = transferrableToken.balanceOf(address(this));
        transferrableToken.safeTransfer(rewardTrader, amount);

        emit RewardsTransferred(rewardToken, amount, rewardTrader);
    }

    function ensureTokenSafeToTransfer(address rewardToken) public view {
        require(rewardToken != asset(), InvalidRewardToken(rewardToken));
        require(!_isVaultOnTheList(IERC4626(rewardToken)), InvalidRewardToken(rewardToken));
        require(rewardToken != address(this), InvalidRewardToken(rewardToken));
    }

    // ----- Pausing user interactions -----

    /// @notice Pauses user interactions including deposit, mint, withdraw, and redeem. Callable by the guardian,
    /// the manager or the owner. To be used in case of an emergency. Users can still use emergencyRedeem
    /// to exit the aggregator.
    function pauseUserInteractions() public onlyManagement {
        _pause();
    }

    /// @notice Unpauses user interactions including deposit, mint, withdraw, and redeem. Callable by the guardian,
    /// the manager or the owner. To be used after mitigating a potential emergency.
    function unpauseUserInteractions() public onlyManagement {
        _unpause();
    }

    // ----- Etc -----

    function getVaults() external view returns (IERC4626[] memory) {
        return _getAggregatorStorage().vaults;
    }

    function getMaxAllocationLimit(IERC4626 vault) external view returns (uint256) {
        return _getAggregatorStorage().allocationLimitBps[address(vault)];
    }

    function _getAggregatorStorage() private pure returns (AggregatorStorage storage $) {
        assembly {
            $.slot := AGGREGATOR_STORAGE_LOCATION
        }
    }
}
