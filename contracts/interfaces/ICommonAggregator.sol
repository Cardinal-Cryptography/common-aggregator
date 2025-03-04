// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

interface ICommonAggregator is IERC4626 {
    // ----- Reporting -----

    event HoldingsStateUpdated(uint256 oldCachedAssets, uint256 newCachedAssets);

    error VaultAddressCantBeZero();
    error IncorrectAsset(address expected, address actual);
    error VaultAlreadyAded(IERC4626 vault);
    error VaultLimitExceeded();

    function updateHoldingsState() external;

    // ----- Deposits -----

    event DepositedToVault(address indexed vault, uint256 amountPlanned, uint256 amountDeposited);

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
    function setProtocolFee(uint256 protocolFeeBps) external;

    error SelfProtocolFeeReceiver();
    error ZeroProtocolFeeReceiver();

    /// @notice Sets the protocol fee receiver.
    /// It's a no-op if `protocolFeeReceiver` is the same as the current `protocolFeeReceiver`.
    function setProtocolFeeReceiver(address protocolFeeReceiver) external;

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

    /// @dev Burns exactly shares from owner and sends proportional amounts of aggregated vaults' shares and idle assets.
    /// @dev MUST emit the EmergencyWithdraw event.
    /// @dev MUST never be paused.
    /// @return assets Amount of the underlying assets transferred to the `account`
    /// @return vaultsShares List of the aggregated vaults' shares amounts that were transferred to the `account`.
    function emergencyRedeem(uint256 shares, address account, address owner)
        external
        returns (uint256 assets, uint256[] memory vaultsShares);
}
