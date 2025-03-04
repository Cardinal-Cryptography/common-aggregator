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

    // ----- Vault management -----

    event VaultAdditionSubmitted(address indexed vault, uint256 limit, uint256 unlockTimestamp);
    event VaultAdditionCancelled(address indexed vault, uint256 limit);
    event VaultAdded(address indexed vault, uint256 limit);

    event VaultRemoved(address indexed vault);

    event VaultForceRemovalSubmitted(address indexed vault, uint256 unlockTimestamp);
    event VaultForceRemovalCancelled(address indexed vault);
    event VaultForceRemoved(address indexed vault);

    function submitAddVault(IERC4626 vault, uint256 limit) external;
    function cancelAddVault(IERC4626 vault, uint256 limit) external;
    function addVault(IERC4626 vault, uint256 limit) external;

    function removeVault(IERC4626 vault) external;

    function submitForceRemoveVault(IERC4626 vault) external;
    function cancelForceRemoveVault(IERC4626 vault) external;
    function forceRemoveVault(IERC4626 vault) external;

    error PendingVaultForceRemoval(IERC4626 vault);

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
    function setProtocolFee(uint256 protocolFeeBps) external;

    error SelfProtocolFeeReceiver();
    error ZeroProtocolFeeReceiver();

    /// @notice Sets the protocol fee receiver.
    /// It's a no-op if `protocolFeeReceiver` is the same as the current `protocolFeeReceiver`.
    function setProtocolFeeReceiver(address protocolFeeReceiver) external;
}
