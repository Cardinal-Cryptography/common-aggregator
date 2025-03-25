// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

interface ICommonAggregator is IERC4626 {
    // ----- Reporting -----

    event HoldingsStateUpdated(uint256 oldCachedAssets, uint256 newCachedAssets);
    event VaultWithdrawFailed(IERC4626 vault);

    error InsufficientAssetsForWithdrawal(uint256 missing);
    error VaultAddressCantBeZero();
    error IncorrectAsset(address expected, address actual);
    error VaultAlreadyAdded(IERC4626 vault);
    error VaultLimitExceeded();

    function updateHoldingsState() external;

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

    // ----- Deposits -----

    event DepositedToVault(address indexed vault, uint256 amountPlanned, uint256 amountDeposited);

    // ----- Withdrawals -----

    error CallerNotAggregator();
    error NotEnoughFunds();
    error AggregatedVaultWithdrawalLimitExceeded(address vault, uint256 maxWithdraw, uint256 amount);

    event ProportionalWithdrawalFailed(uint256 amount);

    // ----- Rebalancing -----

    event AssetsRebalanced(address indexed from, address indexed to, uint256 amount);

    /// @notice Withdraws `assets` from `vault` into aggregator's own balance.
    /// Vault must be present on the vault list.
    /// @dev Doesn't check the allocation limits, as even if they are still
    /// exceeded, the total excess will be lowered.
    function pullFunds(uint256 assets, IERC4626 vault) external;

    /// @notice Redeems `shares` from `vault`, returning assets into
    /// aggregator's own balance. Vault must be present on the vault list.
    /// @dev Similarly to `pullFunds`, doesn't check the allocation limits.
    function pullFundsByShares(uint256 shares, IERC4626 vault) external;

    /// @notice Deposits `assets` from aggregator's own balance into `vault`.
    /// Vault must be present on the vault list. Allocation limits are checked.
    function pushFunds(uint256 assets, IERC4626 vault) external;

    error AllocationLimitExceeded(IERC4626 vault);

    error CallerNotRebalancerOrWithHigherRole();
    error CallerNotManagerNorOwner();
    error CallerNotGuardianOrWithHigherRole();

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

    error ProtocolFeeTooHigh();

    /// @notice Sets bps-wise protocol fee.
    /// The protocol fee is applied on the profit made, with each holdings state update.
    /// It's a no-op if `_protocolFeeBps` is the same as the current `protocolFeeBps`.
    function setProtocolFee(uint256 _protocolFeeBps) external;

    error SelfProtocolFeeReceiver();
    error ZeroProtocolFeeReceiver();

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

    // ----- Emergency redeem -----

    /// @param sender Account executing the withdrawal.
    /// @param receiver Account that received the assets and the aggregated vaults' shares.
    /// @param owner Owner of the aggregator shares that were burnt.
    /// @param assets Amount of underlying assets transferred to the `receiver`
    /// @param shares Amount of the aggregator shares that were burnt.
    /// @param vaultShares List of the aggregated vaults' shares amounts that were transferred to the `receiver`.
    event EmergencyWithdraw(
        address indexed sender,
        address indexed receiver,
        address indexed owner,
        uint256 assets,
        uint256 shares,
        uint256[] vaultShares
    );

    /// @notice Burns exactly shares from owner and sends proportional amounts of aggregated vaults' shares and idle assets.
    /// @dev MUST emit the EmergencyWithdraw event.
    /// @dev MUST never be paused.
    /// @return assets Amount of the underlying assets transferred to the `receiver`
    /// @return vaultsShares List of the aggregated vaults' shares amounts that were transferred to the `receiver`.
    function emergencyRedeem(uint256 shares, address receiver, address owner)
        external
        returns (uint256 assets, uint256[] memory vaultsShares);
}
