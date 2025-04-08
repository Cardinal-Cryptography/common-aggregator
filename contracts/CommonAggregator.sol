// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {ICommonAggregator} from "./interfaces/ICommonAggregator.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    IERC20,
    IERC4626,
    IERC20Metadata,
    SafeERC20,
    ERC20Upgradeable,
    ERC4626BufferedUpgradeable
} from "./ERC4626BufferedUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MAX_BPS} from "./Math.sol";
import {ERC4626BufferedUpgradeable} from "./ERC4626BufferedUpgradeable.sol";

contract CommonAggregator is ICommonAggregator, UUPSUpgradeable, ERC4626BufferedUpgradeable, PausableUpgradeable {
    using Math for uint256;
    using SafeERC20 for IERC20;
    using SafeERC20 for IERC4626;

    uint256 public constant MAX_VAULTS = 5;
    uint256 public constant MAX_PROTOCOL_FEE_BPS = MAX_BPS / 2;

    /// @custom:storage-location erc7201:common.storage.aggregator
    struct AggregatorStorage {
        IERC4626[] vaults; // Both for iterating and a fallback queue.
        mapping(address vault => uint256 limit) allocationLimitBps;
        address management;
    }

    // keccak256(abi.encode(uint256(keccak256("common.storage.aggregator")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant AGGREGATOR_STORAGE_LOCATION =
        0x1344fc1d9208ab003bf22755fd527b5337aabe73460e3f8720ef6cfd49b61d00;

    function _getAggregatorStorage() private pure returns (AggregatorStorage storage $) {
        assembly {
            $.slot := AGGREGATOR_STORAGE_LOCATION
        }
    }

    function getVaults() external view returns (IERC4626[] memory) {
        AggregatorStorage storage $ = _getAggregatorStorage();
        return $.vaults;
    }

    function getMaxAllocationLimit(IERC4626 vault) external view returns (uint256) {
        AggregatorStorage storage $ = _getAggregatorStorage();
        return $.allocationLimitBps[address(vault)];
    }

    function initialize(address management, IERC20Metadata asset, IERC4626[] memory vaults) public initializer {
        __UUPSUpgradeable_init();
        __ERC20_init(string.concat("Common-Aggregator-", asset.name(), "-v1"), string.concat("ca", asset.symbol()));
        __ERC4626Buffered_init(asset);
        __Pausable_init();

        AggregatorStorage storage $ = _getAggregatorStorage();
        $.management = management;

        for (uint256 i = 0; i < vaults.length; i++) {
            ensureVaultCanBeAdded(vaults[i]);
            $.vaults.push(vaults[i]);
            $.allocationLimitBps[address(vaults[i])] = MAX_BPS;
        }
    }

    function ensureVaultCanBeAdded(IERC4626 vault) public view {
        require(asset() == vault.asset(), IncorrectAsset(asset(), vault.asset()));

        AggregatorStorage storage $ = _getAggregatorStorage();
        require($.vaults.length < MAX_VAULTS, VaultLimitExceeded());
        require(!_isVaultOnTheList(vault), VaultAlreadyAdded(vault));
    }

    function ensureVaultIsPresent(IERC4626 vault) public view returns (uint256) {
        (bool isVaultOnTheList, uint256 index) = _getVaultIndex(vault);
        require(isVaultOnTheList, VaultNotOnTheList(vault));
        return index;
    }

    function ensureTokenSafeToTransfer(address rewardToken) public view {
        require(rewardToken != asset(), InvalidRewardToken(rewardToken));
        require(!_isVaultOnTheList(IERC4626(rewardToken)), InvalidRewardToken(rewardToken));
        require(rewardToken != address(this), InvalidRewardToken(rewardToken));
    }

    // ----- ERC4626 -----

    function _decimalsOffset() internal pure override returns (uint8) {
        return 4;
    }

    /// @inheritdoc IERC4626
    /// @notice Returns the maximum deposit amount of the given address at the current time.
    function maxDeposit(address owner) public view override(ERC4626BufferedUpgradeable, IERC4626) returns (uint256) {
        if (paused()) {
            return 0;
        }
        return super.maxDeposit(owner);
    }

    /// @inheritdoc IERC4626
    /// @notice Returns the maximum mint amount of the given address at the current time.
    function maxMint(address owner) public view override(ERC4626BufferedUpgradeable, IERC4626) returns (uint256) {
        if (paused()) {
            return 0;
        }
        return super.maxMint(owner);
    }

    /// @inheritdoc IERC4626
    /// @notice Returns the maximum withdraw amount of the given address at the current time.
    function maxWithdraw(address owner) public view override(ERC4626BufferedUpgradeable, IERC4626) returns (uint256) {
        if (paused()) {
            return 0;
        }
        return super.maxWithdraw(owner).min(_availableFunds());
    }

    /// @inheritdoc IERC4626
    /// @notice Returns the maximum redeem amount of the given address at the current time.
    function maxRedeem(address owner) public view override(ERC4626BufferedUpgradeable, IERC4626) returns (uint256) {
        if (paused()) {
            return 0;
        }
        return super.maxRedeem(owner).min(convertToShares(_availableFunds()));
    }

    function _availableFunds() internal view returns (uint256) {
        AggregatorStorage storage $ = _getAggregatorStorage();
        uint256 availableFunds = IERC20(asset()).balanceOf(address(this));

        for (uint256 i = 0; i < $.vaults.length; ++i) {
            // ERC-4626 requires `maxWithdraw` and `maxRedeem` to be non-reverting.
            // We want to ensure that this requirement is fulfilled, even if one of the
            // aggregated vaults does not respect it and reverts on `maxWithdraw`.
            try $.vaults[i].maxWithdraw(address(this)) returns (uint256 pullableFunds) {
                availableFunds += pullableFunds;
            } catch {}
        }

        return availableFunds;
    }

    /// @inheritdoc IERC4626
    function deposit(uint256 assets, address receiver)
        public
        virtual
        override(ERC4626BufferedUpgradeable, IERC4626)
        whenNotPaused
        returns (uint256)
    {
        return super.deposit(assets, receiver);
    }

    /// @inheritdoc IERC4626
    function mint(uint256 shares, address receiver)
        public
        virtual
        override(ERC4626BufferedUpgradeable, IERC4626)
        whenNotPaused
        returns (uint256)
    {
        return super.mint(shares, receiver);
    }

    /// @inheritdoc IERC4626
    function withdraw(uint256 assets, address receiver, address owner)
        public
        virtual
        override(ERC4626BufferedUpgradeable, IERC4626)
        whenNotPaused
        returns (uint256)
    {
        return super.withdraw(assets, receiver, owner);
    }

    /// @inheritdoc IERC4626
    function redeem(uint256 shares, address receiver, address owner)
        public
        virtual
        override(ERC4626BufferedUpgradeable, IERC4626)
        whenNotPaused
        returns (uint256)
    {
        return super.redeem(shares, receiver, owner);
    }

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

    function _preWithdrawal(uint256 assets) internal override {
        try CommonAggregator(address(this)).pullFundsProportional(assets) {}
        catch {
            emit ProportionalWithdrawalFailed(assets);
            _pullFundsSequential(assets);
        }
    }

    /// @dev Function is exposed as external but only callable by aggregator, because we want to be able
    /// to easily revert all changes in case of it's failure - it is not possible for internal functions.
    function pullFundsProportional(uint256 assetsRequired) external onlyAggregator {
        require(totalAssets() != 0, NotEnoughFunds());

        IERC20 asset = IERC20(asset());
        uint256 idle = asset.balanceOf(address(this));
        uint256 amountIdle = assetsRequired.mulDiv(idle, totalAssets());

        AggregatorStorage storage $ = _getAggregatorStorage();
        uint256[] memory amountsVaults = new uint256[]($.vaults.length);

        uint256 totalGathered = amountIdle;
        for (uint256 i = 0; i < $.vaults.length; ++i) {
            amountsVaults[i] = assetsRequired.mulDiv(_aggregatedVaultAssets($.vaults[i]), totalAssets());
            totalGathered += amountsVaults[i];
        }

        if (totalGathered < assetsRequired) {
            uint256 missing = assetsRequired - totalGathered;
            uint256 additionalIdleContribution = missing.min(idle - amountIdle);
            missing -= additionalIdleContribution;
            amountIdle += additionalIdleContribution;

            for (uint256 i = 0; i < $.vaults.length && missing > 0; ++i) {
                uint256 vaultMaxWithdraw = $.vaults[i].maxWithdraw(address(this));
                require(
                    amountsVaults[i] <= vaultMaxWithdraw,
                    AggregatedVaultWithdrawalLimitExceeded(address($.vaults[i]), vaultMaxWithdraw, amountsVaults[i])
                );
                uint256 additionalVaultContribution = missing.min(vaultMaxWithdraw - amountsVaults[i]);
                missing -= additionalVaultContribution;
                amountsVaults[i] += additionalVaultContribution;
            }

            require(missing == 0, NotEnoughFunds());
        }

        for (uint256 i = 0; i < $.vaults.length; ++i) {
            uint256 shares = $.vaults[i].convertToShares(amountsVaults[i]);
            $.vaults[i].approve(address($.vaults[i]), shares);
            $.vaults[i].withdraw(amountsVaults[i], address(this), address(this));
        }
    }

    function _pullFundsSequential(uint256 assetsRequired) internal {
        AggregatorStorage storage $ = _getAggregatorStorage();

        uint256 currentIdle = IERC20(asset()).balanceOf(address(this));
        uint256 assetsToPull = assetsRequired - assetsRequired.min(currentIdle);

        for (uint256 i = 0; i < $.vaults.length && assetsToPull > 0; i++) {
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

    // TODO: make sure deposits / withdrawals from protocolReceiver are handled correctly

    // ----- Emergency redeem -----

    function maxEmergencyRedeem(address owner) public view returns (uint256) {
        return super.maxRedeem(owner);
    }

    /// @inheritdoc ICommonAggregator
    function emergencyRedeem(uint256 shares, address account, address owner)
        external
        returns (uint256 assets, uint256[] memory vaultShares)
    {
        uint256 maxShares = maxEmergencyRedeem(owner);
        if (shares > maxShares) {
            revert ERC4626ExceededMaxRedeem(owner, shares, maxShares);
        }
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }
        updateHoldingsState();

        uint256 totalShares = totalSupply();
        _burn(owner, shares);

        assets = shares.mulDiv(IERC20(asset()).balanceOf(address(this)), totalShares);
        IERC20(asset()).safeTransfer(account, assets);

        AggregatorStorage storage $ = _getAggregatorStorage();
        vaultShares = new uint256[]($.vaults.length);
        uint256 valueInAssets = assets;
        for (uint256 i = 0; i < $.vaults.length; i++) {
            vaultShares[i] = shares.mulDiv($.vaults[i].balanceOf(address(this)), totalShares);
            valueInAssets += $.vaults[i].convertToAssets(vaultShares[i]);
            $.vaults[i].safeTransfer(account, vaultShares[i]);
        }

        _decreaseAssets(valueInAssets);

        emit EmergencyWithdraw(msg.sender, account, owner, assets, shares, vaultShares);
    }

    // ----- Reporting -----

    function _totalAssetsNotCached() internal view override returns (uint256) {
        AggregatorStorage storage $ = _getAggregatorStorage();

        uint256 assets = IERC20(asset()).balanceOf(address(this));
        for (uint256 i = 0; i < $.vaults.length; i++) {
            assets += _aggregatedVaultAssets(IERC4626($.vaults[i]));
        }
        return assets;
    }

    function _aggregatedVaultAssets(IERC4626 vault) internal view returns (uint256) {
        uint256 shares = vault.balanceOf(address(this));
        return vault.convertToAssets(shares);
    }

    // ----- Aggregated vaults management -----

    function addVault(IERC4626 vault) external override onlyManagement {
        ensureVaultCanBeAdded(vault);
        AggregatorStorage storage $ = _getAggregatorStorage();
        $.vaults.push(vault);
        updateHoldingsState();

        emit VaultAdded(address(vault));
    }

    function removeVault(IERC4626 vault) external override onlyManagement {
        uint256 index = ensureVaultIsPresent(vault);

        // No need to updateHoldingsState, as we're not operating on assets.
        vault.redeem(vault.balanceOf(address(this)), address(this), address(this));
        _removeVault(index);

        emit VaultRemoved(address(vault));
    }

    /// @inheritdoc ICommonAggregator
    function forceRemoveVault(IERC4626 vault) external override onlyManagement {
        uint256 index = ensureVaultIsPresent(vault);
        _removeVault(index);

        // Some assets were lost, so we have to update the holdings state.
        updateHoldingsState();

        emit VaultForceRemoved(address(vault));
    }

    /// Tries to redeem as many shares as possible from the given vault.
    /// Reverts only if the vault is not present on the list.
    function tryExitVault(IERC4626 vault) external onlyManagement {
        ensureVaultIsPresent(vault);

        // Try redeeming as much shares of the removed vault as possible
        try vault.maxRedeem(address(this)) returns (uint256 redeemableShares) {
            try vault.redeem(redeemableShares, address(this), address(this)) {} catch {}
        } catch {}
    }

    /// @notice Removes vault from the list by the given index in the vaults array, without any checks.
    /// Updates the storage and removes the vault from mappings.
    function _removeVault(uint256 index) internal {
        AggregatorStorage storage $ = _getAggregatorStorage();

        delete $.allocationLimitBps[address($.vaults[index])];

        // Remove the vault from the list, shifting the rest of the array.
        for (uint256 i = index; i < $.vaults.length - 1; i++) {
            $.vaults[i] = $.vaults[i + 1];
        }

        $.vaults.pop();
    }

    // ----- Rebalancing -----

    /// @inheritdoc ICommonAggregator
    function pushFunds(uint256 assets, IERC4626 vault) external onlyManagement whenNotPaused {
        updateHoldingsState();
        require(_isVaultOnTheList(vault), VaultNotOnTheList(vault));
        IERC20(asset()).approve(address(vault), assets);
        vault.deposit(assets, address(this));
        _checkLimit(IERC4626(vault));

        emit AssetsRebalanced(address(this), address(vault), assets);
    }

    /// @inheritdoc ICommonAggregator
    function pullFunds(uint256 assets, IERC4626 vault) external onlyManagement {
        require(_isVaultOnTheList(vault), VaultNotOnTheList(vault));
        IERC4626(vault).withdraw(assets, address(this), address(this));

        emit AssetsRebalanced(address(vault), address(this), assets);
    }

    /// @inheritdoc ICommonAggregator
    function pullFundsByShares(uint256 shares, IERC4626 vault) external onlyManagement {
        require(_isVaultOnTheList(vault), VaultNotOnTheList(vault));
        uint256 assets = vault.redeem(shares, address(this), address(this));

        emit AssetsRebalanced(address(vault), address(this), assets);
    }

    // ----- Allocation Limits -----

    /// @inheritdoc ICommonAggregator
    /// @notice Doesn't rebalance the assets, after the action limits may be exceeded.
    function setLimit(IERC4626 vault, uint256 newLimitBps) external override onlyManagement {
        require(newLimitBps <= MAX_BPS, IncorrectMaxAllocationLimit());
        require(_isVaultOnTheList(vault), VaultNotOnTheList(vault));

        AggregatorStorage storage $ = _getAggregatorStorage();
        uint256 oldLimit = $.allocationLimitBps[address(vault)];

        if (oldLimit == newLimitBps) return;

        $.allocationLimitBps[address(vault)] = newLimitBps;

        emit AllocationLimitSet(address(vault), newLimitBps);
    }

    // ----- Fee management -----

    /// @inheritdoc ICommonAggregator
    function setProtocolFee(uint256 protocolFeeBps)
        public
        override(ERC4626BufferedUpgradeable, ICommonAggregator)
        onlyManagement
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
    {
        require(protocolFeeReceiver != address(this), SelfProtocolFeeReceiver());

        address oldProtocolFeeReceiver = getProtocolFeeReceiver();
        if (oldProtocolFeeReceiver == protocolFeeReceiver) return;

        super.setProtocolFeeReceiver(protocolFeeReceiver);

        emit ProtocolFeeReceiverChanged(oldProtocolFeeReceiver, protocolFeeReceiver);
    }

    function _isVaultOnTheList(IERC4626 vault) internal view returns (bool onTheList) {
        (onTheList,) = _getVaultIndex(vault);
    }

    function _getVaultIndex(IERC4626 vault) internal view returns (bool onTheList, uint256 index) {
        AggregatorStorage storage $ = _getAggregatorStorage();

        for (uint256 i = 0; i < $.vaults.length; i++) {
            if ($.vaults[i] == vault) {
                return (true, i);
            }
        }
        return (false, 0);
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

    // ----- Non-asset rewards trading -----

    /// @inheritdoc ICommonAggregator
    function transferRewardsForSale(address rewardToken, address rewardTrader) external onlyManagement {
        ensureTokenSafeToTransfer(rewardToken);
        IERC20 transferrableToken = IERC20(rewardToken);
        uint256 amount = transferrableToken.balanceOf(address(this));
        SafeERC20.safeTransfer(transferrableToken, rewardTrader, amount);

        emit RewardsTransferred(rewardToken, amount, rewardTrader);
    }

    // ----- Pausing user interactions -----

    /// @notice Pauses user interactions including deposit, mint, withdraw, and redeem. Callable by the guardian,
    /// the manager or the owner. To be used in case of an emergency. Users can still use emergencyWithdraw
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

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyManagement {}

    modifier onlyAggregator() {
        require(msg.sender == address(this), CallerNotAggregator());
        _;
    }

    modifier onlyManagement() {
        AggregatorStorage storage $ = _getAggregatorStorage();
        require(msg.sender == $.management, CallerNotManagement());
        _;
    }
}
