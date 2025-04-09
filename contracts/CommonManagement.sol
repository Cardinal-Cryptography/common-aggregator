// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {CommonAggregator} from "./CommonAggregator.sol";
import {ICommonManagement} from "./interfaces/ICommonManagement.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {IERC20, IERC4626, IERC20Metadata, SafeERC20, ERC20Upgradeable} from "./ERC4626BufferedUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MAX_BPS, saturatingAdd} from "./Math.sol";

contract CommonManagement is ICommonManagement, UUPSUpgradeable, Ownable2StepUpgradeable {
    using Math for uint256;
    using SafeERC20 for IERC20;
    using SafeERC20 for IERC4626;

    uint256 public constant SET_TRADER_TIMELOCK = 5 days;
    uint256 public constant ADD_VAULT_TIMELOCK = 7 days;
    uint256 public constant FORCE_REMOVE_VAULT_TIMELOCK = 14 days;
    uint256 public constant AGGREGATOR_UPGRADE_TIMELOCK = 14 days;
    uint256 public constant MANAGEMENT_UPGRADE_TIMELOCK = 14 days;

    enum TimelockTypes {
        SET_TRADER,
        ADD_VAULT,
        FORCE_REMOVE_VAULT,
        AGGREGATOR_UPGRADE,
        MANAGEMENT_UPGRADE
    }

    struct TimelockData {
        uint256 lockedUntil;
        bytes32 actionData;
    }

    /// @custom:storage-location erc7201:common.storage.management
    struct ManagementStorage {
        mapping(bytes32 actionHash => TimelockData timelockData) registeredTimelocks;
        mapping(address rewardToken => address traderAddress) rewardTrader;
        mapping(Roles => mapping(address => bool)) roles;
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
        __Ownable_init(owner);

        ManagementStorage storage $ = _getManagementStorage();
        $.aggregator = aggregator;
    }

    // ----- Aggregated vaults management -----

    /// @inheritdoc ICommonManagement
    function submitAddVault(IERC4626 vault)
        external
        override
        onlyManagerOrOwner
        registersAction(keccak256(abi.encode(TimelockTypes.ADD_VAULT, vault)), 0, ADD_VAULT_TIMELOCK)
    {
        ManagementStorage storage $ = _getManagementStorage();
        $.aggregator.ensureVaultCanBeAdded(vault);

        emit VaultAdditionSubmitted(address(vault), saturatingAdd(block.timestamp, ADD_VAULT_TIMELOCK));
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
        executesAction(keccak256(abi.encode(TimelockTypes.ADD_VAULT, vault)), 0)
    {
        ManagementStorage storage $ = _getManagementStorage();
        $.aggregator.addVault(vault);
    }

    function removeVault(IERC4626 vault) external override onlyManagerOrOwner {
        ManagementStorage storage $ = _getManagementStorage();
        require(
            !_isActionRegistered(keccak256(abi.encode(TimelockTypes.FORCE_REMOVE_VAULT, vault))),
            PendingVaultForceRemoval(vault)
        );

        $.aggregator.removeVault(vault);
    }

    /// @inheritdoc ICommonManagement
    function submitForceRemoveVault(IERC4626 vault)
        external
        override
        onlyManagerOrOwner
        registersAction(keccak256(abi.encode(TimelockTypes.FORCE_REMOVE_VAULT, vault)), 0, FORCE_REMOVE_VAULT_TIMELOCK)
    {
        ManagementStorage storage $ = _getManagementStorage();

        $.aggregator.tryExitVault(vault);
        if (!$.aggregator.paused()) {
            $.aggregator.pauseUserInteractions();
        }
        $.pendingVaultForceRemovals++;

        emit VaultForceRemovalSubmitted(address(vault), saturatingAdd(block.timestamp, FORCE_REMOVE_VAULT_TIMELOCK));
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
        executesAction(keccak256(abi.encode(TimelockTypes.FORCE_REMOVE_VAULT, vault)), 0)
    {
        ManagementStorage storage $ = _getManagementStorage();
        $.aggregator.forceRemoveVault(vault);
        $.pendingVaultForceRemovals--;
    }
    // ----- Rebalancing -----

    /// @inheritdoc ICommonManagement
    function pushFunds(uint256 assets, IERC4626 vault) external onlyRebalancerOrHigherRole {
        ManagementStorage storage $ = _getManagementStorage();
        $.aggregator.pushFunds(assets, vault);
    }

    /// @inheritdoc ICommonManagement
    function pullFunds(uint256 assets, IERC4626 vault) external onlyRebalancerOrHigherRole {
        ManagementStorage storage $ = _getManagementStorage();
        $.aggregator.pullFunds(assets, vault);
    }

    /// @inheritdoc ICommonManagement
    function pullFundsByShares(uint256 shares, IERC4626 vault) external onlyRebalancerOrHigherRole {
        ManagementStorage storage $ = _getManagementStorage();
        $.aggregator.pullFundsByShares(shares, vault);
    }

    // ----- Allocation Limits -----

    /// @inheritdoc ICommonManagement
    /// @notice Doesn't rebalance the assets, after the action limits may be exceeded.
    function setLimit(IERC4626 vault, uint256 newLimitBps) external override onlyOwner {
        ManagementStorage storage $ = _getManagementStorage();
        $.aggregator.setLimit(vault, newLimitBps);
    }

    // ----- Fee management -----

    /// @inheritdoc ICommonManagement
    function setProtocolFee(uint256 protocolFeeBps) public override(ICommonManagement) onlyOwner {
        ManagementStorage storage $ = _getManagementStorage();
        $.aggregator.setProtocolFee(protocolFeeBps);
    }

    /// @inheritdoc ICommonManagement
    function setProtocolFeeReceiver(address protocolFeeReceiver) public override(ICommonManagement) onlyOwner {
        ManagementStorage storage $ = _getManagementStorage();
        $.aggregator.setProtocolFeeReceiver(protocolFeeReceiver);
    }

    // ----- Non-asset rewards trading -----

    /// @inheritdoc ICommonManagement
    function submitSetRewardTrader(address rewardToken, address traderAddress)
        external
        onlyManagerOrOwner
        registersAction(
            keccak256(abi.encode(TimelockTypes.SET_TRADER, rewardToken)),
            keccak256(abi.encode(traderAddress)),
            SET_TRADER_TIMELOCK
        )
    {
        ManagementStorage storage $ = _getManagementStorage();
        require(
            !_isActionRegistered(keccak256(abi.encode(TimelockTypes.ADD_VAULT, rewardToken))),
            InvalidRewardToken(rewardToken)
        );

        $.aggregator.ensureTokenSafeToTransfer(rewardToken);

        emit SetRewardsTraderSubmitted(rewardToken, traderAddress, saturatingAdd(block.timestamp, SET_TRADER_TIMELOCK));
    }

    /// @inheritdoc ICommonManagement
    function cancelSetRewardTrader(address rewardToken, address traderAddress)
        external
        onlyGuardianOrHigherRole
        cancelsAction(keccak256(abi.encode(TimelockTypes.SET_TRADER, rewardToken)))
    {
        emit SetRewardsTraderCancelled(rewardToken, traderAddress);
    }

    /// @inheritdoc ICommonManagement
    function setRewardTrader(address rewardToken, address traderAddress)
        external
        onlyManagerOrOwner
        executesAction(keccak256(abi.encode(TimelockTypes.SET_TRADER, rewardToken)), keccak256(abi.encode(traderAddress)))
    {
        ManagementStorage storage $ = _getManagementStorage();
        require(
            !_isActionRegistered(keccak256(abi.encode(TimelockTypes.ADD_VAULT, rewardToken))),
            InvalidRewardToken(rewardToken)
        );

        $.aggregator.ensureTokenSafeToTransfer(rewardToken);
        $.rewardTrader[rewardToken] = traderAddress;

        emit RewardsTraderSet(rewardToken, traderAddress);
    }

    /// @inheritdoc ICommonManagement
    function transferRewardsForSale(address rewardToken) external {
        ManagementStorage storage $ = _getManagementStorage();
        require(
            !_isActionRegistered(keccak256(abi.encode(TimelockTypes.ADD_VAULT, rewardToken))),
            InvalidRewardToken(rewardToken)
        );

        require($.rewardTrader[rewardToken] != address(0), NoTraderSetForToken(rewardToken));
        address receiver = $.rewardTrader[rewardToken];
        $.aggregator.transferRewardsForSale(rewardToken, receiver);
    }

    // ----- Pausing user interactions -----

    /// @inheritdoc ICommonManagement
    function pauseUserInteractions() external onlyGuardianOrHigherRole {
        ManagementStorage storage $ = _getManagementStorage();
        $.aggregator.pauseUserInteractions();
    }

    /// @inheritdoc ICommonManagement
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
        onlyOwner
        executesAction(keccak256(abi.encode(TimelockTypes.MANAGEMENT_UPGRADE)), keccak256(abi.encode(newImplementation)))
    {
        emit ManagementUpgradeAuthorized(newImplementation);
    }

    function submitUpgradeManagement(address newImplementation)
        external
        onlyOwner
        registersAction(
            keccak256(abi.encode(TimelockTypes.MANAGEMENT_UPGRADE)),
            keccak256(abi.encode(newImplementation)),
            MANAGEMENT_UPGRADE_TIMELOCK
        )
    {
        emit ManagementUpgradeSubmitted(newImplementation, saturatingAdd(block.timestamp, MANAGEMENT_UPGRADE_TIMELOCK));
    }

    function cancelUpgradeManagement(address newImplementation)
        external
        onlyGuardianOrHigherRole
        cancelsAction(keccak256(abi.encode(TimelockTypes.MANAGEMENT_UPGRADE)))
    {
        emit ManagementUpgradeCancelled(newImplementation);
    }

    // ----- Aggregator upgrades -----

    function submitUpgradeAggregator(address newImplementation)
        external
        onlyOwner
        registersAction(
            keccak256(abi.encode(TimelockTypes.AGGREGATOR_UPGRADE)),
            keccak256(abi.encode(newImplementation)),
            AGGREGATOR_UPGRADE_TIMELOCK
        )
    {
        emit AggregatorUpgradeSubmitted(newImplementation, saturatingAdd(block.timestamp, AGGREGATOR_UPGRADE_TIMELOCK));
    }

    function cancelUpgradeAggregator(address newImplementation)
        external
        onlyGuardianOrHigherRole
        cancelsAction(keccak256(abi.encode(TimelockTypes.AGGREGATOR_UPGRADE)))
    {
        emit AggregatorUpgradeCancelled(newImplementation);
    }

    function upgradeAggregator(address newImplementation, bytes memory callData)
        external
        onlyOwner
        executesAction(keccak256(abi.encode(TimelockTypes.AGGREGATOR_UPGRADE)), keccak256(abi.encode(newImplementation)))
    {
        ManagementStorage storage $ = _getManagementStorage();
        UUPSUpgradeable($.aggregator).upgradeToAndCall(newImplementation, callData);
        emit AggregatorUpgraded(newImplementation);
    }

    // ----- Access control -----

    /// @notice We explicitly disable renouncing ownership.
    function renounceOwnership() public override onlyOwner {}

    function hasRole(Roles role, address account) public view returns (bool) {
        ManagementStorage storage $ = _getManagementStorage();
        return $.roles[role][account];
    }

    function grantRole(Roles role, address account) external onlyOwner {
        ManagementStorage storage $ = _getManagementStorage();
        if (!$.roles[role][account]) {
            $.roles[role][account] = true;
            emit RoleGranted(role, account);
        }
    }

    function revokeRole(Roles role, address account) external onlyOwner {
        ManagementStorage storage $ = _getManagementStorage();
        if ($.roles[role][account]) {
            $.roles[role][account] = false;
            emit RoleRevoked(role, account);
        }
    }

    modifier onlyRebalancerOrHigherRole() {
        if (!hasRole(Roles.Rebalancer, msg.sender) && !hasRole(Roles.Manager, msg.sender) && msg.sender != owner()) {
            revert CallerNotRebalancerOrWithHigherRole();
        }
        _;
    }

    modifier onlyGuardianOrHigherRole() {
        if (!hasRole(Roles.Guardian, msg.sender) && !hasRole(Roles.Manager, msg.sender) && msg.sender != owner()) {
            revert CallerNotGuardianOrWithHigherRole();
        }
        _;
    }

    modifier onlyManagerOrOwner() {
        if (!hasRole(Roles.Manager, msg.sender) && msg.sender != owner()) {
            revert CallerNotManagerNorOwner();
        }
        _;
    }

    // ----- Timelocks -----

    error ActionAlreadyRegistered(bytes32 actionHash);
    error ActionNotRegistered(bytes32 actionHash);
    error ActionTimelocked(bytes32 actionHash, uint256 lockedUntil);
    error IncorrectActionData(bytes32 actionHash, bytes32 actionData);

    /// @dev Use this modifier for functions which submit a timelocked action proposal.
    modifier registersAction(bytes32 actionHash, bytes32 actionData, uint256 delay) {
        _register(actionHash, actionData, delay);
        _;
    }

    /// @dev Use this modifier for functions which execute a previously submitted action whose timelock
    /// period has passed.
    modifier executesAction(bytes32 actionHash, bytes32 actionData) {
        _execute(actionHash, actionData);
        _;
    }

    /// @dev Use this modifier to cancel a previously submitted action, so that it can't be executed.
    modifier cancelsAction(bytes32 actionHash) {
        _cancel(actionHash);
        _;
    }

    /// @dev Adds a timelock entry for the given action if it doesn't exist yet. It is safely assumed that `block.timestamp`
    /// is greater than zero. A zero `delay` means that the action is locked only for the current timestamp.
    function _register(bytes32 actionHash, bytes32 actionData, uint256 delay) private {
        ManagementStorage storage $ = _getManagementStorage();
        if ($.registeredTimelocks[actionHash].lockedUntil != 0) {
            revert ActionAlreadyRegistered(actionHash);
        }
        $.registeredTimelocks[actionHash].lockedUntil = saturatingAdd(block.timestamp, delay);
        $.registeredTimelocks[actionHash].actionData = actionData;
    }

    /// @dev Removes a timelock entry for the given action if it exists and the timelock has passed.
    function _execute(bytes32 actionHash, bytes32 actionData) private {
        ManagementStorage storage $ = _getManagementStorage();
        uint256 lockedUntil = $.registeredTimelocks[actionHash].lockedUntil;
        if (lockedUntil == 0) {
            revert ActionNotRegistered(actionHash);
        }
        if (lockedUntil >= block.timestamp) {
            revert ActionTimelocked(actionHash, lockedUntil);
        }
        bytes32 submittedActionData = $.registeredTimelocks[actionHash].actionData;
        if (actionData != submittedActionData) {
            revert IncorrectActionData(actionHash, actionData);
        }
        delete $.registeredTimelocks[actionHash];
    }

    /// @dev Removes a timelock entry for the given action if it exists. Cancellation works both during
    /// and after the timelock period.
    function _cancel(bytes32 actionHash) private {
        ManagementStorage storage $ = _getManagementStorage();
        if ($.registeredTimelocks[actionHash].lockedUntil == 0) {
            revert ActionNotRegistered(actionHash);
        }
        delete $.registeredTimelocks[actionHash];
    }

    function _isActionRegistered(bytes32 actionHash) public view returns (bool) {
        return _getManagementStorage().registeredTimelocks[actionHash].lockedUntil != 0;
    }
}
