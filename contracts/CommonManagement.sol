// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {CommonAggregator} from "./CommonAggregator.sol";
import {ICommonManagement} from "./interfaces/ICommonManagement.sol";
import {CommonTimelocks} from "./CommonTimelocks.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IERC20, IERC4626, IERC20Metadata, SafeERC20, ERC20Upgradeable} from "./ERC4626BufferedUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MAX_BPS} from "./Math.sol";

contract CommonManagement is ICommonManagement, CommonTimelocks, UUPSUpgradeable, AccessControlUpgradeable {
    using Math for uint256;
    using SafeERC20 for IERC20;
    using SafeERC20 for IERC4626;

    bytes32 public constant OWNER = keccak256("OWNER");
    bytes32 public constant MANAGER = keccak256("MANAGER");
    bytes32 public constant REBALANCER = keccak256("REBALANCER");
    bytes32 public constant GUARDIAN = keccak256("GUARDIAN");

    uint256 public constant SET_TRADER_TIMELOCK = 5 days;
    uint256 public constant ADD_VAULT_TIMELOCK = 7 days;
    uint256 public constant FORCE_REMOVE_VAULT_TIMELOCK = 14 days;
    uint256 public constant CONTRACT_UPGRADE_TIMELOCK = 14 days;

    enum TimelockTypes {
        SET_TRADER,
        ADD_VAULT,
        FORCE_REMOVE_VAULT,
        AGGREGATOR_UPGRADE,
        MANAGEMENT_UPGRADE
    }

    /// @custom:storage-location erc7201:common.storage.aggregator
    struct ManagementStorage {
        mapping(address rewardToken => address traderAddress) rewardTrader;
        uint256 pendingVaultForceRemovals;
        CommonAggregator aggregator;
    }

    // keccak256(abi.encode(uint256(keccak256("common.storage.management")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant MANAGEMENT_STORAGE_LOCATION =
        0x0894d4114718f524787486c620e83a6cc5c3b741ebdbccc584ba82fd1c6bc200;

    function _getManagementStorage() private pure returns (ManagementStorage storage $) {
        assembly {
            $.slot := MANAGEMENT_STORAGE_LOCATION
        }
    }

    function initialize(address owner, CommonAggregator aggregator) public initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, owner);
        _grantRole(OWNER, owner);

        ManagementStorage storage $ = _getManagementStorage();
        $.aggregator = aggregator;
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
        ManagementStorage storage $ = _getManagementStorage();
        $.aggregator.ensureVaultCanBeAdded(vault);

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
        ManagementStorage storage $ = _getManagementStorage();
        $.aggregator.addVault(vault);

        emit VaultAdded(address(vault));
    }

    function removeVault(IERC4626 vault) external override onlyManagerOrOwner {
        ManagementStorage storage $ = _getManagementStorage();
        $.aggregator.removeVault(vault);

        emit VaultRemoved(address(vault));
    }

    /// @inheritdoc ICommonManagement
    function submitForceRemoveVault(IERC4626 vault)
        external
        override
        onlyManagerOrOwner
        registersTimelockedAction(
            keccak256(abi.encode(TimelockTypes.FORCE_REMOVE_VAULT, vault)),
            FORCE_REMOVE_VAULT_TIMELOCK
        )
    {
        ManagementStorage storage $ = _getManagementStorage();
        $.aggregator.ensureVaultIsPresent(vault);
        $.pendingVaultForceRemovals++;

        emit VaultForceRemovalSubmitted(address(vault), block.timestamp + FORCE_REMOVE_VAULT_TIMELOCK);
    }

    /// @inheritdoc ICommonManagement
    function cancelForceRemoveVault(IERC4626 vault)
        external
        override
        onlyGuardianOrHigherRole
        cancelsAction(keccak256(abi.encode(TimelockTypes.FORCE_REMOVE_VAULT, vault)))
    {
        ManagementStorage storage $ = _getManagementStorage();
        $.pendingVaultForceRemovals--;

        emit VaultForceRemovalCancelled(address(vault));
    }

    /// @inheritdoc ICommonManagement
    function forceRemoveVault(IERC4626 vault)
        external
        override
        onlyManagerOrOwner
        executesUnlockedAction(keccak256(abi.encode(TimelockTypes.FORCE_REMOVE_VAULT, vault)))
    {
        ManagementStorage storage $ = _getManagementStorage();
        $.aggregator.forceRemoveVault(vault);
        $.pendingVaultForceRemovals--;
        emit VaultForceRemoved(address(vault));
    }
    // ----- Rebalancing -----

    /// @inheritdoc ICommonManagement
    function pushFunds(uint256 assets, IERC4626 vault) external onlyRebalancerOrHigherRole {
        ManagementStorage storage $ = _getManagementStorage();
        $.aggregator.pushFunds(assets, vault);
        emit AssetsRebalanced(address($.aggregator), address(vault), assets);
    }

    /// @inheritdoc ICommonManagement
    function pullFunds(uint256 assets, IERC4626 vault) external onlyRebalancerOrHigherRole {
        ManagementStorage storage $ = _getManagementStorage();
        $.aggregator.pullFunds(assets, vault);
        emit AssetsRebalanced(address(vault), address($.aggregator), assets);
    }

    /// @inheritdoc ICommonManagement
    function pullFundsByShares(uint256 shares, IERC4626 vault) external onlyRebalancerOrHigherRole {
        ManagementStorage storage $ = _getManagementStorage();
        uint256 assets = $.aggregator.pullFundsByShares(shares, vault);
        emit AssetsRebalanced(address(vault), address($.aggregator), assets);
    }

    // ----- Allocation Limits -----

    /// @inheritdoc ICommonManagement
    /// @notice Doesn't rebalance the assets, after the action limits may be exceeded.
    function setLimit(IERC4626 vault, uint256 newLimitBps) external override onlyRole(OWNER) {
        ManagementStorage storage $ = _getManagementStorage();
        $.aggregator.setLimit(vault, newLimitBps);

        emit AllocationLimitSet(address(vault), newLimitBps);
    }

    // ----- Fee management -----

    /// @inheritdoc ICommonManagement
    function setProtocolFee(uint256 protocolFeeBps) public override(ICommonManagement) onlyRole(OWNER) {
        ManagementStorage storage $ = _getManagementStorage();
        uint256 oldProtocolFee = $.aggregator.getProtocolFee();
        $.aggregator.setProtocolFee(protocolFeeBps);

        emit ProtocolFeeChanged(oldProtocolFee, protocolFeeBps);
    }

    /// @inheritdoc ICommonManagement
    function setProtocolFeeReceiver(address protocolFeeReceiver) public override(ICommonManagement) onlyRole(OWNER) {
        ManagementStorage storage $ = _getManagementStorage();
        address oldProtocolFeeReceiver = $.aggregator.getProtocolFeeReceiver();
        $.aggregator.setProtocolFeeReceiver(protocolFeeReceiver);

        emit ProtocolFeeReceiverChanged(oldProtocolFeeReceiver, protocolFeeReceiver);
    }

    // ----- Non-asset rewards trading -----

    /// @inheritdoc ICommonManagement
    function submitSetRewardTrader(address rewardToken, address traderAddress)
        external
        onlyManagerOrOwner
        registersTimelockedAction(
            keccak256(abi.encode(TimelockTypes.SET_TRADER, rewardToken, traderAddress)),
            SET_TRADER_TIMELOCK
        )
    {
        require(
            !_isTimelockedActionRegistered(keccak256(abi.encode(TimelockTypes.ADD_VAULT, rewardToken))),
            InvalidRewardToken(rewardToken)
        );
        ManagementStorage storage $ = _getManagementStorage();
        $.aggregator.ensureTokenSafeToTransfer(rewardToken);

        emit SetRewardsTraderSubmitted(rewardToken, traderAddress, block.timestamp + SET_TRADER_TIMELOCK);
    }

    /// @inheritdoc ICommonManagement
    function cancelSetRewardTrader(address rewardToken, address traderAddress)
        external
        onlyGuardianOrHigherRole
        cancelsAction(keccak256(abi.encode(TimelockTypes.SET_TRADER, rewardToken, traderAddress)))
    {
        emit SetRewardsTraderCancelled(rewardToken, traderAddress);
    }

    /// @inheritdoc ICommonManagement
    function setRewardTrader(address rewardToken, address traderAddress)
        external
        onlyManagerOrOwner
        executesUnlockedAction(keccak256(abi.encode(TimelockTypes.SET_TRADER, rewardToken, traderAddress)))
    {
        require(
            !_isTimelockedActionRegistered(keccak256(abi.encode(TimelockTypes.ADD_VAULT, rewardToken))),
            InvalidRewardToken(rewardToken)
        );
        ManagementStorage storage $ = _getManagementStorage();
        $.aggregator.ensureTokenSafeToTransfer(rewardToken);
        $.rewardTrader[rewardToken] = traderAddress;

        emit RewardsTraderSet(rewardToken, traderAddress);
    }

    /// @inheritdoc ICommonManagement
    function transferRewardsForSale(address rewardToken) external {
        ManagementStorage storage $ = _getManagementStorage();
        require($.rewardTrader[rewardToken] != address(0), NoTraderSetForToken(rewardToken));
        address receiver = $.rewardTrader[rewardToken];
        uint256 amount = $.aggregator.transferRewardsForSale(rewardToken, receiver);

        emit RewardsTransferred(rewardToken, amount, receiver);
    }

    // ----- Pausing user interactions -----

    /// @notice Pauses user interactions including deposit, mint, withdraw, and redeem. Callable by the guardian,
    /// the manager or the owner. To be used in case of an emergency. Users can still use emergencyWithdraw
    /// to exit the aggregator.
    function pauseUserInteractions() external onlyGuardianOrHigherRole {
        ManagementStorage storage $ = _getManagementStorage();
        $.aggregator.pauseUserInteractions();
    }

    /// @notice Unpauses user interactions including deposit, mint, withdraw, and redeem. Callable by the guardian,
    /// the manager or the owner. To be used after mitigating a potential emergency.
    function unpauseUserInteractions() external onlyGuardianOrHigherRole {
        ManagementStorage storage $ = _getManagementStorage();
        uint256 pendingVaultForceRemovals = $.pendingVaultForceRemovals;
        require(pendingVaultForceRemovals == 0, PendingVaultForceRemovals(pendingVaultForceRemovals));
        $.aggregator.unpauseUserInteractions();
    }

    // ----- Management upgrades -----

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(OWNER)
        executesUnlockedAction(keccak256(abi.encode(TimelockTypes.MANAGEMENT_UPGRADE, newImplementation)))
    {
        emit ManagementUpgradeAuthorized(newImplementation);
    }

    function submitUpgradeManagement(address newImplementation)
        external
        onlyRole(OWNER)
        registersTimelockedAction(
            keccak256(abi.encode(TimelockTypes.MANAGEMENT_UPGRADE, newImplementation)),
            CONTRACT_UPGRADE_TIMELOCK
        )
    {
        emit ManagementUpgradeSubmitted(newImplementation, block.timestamp + CONTRACT_UPGRADE_TIMELOCK);
    }

    function cancelUpgradeManagement(address newImplementation)
        external
        onlyGuardianOrHigherRole
        cancelsAction(keccak256(abi.encode(TimelockTypes.MANAGEMENT_UPGRADE, newImplementation)))
    {
        emit ManagementUpgradeCancelled(newImplementation);
    }

    // ----- Aggregator upgrades -----

    function submitUpgradeAggregator(address newImplementation)
        external
        onlyRole(OWNER)
        registersTimelockedAction(
            keccak256(abi.encode(TimelockTypes.AGGREGATOR_UPGRADE, newImplementation)),
            CONTRACT_UPGRADE_TIMELOCK
        )
    {
        emit AggregatorUpgradeSubmitted(newImplementation, block.timestamp + CONTRACT_UPGRADE_TIMELOCK);
    }

    function cancelUpgradeAggregator(address newImplementation)
        external
        onlyGuardianOrHigherRole
        cancelsAction(keccak256(abi.encode(TimelockTypes.AGGREGATOR_UPGRADE, newImplementation)))
    {
        emit AggregatorUpgradeCancelled(newImplementation);
    }

    function upgradeAggregator(address newImplementation, bytes memory callData)
        external
        onlyRole(OWNER)
        executesUnlockedAction(keccak256(abi.encode(TimelockTypes.AGGREGATOR_UPGRADE, newImplementation)))
    {
        ManagementStorage storage $ = _getManagementStorage();
        UUPSUpgradeable($.aggregator).upgradeToAndCall(newImplementation, callData);
        emit AggregatorUpgraded(newImplementation);
    }

    // ----- Access control -----

    modifier onlyRebalancerOrHigherRole() {
        if (!hasRole(REBALANCER, msg.sender) && !hasRole(MANAGER, msg.sender) && !hasRole(OWNER, msg.sender)) {
            revert CallerNotRebalancerOrWithHigherRole();
        }
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
