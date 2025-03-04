// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {ICommonAggregator} from "./interfaces/ICommonAggregator.sol";
import {CommonTimelocks} from "./CommonTimelocks.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IERC20, ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {
    IERC4626,
    ERC4626Upgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MAX_BPS} from "./Math.sol";
import "./RewardBuffer.sol";

contract CommonAggregator is
    ICommonAggregator,
    CommonTimelocks,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ERC4626Upgradeable
{
    using RewardBuffer for RewardBuffer.Buffer;
    using Math for uint256;

    bytes32 public constant OWNER = keccak256("OWNER");
    bytes32 public constant MANAGER = keccak256("MANAGER");
    bytes32 public constant REBALANCER = keccak256("REBALANCER");
    bytes32 public constant GUARDIAN = keccak256("GUARDIAN");

    uint256 public constant MAX_VAULTS = 5;
    uint256 public constant MAX_PROTOCOL_FEE_BPS = MAX_BPS / 2;

    uint256 public constant ADD_VAULT_TIMELOCK = 7 days;
    uint256 public constant FORCE_REMOVE_VAULT_TIMELOCK = 7 days;

    enum TimelockTypes {
        ADD_VAULT,
        FORCE_REMOVE_VAULT
    }

    /// @custom:storage-location erc7201:common.storage.aggregator
    struct AggregatorStorage {
        RewardBuffer.Buffer rewardBuffer;
        IERC4626[] vaults; // Both for iterating and a fallback queue.
        mapping(address vault => uint256 limit) allocationLimitBps;
        uint256 protocolFeeBps;
        address protocolFeeReceiver;
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
        __ERC4626_init(asset);

        _grantRole(DEFAULT_ADMIN_ROLE, owner);
        _grantRole(OWNER, owner);

        AggregatorStorage storage $ = _getAggregatorStorage();

        for (uint256 i = 0; i < vaults.length; i++) {
            _ensureVaultCanBeAdded(vaults[i]);
            $.vaults.push(vaults[i]);
            $.allocationLimitBps[address(vaults[i])] = MAX_BPS;
        }

        $.protocolFeeBps = 0;
        $.protocolFeeReceiver = address(1);
    }

    function _ensureVaultCanBeAdded(IERC4626 vault) private view {
        require(address(vault) != address(0), VaultAddressCantBeZero());
        require(asset() == vault.asset(), IncorrectAsset(asset(), vault.asset()));

        AggregatorStorage storage $ = _getAggregatorStorage();
        require($.vaults.length < MAX_VAULTS, VaultLimitExceeded());
        require(!_isVaultOnTheList(vault), VaultAlreadyAded(vault));
    }

    // ----- ERC4626 -----

    function _decimalsOffset() internal pure override returns (uint8) {
        return 4;
    }

    /// @inheritdoc IERC4626
    /// @notice Returns cached assets from the last holdings state update.
    function totalAssets() public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        AggregatorStorage storage $ = _getAggregatorStorage();
        return $.rewardBuffer._getAssetsCached();
    }

    /// @inheritdoc IERC4626
    /// @dev Updates holdings state before the preview.
    function previewDeposit(uint256 assets) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        (uint256 newTotalAssets, uint256 newTotalSupply) = _previewUpdateHoldingsState();
        return assets.mulDiv(newTotalSupply + 10 ** _decimalsOffset(), newTotalAssets + 1, Math.Rounding.Floor);
    }

    /// @inheritdoc IERC4626
    /// @dev Updates holdings state before the preview.
    function previewMint(uint256 shares) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        (uint256 newTotalAssets, uint256 newTotalSupply) = _previewUpdateHoldingsState();
        return shares.mulDiv(newTotalAssets + 1, newTotalSupply + 10 ** _decimalsOffset(), Math.Rounding.Ceil);
    }

    /// @inheritdoc IERC4626
    /// @dev Updates holdings state before the preview.
    function previewWithdraw(uint256 assets) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        (uint256 newTotalAssets, uint256 newTotalSupply) = _previewUpdateHoldingsState();
        return assets.mulDiv(newTotalSupply + 10 ** _decimalsOffset(), newTotalAssets + 1, Math.Rounding.Ceil);
    }

    /// @inheritdoc IERC4626
    /// @dev Updates holdings state before the preview.
    function previewRedeem(uint256 shares) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        (uint256 newTotalAssets, uint256 newTotalSupply) = _previewUpdateHoldingsState();
        return shares.mulDiv(newTotalAssets + 1, newTotalSupply + 10 ** _decimalsOffset(), Math.Rounding.Floor);
    }

    /// @inheritdoc IERC4626
    /// @notice Updates holdings state before depositing.
    function deposit(uint256 assets, address account) public override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        updateHoldingsState();
        uint256 shares = super.deposit(assets, account);

        AggregatorStorage storage $ = _getAggregatorStorage();
        _distributeToVaults(assets);
        $.rewardBuffer._increaseAssets(assets);

        return shares;
    }

    /// @inheritdoc IERC4626
    /// @notice Updates holdings state before minting.
    function mint(uint256 shares, address account) public override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        updateHoldingsState();
        uint256 assets = super.mint(shares, account);

        AggregatorStorage storage $ = _getAggregatorStorage();
        _distributeToVaults(assets);
        $.rewardBuffer._increaseAssets(assets);

        return assets;
    }

    function _distributeToVaults(uint256 assets) internal {
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

    /// @inheritdoc IERC4626
    /// @notice Updates holdings state before withdrawing.
    function withdraw(uint256 assets, address account, address owner)
        public
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256)
    {
        updateHoldingsState();
        uint256 shares = super.withdraw(assets, account, owner);

        AggregatorStorage storage $ = _getAggregatorStorage();
        $.rewardBuffer._decreaseAssets(assets);

        return shares;
    }

    /// @inheritdoc IERC4626
    /// @notice Updates holdings state before redeeming.
    function redeem(uint256 shares, address account, address owner)
        public
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256)
    {
        updateHoldingsState();
        uint256 assets = super.redeem(shares, account, owner);

        AggregatorStorage storage $ = _getAggregatorStorage();
        $.rewardBuffer._decreaseAssets(assets);

        return assets;
    }

    // TODO: make sure deposits / withdrawals from protocolReceiver are handled correctly

    // ----- Reporting -----

    /// @notice Updates holdinds state, by reporting on every vault how many assets it has.
    /// Profits are smoothed out by the reward buffer, and ditributed to the holders.
    /// Protocol fee is taken from the profits. Potential losses are first covered by the buffer.
    function updateHoldingsState() public override {
        AggregatorStorage storage $ = _getAggregatorStorage();
        uint256 oldCachedAssets = $.rewardBuffer._getAssetsCached();

        if (oldCachedAssets == 0) {
            // We have to wait for the deposit to happen
            return;
        } else {
            uint256 newAssets = _totalAssetsNotCached();
            (uint256 sharesToMint, uint256 sharesToBurn) =
                $.rewardBuffer._updateBuffer(newAssets, totalSupply(), $.protocolFeeBps);
            if (sharesToMint > 0) {
                uint256 feePartOfMintedShares = sharesToMint.mulDiv($.protocolFeeBps, MAX_BPS, Math.Rounding.Ceil);
                _mint(address(this), sharesToMint - feePartOfMintedShares);
                _mint($.protocolFeeReceiver, feePartOfMintedShares);
            }
            if (sharesToBurn > 0) {
                _burn(address(this), sharesToBurn);
            }
            emit HoldingsStateUpdated(oldCachedAssets, newAssets);
        }
    }

    /// @notice Preview the holdings state update, without actually updating it.
    /// Returns `totalAssets` and `totalSupply` that there would be after the update.
    function _previewUpdateHoldingsState() internal view returns (uint256 newTotalAssets, uint256 newTotalSupply) {
        AggregatorStorage storage $ = _getAggregatorStorage();
        if ($.rewardBuffer._getAssetsCached() == 0) {
            return (0, totalSupply());
        }

        newTotalAssets = _totalAssetsNotCached();
        (uint256 sharesToMint, uint256 sharesToBurn) =
            $.rewardBuffer._simulateBufferUpdate(newTotalAssets, totalSupply(), $.protocolFeeBps);
        return (newTotalAssets, totalSupply() + sharesToMint - sharesToBurn);
    }

    function _totalAssetsNotCached() internal view returns (uint256) {
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
    /// Also the same vault can be submitted multiple times, with different limits. Only one such submission can be accepted at a time.
    /// Manager or Guardian should cancel mistaken and stale submissions.
    function submitAddVault(IERC4626 vault, uint256 limit)
        external
        override
        onlyManagerOrOwner
        registersTimelockedAction(keccak256(abi.encode(TimelockTypes.ADD_VAULT, vault, limit)), ADD_VAULT_TIMELOCK)
    {
        _ensureVaultCanBeAdded(vault);
        if (limit > MAX_BPS) {
            revert IncorrectMaxAllocationLimit();
        }
        emit VaultAdditionSubmitted(address(vault), limit, block.timestamp + ADD_VAULT_TIMELOCK);
    }

    function cancelAddVault(IERC4626 vault, uint256 limit)
        external
        override
        onlyGuardianOrHigherRole
        cancelsAction(keccak256(abi.encode(TimelockTypes.ADD_VAULT, vault, limit)))
    {
        emit VaultAdditionCancelled(address(vault), limit);
    }

    function addVault(IERC4626 vault, uint256 limit)
        external
        override
        onlyManagerOrOwner
        executesUnlockedAction(keccak256(abi.encode(TimelockTypes.ADD_VAULT, vault, limit)))
    {
        _ensureVaultCanBeAdded(vault);
        if (limit > MAX_BPS) {
            revert IncorrectMaxAllocationLimit();
        }
        AggregatorStorage storage $ = _getAggregatorStorage();
        $.vaults.push(vault);
        $.allocationLimitBps[address(vault)] = limit;
        updateHoldingsState();

        emit VaultAdded(address(vault), limit);
    }

    function removeVault(IERC4626 vault) external override onlyManagerOrOwner {
        (bool isVaultOnTheList, uint256 index) = _getVaultIndex(vault);
        require(isVaultOnTheList, VaultNotOnTheList(vault));
        require(
            !_isTimelockedActionRegistered(keccak256(abi.encode(TimelockTypes.FORCE_REMOVE_VAULT, vault))),
            PendingVaultForceRemoval(vault)
        );

        // No need to updateHoldingsState, as we're not operating on assets.
        AggregatorStorage storage $ = _getAggregatorStorage();
        $.vaults[index].redeem($.vaults[index].balanceOf(address(this)), address(this), address(this));
        delete $.allocationLimitBps[address(vault)];

        // Remove the vault from the list, shifting the rest of the array.
        for (uint256 i = index; i < $.vaults.length - 1; i++) {
            $.vaults[i] = $.vaults[i + 1];
        }
        $.vaults.pop();

        // No need to updateHoldingsState again, as we don't have any shares of the vault anymore.
        emit VaultRemoved(address(vault));
    }

    // ----- Rebalancing -----

    /// @inheritdoc ICommonAggregator
    function pushFunds(uint256 assets, IERC4626 vault) external onlyRebalancerOrHigherRole {
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

        AggregatorStorage storage $ = _getAggregatorStorage();
        uint256 oldProtocolFee = $.protocolFeeBps;

        if (oldProtocolFee == protocolFeeBps) return;
        $.protocolFeeBps = protocolFeeBps;
        emit ProtocolFeeChanged(oldProtocolFee, protocolFeeBps);
    }

    /// @inheritdoc ICommonAggregator
    function setProtocolFeeReceiver(address protocolFeeReceiver) external onlyRole(OWNER) {
        require(protocolFeeReceiver != address(this), SelfProtocolFeeReceiver());
        require(protocolFeeReceiver != address(0), ZeroProtocolFeeReceiver());

        AggregatorStorage storage $ = _getAggregatorStorage();
        address oldProtocolFeeReceiver = $.protocolFeeReceiver;

        if (oldProtocolFeeReceiver == protocolFeeReceiver) return;
        $.protocolFeeReceiver = protocolFeeReceiver;
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

    modifier onlyManagerOrOwner() {
        if (!hasRole(MANAGER, msg.sender) && !hasRole(OWNER, msg.sender)) {
            revert CallerNotManagerNorOwner();
        }
        _;
    }

    modifier onlyGuardianOrHigherRole() {
        if (!hasRole(GUARDIAN, msg.sender) && !hasRole(MANAGER, msg.sender) && !hasRole(OWNER, msg.sender)) {
            revert CallerNotGuardianOrWithHigherRole();
        }
        _;
    }
}
