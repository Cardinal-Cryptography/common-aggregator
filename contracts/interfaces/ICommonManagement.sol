// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC4626Buffered} from "./IERC4626Buffered.sol";

interface ICommonManagement {
    // ----- Aggregator Upgrades -----

    event AggregatorUpgradeSubmitted(address newImplementation, uint256 unlockTimestamp);
    event AggregatorUpgradeCancelled(address newImplementation);
    event AggregatorUpgraded(address newImplementation);

    /// @notice Submits timelocked upgrade action of the aggregator contract to `newImplementation`.
    /// After `unlockTimestamp` passes, the contract upgrade can be performed to the new implementation.
    function submitUpgradeAggregator(address newImplementation) external;

    /// @notice Cancels timelocked upgrade the aggregator contract action to `newImplementation`.
    function cancelUpgradeAggregator(address newImplementation) external;

    /// @notice Executes the upgrade of the aggregator contract to the new implementation.
    function upgradeAggregator(address newImplementation, bytes memory callData) external;

    // ----- Management Upgrades -----

    event ManagementUpgradeSubmitted(address newImplementation, uint256 unlockTimestamp);
    event ManagementUpgradeCancelled(address newImplementation);
    event ManagementUpgradeAuthorized(address newImplementation);

    /// @notice Submits timelocked upgrade action of the management contract to `newImplementation`.
    /// After `unlockTimestamp` passes, the contract upgrade can be performed to the new implementation.
    /// @dev After the timelock passes, upgrader can upgradeToAndCall on the new implementation with
    /// any calldata. No check against missing some storage or selectors are done on the contract
    /// level. It's recommended to use the `openzeppelin-foundry-upgrades` libarary for updates.
    /// There could be many pending upgrades, so it's the guardian's responsibility to cancel
    /// the invalid ones.
    function submitUpgradeManagement(address newImplementation) external;

    /// @notice Cancels timelocked upgrade of the management contract action to `newImplementation`.
    function cancelUpgradeManagement(address newImplementation) external;

    // ----- Vault management -----

    event VaultAdditionSubmitted(address indexed vault, uint256 unlockTimestamp);
    event VaultAdditionCancelled(address indexed vault);
    event VaultAdded(address indexed vault);

    event VaultRemoved(address indexed vault);

    event VaultForceRemovalSubmitted(address indexed vault, uint256 unlockTimestamp);
    event VaultForceRemovalCancelled(address indexed vault);
    event VaultForceRemoved(address indexed vault);

    function submitAddVault(IERC4626 vault) external;
    function cancelAddVault(IERC4626 vault) external;
    function addVault(IERC4626 vault) external;

    function removeVault(IERC4626 vault) external;

    /// @notice Submits timelocked force removal action for `vault`.
    /// Pauses user actions (deposit, mint, withdraw, redeem), allowing only for the emergency redeem, if
    /// the aggregator is not already paused.
    /// After `unlockTimestamp` passes, the `forceRemoveVault` can be called.
    /// @dev Tries to redeem as many `vault`'s shares as possible.
    function submitForceRemoveVault(IERC4626 vault) external;

    /// @notice Cancels timelocked force removal action for `vault`.
    /// Doesn't unpause protocol by itself.
    function cancelForceRemoveVault(IERC4626 vault) external;

    /// @notice Force-removes `vault` from the aggregator, lossing all the assets allocated to it.
    /// Doesn't unpause protocol by itself.
    function forceRemoveVault(IERC4626 vault) external;

    error PendingVaultForceRemoval(IERC4626 vault);
    error VaultAdditionAlreadyPending(IERC4626 vault);

    // ----- Rebalancing -----

    event AssetsRebalanced(address indexed from, address indexed to, uint256 amount);

    /// @notice Deposits `assets` from aggregator's own balance into `vault`.
    /// Vault must be present on the vault list. Allocation limits are checked.
    function pushFunds(uint256 assets, IERC4626 vault) external;

