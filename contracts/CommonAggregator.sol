// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {ICommonAggregator} from "./interfaces/ICommonAggregator.sol";
import {CommonTimelocks} from "./CommonTimelocks.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
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
import {CommonTimelocks} from "./CommonTimelocks.sol";

contract CommonAggregator is
    ICommonAggregator,
    CommonTimelocks,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ERC4626BufferedUpgradeable,
    PausableUpgradeable
{
    using Math for uint256;
    using SafeERC20 for IERC20;
    using SafeERC20 for IERC4626;

    bytes32 public constant OWNER = keccak256("OWNER");
    bytes32 public constant MANAGER = keccak256("MANAGER");
    bytes32 public constant REBALANCER = keccak256("REBALANCER");
    bytes32 public constant GUARDIAN = keccak256("GUARDIAN");

    uint256 public constant MAX_VAULTS = 5;
    uint256 public constant MAX_PROTOCOL_FEE_BPS = MAX_BPS / 2;

    uint256 public constant SET_TRADER_TIMELOCK = 5 days;
    uint256 public constant ADD_VAULT_TIMELOCK = 7 days;
    uint256 public constant FORCE_REMOVE_VAULT_TIMELOCK = 14 days;

    enum TimelockTypes {
        SET_TRADER,
        ADD_VAULT,
        FORCE_REMOVE_VAULT
    }

    /// @custom:storage-location erc7201:common.storage.aggregator
    struct AggregatorStorage {
        IERC4626[] vaults; // Both for iterating and a fallback queue.
        mapping(address vault => uint256 limit) allocationLimitBps;
        mapping(address rewardToken => address traderAddress) rewardTrader;
        uint256 pendingVaultForceRemovals;
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

    function initialize(address owner, IERC20Metadata asset, IERC4626[] memory vaults) public initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ERC20_init(string.concat("Common-Aggregator-", asset.name(), "-v1"), string.concat("ca", asset.symbol()));
        // TODO: set meaningful address here
        __ERC4626Buffered_init(asset, address(1));

        _grantRole(DEFAULT_ADMIN_ROLE, owner);
        _grantRole(OWNER, owner);

        AggregatorStorage storage $ = _getAggregatorStorage();

        for (uint256 i = 0; i < vaults.length; i++) {
            _ensureVaultCanBeAdded(vaults[i]);
            $.vaults.push(vaults[i]);
            $.allocationLimitBps[address(vaults[i])] = MAX_BPS;
        }
    }

    function _ensureVaultCanBeAdded(IERC4626 vault) private view {
        require(address(vault) != address(0), VaultAddressCantBeZero());
        require(asset() == vault.asset(), IncorrectAsset(asset(), vault.asset()));

        AggregatorStorage storage $ = _getAggregatorStorage();
        require($.vaults.length < MAX_VAULTS, VaultLimitExceeded());
        require(!_isVaultOnTheList(vault), VaultAlreadyAdded(vault));
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

    /// @notice Submits a timelocked proposal to add a new vault to the list.
    /// @dev There's no limit on the number of pending vaults that can be added, only on the number of fully added vaults.
    /// Manager or Guardian should cancel mistaken and stale submissions.
    function submitAddVault(IERC4626 vault)
        external
        override
        onlyManagerOrOwner
        registersTimelockedAction(keccak256(abi.encode(TimelockTypes.ADD_VAULT, vault)), ADD_VAULT_TIMELOCK)
    {
        _ensureVaultCanBeAdded(vault);

        emit VaultAdditionSubmitted(address(vault), block.timestamp + ADD_VAULT_TIMELOCK);
    }

    function cancelAddVault(IERC4626 vault)
        external
        override
        onlyGuardianOrHigherRole
        cancelsAction(keccak256(abi.encode(TimelockTypes.ADD_VAULT, vault)))
    {
        emit VaultAdditionCancelled(address(vault));
    }

    function addVault(IERC4626 vault)
        external
        override
        onlyManagerOrOwner
        executesUnlockedAction(keccak256(abi.encode(TimelockTypes.ADD_VAULT, vault)))
    {
        _ensureVaultCanBeAdded(vault);
        AggregatorStorage storage $ = _getAggregatorStorage();
        $.vaults.push(vault);
        updateHoldingsState();

        emit VaultAdded(address(vault));
    }

    function removeVault(IERC4626 vault) external override onlyManagerOrOwner {
        (bool isVaultOnTheList,) = _getVaultIndex(vault);
        require(isVaultOnTheList, VaultNotOnTheList(vault));
        require(
            !_isTimelockedActionRegistered(keccak256(abi.encode(TimelockTypes.FORCE_REMOVE_VAULT, vault))),
            PendingVaultForceRemoval(vault)
        );

        // No need to updateHoldingsState, as we're not operating on assets.
        vault.redeem(vault.balanceOf(address(this)), address(this), address(this));

        _removeVault(vault);

        // No need to updateHoldingsState again, as we don't have any shares of the vault anymore.
        emit VaultRemoved(address(vault));
    }

    /// @notice Removes vault from the list, without any timelocks or checks other than
    /// the presence of the vault on the list. Updates storage and removes vault from mappings.
    function _removeVault(IERC4626 vault) internal {
        (bool isVaultOnTheList, uint256 index) = _getVaultIndex(vault);
        require(isVaultOnTheList, VaultNotOnTheList(vault));

        AggregatorStorage storage $ = _getAggregatorStorage();

        delete $.allocationLimitBps[address(vault)];

        // Remove the vault from the list, shifting the rest of the array.
        for (uint256 i = index; i < $.vaults.length - 1; i++) {
            $.vaults[i] = $.vaults[i + 1];
        }
        $.vaults.pop();
    }

    /// @inheritdoc ICommonAggregator
    function submitForceRemoveVault(IERC4626 vault)
        external
        override
        onlyManagerOrOwner
        registersTimelockedAction(
            keccak256(abi.encode(TimelockTypes.FORCE_REMOVE_VAULT, vault)),
            FORCE_REMOVE_VAULT_TIMELOCK
        )
    {
        (bool isVaultOnTheList,) = _getVaultIndex(vault);
        require(isVaultOnTheList, VaultNotOnTheList(vault));

        // Try redeeming as much shares of the removed vault as possible
        try vault.maxRedeem(address(this)) returns (uint256 redeemableShares) {
            try vault.redeem(redeemableShares, address(this), address(this)) {} catch {}
        } catch {}

        if (!paused()) {
            pauseUserInteractions();
        }

        _getAggregatorStorage().pendingVaultForceRemovals++;
        emit VaultForceRemovalSubmitted(address(vault), block.timestamp + FORCE_REMOVE_VAULT_TIMELOCK);
    }

    /// @inheritdoc ICommonAggregator
    function cancelForceRemoveVault(IERC4626 vault)
        external
        override
        onlyGuardianOrHigherRole
        cancelsAction(keccak256(abi.encode(TimelockTypes.FORCE_REMOVE_VAULT, vault)))
    {
        _getAggregatorStorage().pendingVaultForceRemovals--;
        emit VaultForceRemovalCancelled(address(vault));
    }

    /// @inheritdoc ICommonAggregator
    function forceRemoveVault(IERC4626 vault)
        external
        override
        onlyManagerOrOwner
        executesUnlockedAction(keccak256(abi.encode(TimelockTypes.FORCE_REMOVE_VAULT, vault)))
    {
        _removeVault(vault);

        // Some assets were lost, so we have to update the holdings state.
        updateHoldingsState();

        _getAggregatorStorage().pendingVaultForceRemovals--;
        emit VaultForceRemoved(address(vault));
    }
    // ----- Rebalancing -----

    /// @inheritdoc ICommonAggregator
    function pushFunds(uint256 assets, IERC4626 vault) external onlyRebalancerOrHigherRole whenNotPaused {
        updateHoldingsState();
        require(_isVaultOnTheList(vault), VaultNotOnTheList(vault));

        IERC20(asset()).approve(address(vault), assets);
        vault.deposit(assets, address(this));
        _checkLimit(IERC4626(vault));

        emit AssetsRebalanced(address(this), address(vault), assets);
    }

    /// @inheritdoc ICommonAggregator
    function pullFunds(uint256 assets, IERC4626 vault) external onlyRebalancerOrHigherRole {
        require(_isVaultOnTheList(vault), VaultNotOnTheList(vault));

        IERC4626(vault).withdraw(assets, address(this), address(this));

        emit AssetsRebalanced(address(vault), address(this), assets);
    }

    /// @inheritdoc ICommonAggregator
    function pullFundsByShares(uint256 shares, IERC4626 vault) external onlyRebalancerOrHigherRole {
        require(_isVaultOnTheList(vault), VaultNotOnTheList(vault));

        uint256 assets = vault.redeem(shares, address(this), address(this));

        emit AssetsRebalanced(address(vault), address(this), assets);
    }

    // ----- Allocation Limits -----

    /// @inheritdoc ICommonAggregator
    /// @notice Doesn't rebalance the assets, after the action limits may be exceeded.
    function setLimit(IERC4626 vault, uint256 newLimitBps) external override onlyRole(OWNER) {
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
    function setProtocolFee(uint256 protocolFeeBps) external onlyRole(OWNER) {
        require(protocolFeeBps <= MAX_PROTOCOL_FEE_BPS, ProtocolFeeTooHigh());

        ERC4626BufferedStorage storage buffer$ = _getERC4626BufferedStorage();
        uint256 oldProtocolFee = buffer$.protocolFeeBps;

        if (oldProtocolFee == protocolFeeBps) return;
        buffer$.protocolFeeBps = protocolFeeBps;
        emit ProtocolFeeChanged(oldProtocolFee, protocolFeeBps);
    }

    /// @inheritdoc ICommonAggregator
    function setProtocolFeeReceiver(address protocolFeeReceiver) external onlyRole(OWNER) {
        require(protocolFeeReceiver != address(this), SelfProtocolFeeReceiver());
        require(protocolFeeReceiver != address(0), ZeroProtocolFeeReceiver());

        ERC4626BufferedStorage storage buffer$ = _getERC4626BufferedStorage();
        address oldProtocolFeeReceiver = buffer$.protocolFeeReceiver;

        if (oldProtocolFeeReceiver == protocolFeeReceiver) return;
        buffer$.protocolFeeReceiver = protocolFeeReceiver;
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
    function submitSetRewardTrader(address rewardToken, address traderAddress)
        external
        onlyManagerOrOwner
        registersTimelockedAction(
            keccak256(abi.encode(TimelockTypes.SET_TRADER, rewardToken, traderAddress)),
            SET_TRADER_TIMELOCK
        )
    {
        _ensureTokenSafeToTransfer(rewardToken);

        emit SetRewardsTraderSubmitted(rewardToken, traderAddress, block.timestamp + SET_TRADER_TIMELOCK);
    }

    /// @inheritdoc ICommonAggregator
    function setRewardTrader(address rewardToken, address traderAddress)
        external
        onlyManagerOrOwner
        executesUnlockedAction(keccak256(abi.encode(TimelockTypes.SET_TRADER, rewardToken, traderAddress)))
    {
        _ensureTokenSafeToTransfer(rewardToken);
        AggregatorStorage storage $ = _getAggregatorStorage();
        $.rewardTrader[rewardToken] = traderAddress;

        emit RewardsTraderSet(rewardToken, traderAddress);
    }

    /// @inheritdoc ICommonAggregator
    function cancelSetRewardTrader(address rewardToken, address traderAddress)
        external
        onlyGuardianOrHigherRole
        cancelsAction(keccak256(abi.encode(TimelockTypes.SET_TRADER, rewardToken, traderAddress)))
    {
        emit SetRewardsTraderCancelled(rewardToken, traderAddress);
    }

    /// @inheritdoc ICommonAggregator
    function transferRewardsForSale(address rewardToken) external {
        _ensureTokenSafeToTransfer(rewardToken);
        AggregatorStorage storage $ = _getAggregatorStorage();
        require($.rewardTrader[rewardToken] != address(0), NoTraderSetForToken(rewardToken));

        IERC20 transferrableToken = IERC20(rewardToken);
        uint256 amount = transferrableToken.balanceOf(address(this));
        address receiver = $.rewardTrader[rewardToken];

        SafeERC20.safeTransfer(transferrableToken, receiver, amount);

        emit RewardsTransferred(rewardToken, amount, receiver);
    }

    function _ensureTokenSafeToTransfer(address rewardToken) internal view {
        require(rewardToken != asset(), InvalidRewardToken(rewardToken));
        require(!_isVaultOnTheList(IERC4626(rewardToken)), InvalidRewardToken(rewardToken));
        require(rewardToken != address(this), InvalidRewardToken(rewardToken));
        require(
            !_isTimelockedActionRegistered(keccak256(abi.encode(TimelockTypes.ADD_VAULT, rewardToken))),
            InvalidRewardToken(rewardToken)
        );
    }

    // ----- Pausing user interactions -----

    /// @notice Pauses user interactions including deposit, mint, withdraw, and redeem. Callable by the guardian,
    /// the manager or the owner. To be used in case of an emergency. Users can still use emergencyWithdraw
    /// to exit the aggregator.
    function pauseUserInteractions() public onlyGuardianOrHigherRole {
        _pause();
    }

    /// @notice Unpauses user interactions including deposit, mint, withdraw, and redeem. Callable by the guardian,
    /// the manager or the owner. To be used after mitigating a potential emergency.
    function unpauseUserInteractions() public onlyGuardianOrHigherRole {
        uint256 pendingVaultForceRemovals = _getAggregatorStorage().pendingVaultForceRemovals;
        require(pendingVaultForceRemovals == 0, PendingVaultForceRemovals(pendingVaultForceRemovals));
        _unpause();
    }

    error PendingVaultForceRemovals(uint256 count);

    // ----- Etc -----

    constructor() {
        _disableInitializers();
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(OWNER) {}

    modifier onlyRebalancerOrHigherRole() {
        if (!hasRole(REBALANCER, msg.sender) && !hasRole(MANAGER, msg.sender) && !hasRole(OWNER, msg.sender)) {
            revert CallerNotRebalancerOrWithHigherRole();
        }
        _;
    }

    modifier onlyAggregator() {
        require(msg.sender == address(this), CallerNotAggregator());
        _;
    }

    modifier onlyGuardianOrHigherRole() {
        if (!hasRole(GUARDIAN, msg.sender) && !hasRole(MANAGER, msg.sender) && !hasRole(OWNER, msg.sender)) {
            revert CallerNotGuardianOrWithHigherRole();
        }
        _;
    }

    modifier onlyManagerOrOwner() {
        if (!hasRole(MANAGER, msg.sender) && !hasRole(OWNER, msg.sender)) {
            revert CallerNotManagerNorOwner();
        }
        _;
    }
}
