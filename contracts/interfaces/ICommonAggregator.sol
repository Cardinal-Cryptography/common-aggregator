// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {IERC4626, IERC4626Buffered} from "contracts/interfaces/IERC4626Buffered.sol";

interface ICommonAggregator is IERC4626Buffered {
    // ----- Reporting -----

    event VaultWithdrawFailed(IERC4626 vault);

    error InsufficientAssetsForWithdrawal(uint256 missing);
    error IncorrectAsset(address expected, address actual);
    error VaultAlreadyAdded(IERC4626 vault);
    error VaultLimitExceeded();

    // ----- Vault management -----

    event VaultAdded(address indexed vault);
    event VaultRemoved(address indexed vault);
    event VaultForceRemoved(address indexed vault);

    function addVault(IERC4626 vault) external;
    function removeVault(IERC4626 vault) external;
    function forceRemoveVault(IERC4626 vault) external;

    function tryExitVault(IERC4626 vault) external;

    // ----- Deposits -----

    event DepositedToVault(address indexed vault, uint256 amountPlanned, uint256 amountDeposited);

    // ----- Withdrawals -----

    error CallerNotAggregator();
    error NotEnoughFunds();
    error AggregatedVaultWithdrawalLimitExceeded(address vault, uint256 maxWithdraw, uint256 amount);

    event ProportionalWithdrawalFailed(uint256 amount);

    // ----- Rebalancing -----

    event AssetsRebalanced(address indexed from, address indexed to, uint256 amount);

    function pushFunds(uint256 assets, IERC4626 vault) external;
    function pullFunds(uint256 assets, IERC4626 vault) external;
    function pullFundsByShares(uint256 shares, IERC4626 vault) external;

    error AllocationLimitExceeded(IERC4626 vault);

    // ----- Allocation Limits -----

    event AllocationLimitSet(address indexed vault, uint256 newLimitBps);

    error VaultNotOnTheList(IERC4626 vault);
    error IncorrectMaxAllocationLimit();

    function setLimit(IERC4626 vault, uint256 newLimitBps) external;

    // ----- Fee management -----

    event ProtocolFeeChanged(uint256 oldProtocolFee, uint256 newProtocolFee);
    event ProtocolFeeReceiverChanged(address indexed oldPorotocolFeeReceiver, address indexed newPorotocolFeeReceiver);

    error ProtocolFeeTooHigh();
    error SelfProtocolFeeReceiver();

    // ----- Non-asset rewards trading -----

    event RewardsTransferred(address indexed rewardToken, uint256 amount, address indexed receiver);

    error InvalidRewardToken(address token);

    function transferRewardsForSale(address rewardToken, address rewardTrader) external;

    function isVaultOnTheList(IERC4626 vault) external view returns (bool);

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

    function emergencyRedeem(uint256 shares, address receiver, address owner)
        external
        returns (uint256 assets, uint256[] memory vaultsShares);

    // ----- Access control -----

    error CallerNotManagement();

    function ensureTokenIsNotInherentlyUsed(address token) external;

    // ----- Pausable -----

    function pauseUserInteractions() external;
    function unpauseUserInteractions() external;
    function paused() external view returns (bool);
}
