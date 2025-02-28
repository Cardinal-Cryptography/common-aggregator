// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

interface ICommonAggregator is IERC4626 {
    // ----- Reporting -----

    event HoldingsStateUpdated(uint256 oldCachedAssets, uint256 newCachedAssets);

    function updateHoldingsState() external;

    // ----- Rebalancing -----

    event AssetsRebalanced(address indexed from, address indexed to, uint256 amount);

    /// @notice Withdraws `assets` from `vault` into aggregator's own balance.
    /// Vault must be present on the vault list.
    /// @dev Doesn't check the allocation limits, as even if they are still
    /// exceeded, the total excess will be lowered.
    function pullFunds(uint256 assets, address vault) external;

    /// @notice Redeems `shares` from `vault`, returning assets into
    /// aggregator's own balance. Vault must be present on the vault list.
    /// @dev Similarly to `pullFunds`, doesn't check the allocation limits.
    function pullFundsByShares(uint256 shares, address _vault) external;

    /// @notice Deposits `assets` from aggregator's own balance into `vault`.
    /// Vault must be present on the vault list. Allocation limits are checked.
    function pushFunds(uint256 assets, address vault) external;

    // ----- Allocation Limits -----

    event AllocationLimitSet(address indexed vault, uint256 newLimitBps);

    /// @notice Sets allocation limit of `vault` to `newLimitBps`.
    /// The limit is expressed in bps, and is applied on the assets.
    /// It's a no-op if `newLimitBps` is the same as the current limit.
    /// Reverts if `newLimitBps` is higher MAX_BPS, or if `vault` is not present
    /// on the vault list.
    function setLimit(address vault, uint256 newLimitBps) external;

    // ----- Fee management -----

    event ProtocolFeeChanged(uint256 oldProtocolFee, uint256 newProtocolFee);

    event ProtocolFeeReceiverChanged(address indexed oldPorotocolFeeReceiver, address indexed newPorotocolFeeReceiver);

    error ProtocolFeeTooHigh();

    /// @notice Sets bps-wise protocol fee.
    /// The protocol fee is applied on the profit made, with each holdings state update.
    /// It's a no-op if `_protocolFeeBps` is the same as the current `protocolFeeBps`.
    function setProtocolFee(uint256 protocolFeeBps) external;

    /// @notice Sets the protocol fee receiver.
    /// It's a no-op if `protocolFeeReceiver` is the same as the current `protocolFeeReceiver`.
    function setProtocolFeeReceiver(address protocolFeeReceiver) external;
}
