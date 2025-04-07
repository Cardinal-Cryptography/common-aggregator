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

    /// @notice Submits timelocked force removal action for `vault`. Triggers a pause on the aggregator
    /// allowing users only to emergency redeem. After `unlockTimestamp` passes, `forceRemoveVault`
    /// can be called.
    /// @dev Tries to redeem as many `vault`'s shares as possible.
    function submitForceRemoveVault(IERC4626 vault) external;

    /// @notice Cancels timelocked force removal action for `vault`.
    /// Doesn't trigger unpause on the aggregator by itself.
    function cancelForceRemoveVault(IERC4626 vault) external;

    /// @notice Force-removes `vault` from the aggregator, loosing all the assets allocated to it.
    /// Doesn't trigger unpause on the aggregator by itself.
    function forceRemoveVault(IERC4626 vault) external;

    error PendingVaultForceRemoval(IERC4626 vault);
    error VaultAdditionAlreadyPending(IERC4626 vault);

    // ----- Rebalancing -----

    event AssetsRebalanced(address indexed from, address indexed to, uint256 amount);

    /// @notice Allows the `REBALANCER` or higher role holder to trigger `pushFunds` on the aggregator.
    function pushFunds(uint256 assets, IERC4626 vault) external;

    /// @notice Allows the `REBALANCER` or higher role holder to trigger `pullFunds` on the aggregator.
    function pullFunds(uint256 assets, IERC4626 vault) external;

    /// @notice Allows the `REBALANCER` or higher role holder to triggers `pullFundsByShares` on the aggregator.
    function pullFundsByShares(uint256 shares, IERC4626 vault) external;

    // ----- Allocation Limits -----

    event AllocationLimitSet(address indexed vault, uint256 newLimitBps);

    /// @notice Allows the `OWNER` role holder to trigger `setLimit` on the aggregator.
    function setLimit(IERC4626 vault, uint256 newLimitBps) external;

    // ----- Fee management -----

    event ProtocolFeeChanged(uint256 oldProtocolFee, uint256 newProtocolFee);
    event ProtocolFeeReceiverChanged(address indexed oldPorotocolFeeReceiver, address indexed newPorotocolFeeReceiver);

    /// @notice Allows the `OWNER` role holder to trigger `setProtocolFee` on the aggregator.
    function setProtocolFee(uint256 _protocolFeeBps) external;

    /// @notice Allows the `OWNER` role holder to trigger `setProtocolFeeReceiver` on the aggregator.
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

    /// @notice Proposes execution of `setRewardTrader` with given parameters. Ensures that the reward
    /// token is not a vault pending to be added. Caller must hold the `OWNER` role.
    function submitSetRewardTrader(address rewardToken, address traderAddress) external;

    /// @notice Allows transfering `rewardToken`s from aggregator to `traderAddress` using the
    /// `transferRewardsForSale` method. Ensures that the reward token is not a vault pending to be added.
    /// Can only be called after timelock initiated in `submitSetRewardTrader` has elapsed.
    function setRewardTrader(address rewardToken, address traderAddress) external;

    /// @notice Cancels reward trader setting action.
    /// Caller must hold `GUARDIAN`, `MANAGER` or `OWNER` role.
    function cancelSetRewardTrader(address rewardToken, address traderAddress) external;

    /// @notice Triggers `transferRewardsForSale` on the aggregator. Ensures that the reward
    /// token is not a vault pending to be added.
    function transferRewardsForSale(address token) external;

    // ----- Pausing -----

    /// @notice Allows the `GUARDIAN` or a higher role holder to trigger `pauseUserInteractions` on the aggregator.
    function pauseUserInteractions() external;

    /// @notice Allows the `GUARDIAN` or a higher role holder to trigger `unpauseUserInteractions` on the aggregator.
    function unpauseUserInteractions() external;

    error PendingVaultForceRemovals(uint256 count);

    // ----- Access control -----

    error CallerNotRebalancerOrWithHigherRole();
    error CallerNotManagerNorOwner();
    error CallerNotGuardianOrWithHigherRole();
}