    /// @notice Withdraws `assets` from `vault` into aggregator's own balance.
    /// Vault must be present on the vault list.
    /// @dev Doesn't check the allocation limits, as even if they are still
    /// exceeded, the total excess will be lowered.
    function pullFunds(uint256 assets, IERC4626 vault) external;

    /// @notice Redeems `shares` from `vault`, returning assets into
    /// aggregator's own balance. Vault must be present on the vault list.
    /// @dev Similarly to `pullFunds`, doesn't check the allocation limits.
    function pullFundsByShares(uint256 shares, IERC4626 vault) external;

    // ----- Allocation Limits -----

    event AllocationLimitSet(address indexed vault, uint256 newLimitBps);

    /// @notice Sets allocation limit of `vault` to `newLimitBps`.
    /// The limit is expressed in bps, and is applied on the assets.
    /// It's a no-op if `newLimitBps` is the same as the current limit.
    /// Reverts if `newLimitBps` is higher MAX_BPS, or if `vault` is not present
    /// on the vault list.
    function setLimit(IERC4626 vault, uint256 newLimitBps) external;

    error VaultNotOnTheList(IERC4626 vault);
    error IncorrectMaxAllocationLimit();

    // ----- Fee management -----

    event ProtocolFeeChanged(uint256 oldProtocolFee, uint256 newProtocolFee);

    event ProtocolFeeReceiverChanged(address indexed oldPorotocolFeeReceiver, address indexed newPorotocolFeeReceiver);

    /// @notice Sets bps-wise protocol fee.
    /// The protocol fee is applied on the profit made, with each holdings state update.
    /// It's a no-op if `_protocolFeeBps` is the same as the current `protocolFeeBps`.
    function setProtocolFee(uint256 _protocolFeeBps) external;

    error SelfProtocolFeeReceiver();

    /// @notice Sets the protocol fee receiver.
    /// It's a no-op if `protocolFeeReceiver` is the same as the current `protocolFeeReceiver`.
    function setProtocolFeeReceiver(address protocolFeeReceiver) external;

    // ----- Non-asset rewards trading -----

    event SetRewardsTraderSubmitted(
        address indexed rewardToken, address indexed traderAddress, uint256 unlockTimestamp
    );
    event SetRewardsTraderCancelled(address indexed rewardToken, address indexed traderAddress);
    event RewardsTraderSet(address indexed rewardToken, address indexed traderAddress);
    event RewardsTransferred(address indexed rewardToken, uint256 amount, address indexed receiver);

    error InvalidRewardToken(address token);
    error NoTraderSetForToken(address token);

    /// @notice Proposes execution of `setRewardTrader` with given parameters.
    /// Caller must hold the `OWNER` role.
    function submitSetRewardTrader(address rewardToken, address traderAddress) external;

    /// @notice Allows transfering `rewardToken`s from aggregator to `traderAddress`
    /// using `transferRewardsForSale` method.
    /// Can only be called after timelock initiated in `submitSetRewardTrader` has elapsed.
    function setRewardTrader(address rewardToken, address traderAddress) external;

    /// @notice Cancels reward trader setting action.
    /// Caller must hold `GUARDIAN`, `MANAGER` or `OWNER` role.
    function cancelSetRewardTrader(address rewardToken, address traderAddress) external;

    /// @notice Transfers all `token`s held in the aggregator to `rewardTrader[token]`
    function transferRewardsForSale(address token) external;

    // ----- Pausing -----

    /// @notice Pauses user interactions including deposit, mint, withdraw, and redeem. Callable by the guardian,
    /// the manager or the owner. To be used in case of an emergency. Users can still use emergencyWithdraw
    /// to exit the aggregator.
    function pauseUserInteractions() external;

    /// @notice Unpauses user interactions including deposit, mint, withdraw, and redeem. Callable by the guardian,
    /// the manager or the owner. To be used after mitigating a potential emergency.
    function unpauseUserInteractions() external;

    error PendingVaultForceRemovals(uint256 count);

    // ----- Access control -----

    error CallerNotRebalancerOrWithHigherRole();
    error CallerNotManagerNorOwner();
    error CallerNotGuardianOrWithHigherRole();
}
