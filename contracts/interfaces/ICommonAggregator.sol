// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC4626Buffered} from "./IERC4626Buffered.sol";

interface ICommonAggregator is IERC4626Buffered {
    // ----- Reporting -----

    event VaultWithdrawFailed(IERC4626 vault);

    error InsufficientAssetsForWithdrawal(uint256 missing);
    error IncorrectAsset(address expected, address actual);
    error VaultAlreadyAdded(IERC4626 vault);
    error VaultLimitExceeded();

    // ----- Vault management -----

    function addVault(IERC4626 vault) external;
    function removeVault(IERC4626 vault) external;
    function forceRemoveVault(IERC4626 vault) external;

    // ----- Deposits -----

    event DepositedToVault(address indexed vault, uint256 amountPlanned, uint256 amountDeposited);

    // ----- Withdrawals -----

    error CallerNotAggregator();
    error NotEnoughFunds();
    error AggregatedVaultWithdrawalLimitExceeded(address vault, uint256 maxWithdraw, uint256 amount);

    event ProportionalWithdrawalFailed(uint256 amount);

    // ----- Rebalancing -----

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
    function pullFundsByShares(uint256 shares, IERC4626 vault) external returns (uint256 assets);

    error AllocationLimitExceeded(IERC4626 vault);

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
    /// It's a no-op if `protocolFeeBps` is the same as the current `protocolFeeBps`.
    function setProtocolFee(uint256 protocolFeeBps) external;

    error SelfProtocolFeeReceiver();

    /// @notice Sets the protocol fee receiver.
    /// It's a no-op if `protocolFeeReceiver` is the same as the current `protocolFeeReceiver`.
    function setProtocolFeeReceiver(address protocolFeeReceiver) external;

    // ----- Non-asset rewards trading -----

    error InvalidRewardToken(address token);

    /// @notice Transfers all `rewardToken`s held in the aggregator to `rewardTrader`
    function transferRewardsForSale(address rewardToken, address rewardTrader) external returns (uint256 amount);

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

    // ----- Checks -----

    function ensureVaultCanBeAdded(IERC4626 vault) external view;
    function ensureVaultIsPresent(IERC4626 vault) external view returns (uint256);
    function ensureTokenSafeToTransfer(address rewardToken) external view;

    // ----- Pausing -----

    function pauseUserInteractions() external;
    function unpauseUserInteractions() external;

    // ----- Access control -----

    error CallerNotManagement();
}
