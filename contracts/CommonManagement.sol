// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    IERC20,
    IERC4626,
    Math,
    SafeERC20
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {CommonAggregator, ICommonAggregator} from "./CommonAggregator.sol";
import {saturatingAdd} from "./Math.sol";

/// @notice CommonManagement is the contract that manages the CommonAggregator, adding
/// more fine-grained access control and timelocking the most sensitive actions.
/// There are four roles specified:
/// * `OWNER`: can grant and revoke other roles, set protocol fee and its receiver, set allocation
///   limits per aggregated vault, and upgrade both the management and the aggregator contracts.
///   except of that, it has all the permissions of the `MANAGER` role. There can be exactly one owner.
/// * `MANAGER`: can add and remove vaults, or set reward traders. It also has all the permissions
///   of the `GUARDIAN` and `REBALANCER` roles.
/// * `GUARDIAN`: can pause and unpause the aggregator, and cancel timelocked actions.
/// * `REBALANCER`: can rebalance funds between vaults, according to the allocation limits.
contract CommonManagement is UUPSUpgradeable, Ownable2StepUpgradeable {
    using Math for uint256;
    using SafeERC20 for IERC20;
    using SafeERC20 for IERC4626;

    uint256 public constant SET_TRADER_TIMELOCK = 3 days;
    uint256 public constant ADD_VAULT_TIMELOCK = 3 days;
    uint256 public constant FORCE_REMOVE_VAULT_TIMELOCK = 3 days;
    uint256 public constant AGGREGATOR_UPGRADE_TIMELOCK = 3 days;
    uint256 public constant MANAGEMENT_UPGRADE_TIMELOCK = 3 days;

    event AggregatorUpgradeSubmitted(address indexed newImplementation, uint256 unlockTimestamp);
    event AggregatorUpgradeCancelled(address indexed newImplementation);
    event AggregatorUpgraded(address indexed newImplementation);

    event ManagementUpgradeSubmitted(address indexed newImplementation, uint256 unlockTimestamp);
    event ManagementUpgradeCancelled(address indexed newImplementation);
    event ManagementUpgradeAuthorized(address indexed newImplementation);

    event VaultAdditionSubmitted(address indexed vault, uint256 unlockTimestamp);
    event VaultAdditionCancelled(address indexed vault);

    event VaultForceRemovalSubmitted(address indexed vault, uint256 unlockTimestamp);
    event VaultForceRemovalCancelled(address indexed vault);

    event SetRewardsTraderSubmitted(
        address indexed rewardToken, address indexed traderAddress, uint256 unlockTimestamp
    );
    event SetRewardsTraderCancelled(address indexed rewardToken, address indexed traderAddress);
    event RewardsTraderSet(address indexed rewardToken, address indexed traderAddress);

    event RoleGranted(Roles role, address indexed account);
    event RoleRevoked(Roles role, address indexed account);

    error PendingVaultForceRemoval(IERC4626 vault);
    error VaultAdditionAlreadyPending(IERC4626 vault);

    error InvalidRewardToken(address token);
    error NoTraderSetForToken(address token);

    error PendingVaultForceRemovals(uint256 count);

    error CallerNotRebalancerOrWithHigherRole();
    error CallerNotManagerNorOwner();
    error CallerNotGuardianOrWithHigherRole();

    enum TimelockTypes {
        SET_TRADER,
        ADD_VAULT,
        FORCE_REMOVE_VAULT,
        AGGREGATOR_UPGRADE,
        MANAGEMENT_UPGRADE
    }

    enum Roles {
        Manager,
        Rebalancer,
        Guardian
    }

    struct TimelockData {
        uint256 lockedUntil;
        bytes32 actionData; // Used to enforce parameter consistency between action submission and execution.
    }

    bytes32 private constant EMPTY_ACTION_DATA = 0;

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

        _getManagementStorage().aggregator = aggregator;
    }

    // ----- Aggregated vaults management -----

    /// @notice Submits timelocked action for adding `vault` to the aggregator.
    function submitAddVault(IERC4626 vault)
        external
        onlyManagerOrOwner
        registersAction(keccak256(abi.encode(TimelockTypes.ADD_VAULT, vault)), EMPTY_ACTION_DATA, ADD_VAULT_TIMELOCK)
    {
        ManagementStorage storage $ = _getManagementStorage();
        require(
            $.aggregator.asset() == vault.asset(), ICommonAggregator.IncorrectAsset($.aggregator.asset(), vault.asset())
        );
        require(!$.aggregator.isVaultOnTheList(vault), ICommonAggregator.VaultAlreadyAdded(vault));

        emit VaultAdditionSubmitted(address(vault), saturatingAdd(block.timestamp, ADD_VAULT_TIMELOCK));
    }

    /// @notice Cancels timelocked action for adding `vault` to the aggregator.
    function cancelAddVault(IERC4626 vault)
        external
        onlyGuardianOrHigherRole
        cancelsAction(keccak256(abi.encode(TimelockTypes.ADD_VAULT, vault)))
    {
        emit VaultAdditionCancelled(address(vault));
    }

    /// @notice Adds `vault` to the aggregator, after the timelock has passed.
    function addVault(IERC4626 vault)
        external
        onlyManagerOrOwner
        executesAction(keccak256(abi.encode(TimelockTypes.ADD_VAULT, vault)), EMPTY_ACTION_DATA)
    {
        _getManagementStorage().aggregator.addVault(vault);
    }

    /// @notice Allows the `MANAGER` or `OWNER` to call `remove(vault)` on aggregator.
    /// @dev No timelock is used, as the action can't lose any assets.
    function removeVault(IERC4626 vault) external onlyManagerOrOwner {
        require(
            !isActionRegistered(keccak256(abi.encode(TimelockTypes.FORCE_REMOVE_VAULT, vault))),
            PendingVaultForceRemoval(vault)
        );

        _getManagementStorage().aggregator.removeVault(vault);
    }

    /// @notice Submits timelocked force removal action for `vault`. Triggers a pause on the aggregator
    /// allowing users only to emergency redeem. After `unlockTimestamp` passes, `forceRemoveVault`
    /// can be called.
    /// @dev Tries to redeem as many `vault`'s shares as possible.
    function submitForceRemoveVault(IERC4626 vault)
        external
        onlyManagerOrOwner
        registersAction(
            keccak256(abi.encode(TimelockTypes.FORCE_REMOVE_VAULT, vault)),
            EMPTY_ACTION_DATA,
            FORCE_REMOVE_VAULT_TIMELOCK
        )
    {
        ManagementStorage storage $ = _getManagementStorage();

        $.aggregator.tryExitVault(vault);
        if (!$.aggregator.paused()) {
            $.aggregator.pauseUserInteractions();
        }
        ++$.pendingVaultForceRemovals;

        emit VaultForceRemovalSubmitted(address(vault), saturatingAdd(block.timestamp, FORCE_REMOVE_VAULT_TIMELOCK));
    }

    /// @notice Cancels timelocked force removal action for `vault`.
    /// Doesn't trigger unpause on the aggregator by itself.
    function cancelForceRemoveVault(IERC4626 vault)
        external
        onlyGuardianOrHigherRole
        cancelsAction(keccak256(abi.encode(TimelockTypes.FORCE_REMOVE_VAULT, vault)))
    {
        --_getManagementStorage().pendingVaultForceRemovals;

        emit VaultForceRemovalCancelled(address(vault));
    }

    /// @notice Force-removes `vault` from the aggregator, losing all the assets allocated to it.
    /// Doesn't trigger unpause on the aggregator by itself. The timelock must have passed after
    /// the `submitForceRemoveVault` was called.
    function forceRemoveVault(IERC4626 vault)
        external
        onlyManagerOrOwner
        executesAction(keccak256(abi.encode(TimelockTypes.FORCE_REMOVE_VAULT, vault)), EMPTY_ACTION_DATA)
    {
        ManagementStorage storage $ = _getManagementStorage();
        $.aggregator.forceRemoveVault(vault);
        --$.pendingVaultForceRemovals;
    }
    // ----- Rebalancing -----

    /// @notice Allows the `REBALANCER` or higher role holder to trigger `pushFunds` on the aggregator.
    function pushFunds(uint256 assets, IERC4626 vault) external onlyRebalancerOrHigherRole {
        _getManagementStorage().aggregator.pushFunds(assets, vault);
    }

    /// @notice Allows the `REBALANCER` or higher role holder to trigger `pullFunds` on the aggregator.
    function pullFunds(uint256 assets, IERC4626 vault) external onlyRebalancerOrHigherRole {
        _getManagementStorage().aggregator.pullFunds(assets, vault);
    }

    /// @notice Allows the `REBALANCER` or higher role holder to triggers `pullFundsByShares` on the aggregator.
    function pullFundsByShares(uint256 shares, IERC4626 vault) external onlyRebalancerOrHigherRole {
        _getManagementStorage().aggregator.pullFundsByShares(shares, vault);
    }

    // ----- Allocation Limits -----

    /// @notice Allows the `OWNER` role holder to trigger `setLimit` on the aggregator.
    function setLimit(IERC4626 vault, uint256 newLimitBps) external onlyOwner {
        _getManagementStorage().aggregator.setLimit(vault, newLimitBps);
    }

    // ----- Fee management -----

    /// @notice Allows the `OWNER` role holder to trigger `setProtocolFee` on the aggregator.
    function setProtocolFee(uint256 protocolFeeBps) public onlyOwner {
        _getManagementStorage().aggregator.setProtocolFee(protocolFeeBps);
    }

    /// @notice Allows the `OWNER` role holder to trigger `setProtocolFeeReceiver` on the aggregator.
    function setProtocolFeeReceiver(address protocolFeeReceiver) public onlyOwner {
        _getManagementStorage().aggregator.setProtocolFeeReceiver(protocolFeeReceiver);
    }

    // ----- Non-asset rewards trading -----

    /// @notice Proposes execution of `setRewardTrader` with given parameters.
    /// @dev Ensures that the reward is not asset, aggregator share, one of the aggregated
    /// vault's share, or share of a vault that is pending to be added. Caller must hold the
    /// `OWNER` role.
    function submitSetRewardTrader(address rewardToken, address traderAddress)
        external
        onlyManagerOrOwner
        registersAction(
            keccak256(abi.encode(TimelockTypes.SET_TRADER, rewardToken)),
            keccak256(abi.encode(traderAddress)),
            SET_TRADER_TIMELOCK
        )
    {
        require(
            !isActionRegistered(keccak256(abi.encode(TimelockTypes.ADD_VAULT, rewardToken))),
            InvalidRewardToken(rewardToken)
        );

        _getManagementStorage().aggregator.ensureTokenIsNotInherentlyUsed(rewardToken);

        emit SetRewardsTraderSubmitted(rewardToken, traderAddress, saturatingAdd(block.timestamp, SET_TRADER_TIMELOCK));
    }

    /// @notice Cancels reward trader setting action.
    /// Caller must hold `GUARDIAN`, `MANAGER` or `OWNER` role.
    function cancelSetRewardTrader(address rewardToken, address traderAddress)
        external
        onlyGuardianOrHigherRole
        cancelsAction(keccak256(abi.encode(TimelockTypes.SET_TRADER, rewardToken)))
    {
        emit SetRewardsTraderCancelled(rewardToken, traderAddress);
    }

    /// @notice Allows transfering `rewardToken`s from aggregator to `traderAddress` using the
    /// `transferRewardsForSale` method. Ensures that the reward is not asset, aggregator share, one of the aggregated
    /// vault's share, or share of a vault that is pending to be added.
    /// Can only be called after timelock initiated in `submitSetRewardTrader` has elapsed.
    function setRewardTrader(address rewardToken, address traderAddress)
        external
        onlyManagerOrOwner
        executesAction(keccak256(abi.encode(TimelockTypes.SET_TRADER, rewardToken)), keccak256(abi.encode(traderAddress)))
    {
        ManagementStorage storage $ = _getManagementStorage();
        require(
            !isActionRegistered(keccak256(abi.encode(TimelockTypes.ADD_VAULT, rewardToken))),
            InvalidRewardToken(rewardToken)
        );

        $.aggregator.ensureTokenIsNotInherentlyUsed(rewardToken);
        $.rewardTrader[rewardToken] = traderAddress;

        emit RewardsTraderSet(rewardToken, traderAddress);
    }

    /// @notice Triggers `transferRewardsForSale` on the aggregator.
    /// Can be called permissionlessly, and reward will be sent to the trader set.
    /// @dev Ensures that the reward token is not a vault pending to be added,
    /// and the called vault ensures that the token is not asset, aggregator share,
    /// or one of the aggregated vault's share.
    function transferRewardsForSale(address rewardToken) external {
        ManagementStorage storage $ = _getManagementStorage();
        require(
            !isActionRegistered(keccak256(abi.encode(TimelockTypes.ADD_VAULT, rewardToken))),
            InvalidRewardToken(rewardToken)
        );

        require($.rewardTrader[rewardToken] != address(0), NoTraderSetForToken(rewardToken));
        address receiver = $.rewardTrader[rewardToken];
        $.aggregator.transferRewardsForSale(rewardToken, receiver);
    }

    // ----- Pausing user interactions -----

    /// @notice Allows the `GUARDIAN` or a higher role holder to trigger `pauseUserInteractions` on the aggregator.
    function pauseUserInteractions() external onlyGuardianOrHigherRole {
        _getManagementStorage().aggregator.pauseUserInteractions();
    }

    /// @notice Allows the `GUARDIAN` or a higher role holder to trigger `unpauseUserInteractions` on the aggregator.
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

    /// @notice Submits timelocked upgrade action of the management contract to `newImplementation`.
    /// After `unlockTimestamp` passes, the contract upgrade can be performed to the new implementation.
    /// @dev After the timelock passes, upgrader can upgradeToAndCall on the new implementation with
    /// any calldata. No check against missing some storage or selectors are done on the contract
    /// level. It's recommended to use the `openzeppelin-foundry-upgrades` libarary for updates.
    /// There could be many pending upgrades, so it's the guardian's responsibility to cancel
    /// the invalid ones.
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

    /// @notice Cancels timelocked upgrade of the management contract action to `newImplementation`.
    function cancelUpgradeManagement(address newImplementation)
        external
        onlyGuardianOrHigherRole
        cancelsAction(keccak256(abi.encode(TimelockTypes.MANAGEMENT_UPGRADE)))
    {
        emit ManagementUpgradeCancelled(newImplementation);
    }

    // ----- Aggregator upgrades -----

    /// @notice Submits timelocked upgrade action of the aggregator contract to `newImplementation`.
    /// After `unlockTimestamp` passes, the contract upgrade can be performed to the new implementation.
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

    /// @notice Cancels timelocked upgrade the aggregator contract action to `newImplementation`.
    function cancelUpgradeAggregator(address newImplementation)
        external
        onlyGuardianOrHigherRole
        cancelsAction(keccak256(abi.encode(TimelockTypes.AGGREGATOR_UPGRADE)))
    {
        emit AggregatorUpgradeCancelled(newImplementation);
    }

    /// @notice Executes the upgrade of the aggregator contract to the new implementation.
    function upgradeAggregator(address newImplementation, bytes calldata callData)
        external
        onlyOwner
        executesAction(keccak256(abi.encode(TimelockTypes.AGGREGATOR_UPGRADE)), keccak256(abi.encode(newImplementation)))
    {
        UUPSUpgradeable(_getManagementStorage().aggregator).upgradeToAndCall(newImplementation, callData);
        emit AggregatorUpgraded(newImplementation);
    }

    // ----- Access control -----

    /// @notice We explicitly disable renouncing ownership.
    function renounceOwnership() public override onlyOwner {}

    function hasRole(Roles role, address account) public view returns (bool) {
        return _getManagementStorage().roles[role][account];
    }

    /// Grants one of the `Roles` to `account`.
    function grantRole(Roles role, address account) external onlyOwner {
        ManagementStorage storage $ = _getManagementStorage();
        if (!$.roles[role][account]) {
            $.roles[role][account] = true;
            emit RoleGranted(role, account);
        }
    }

    /// Removes the `role` from `account`.
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
        $.registeredTimelocks[actionHash] =
            TimelockData({lockedUntil: saturatingAdd(block.timestamp, delay), actionData: actionData});
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

    /// @notice Checks if a timelocked action is registered.
    function isActionRegistered(bytes32 actionHash) public view returns (bool) {
        return _getManagementStorage().registeredTimelocks[actionHash].lockedUntil != 0;
    }
}
