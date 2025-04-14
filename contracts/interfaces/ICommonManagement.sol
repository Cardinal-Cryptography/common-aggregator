// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

interface ICommonManagement {
    // ----- Aggregator Upgrades -----

    event AggregatorUpgradeSubmitted(address indexed newImplementation, uint256 unlockTimestamp);
    event AggregatorUpgradeCancelled(address indexed newImplementation);
    event AggregatorUpgraded(address indexed newImplementation);

    function submitUpgradeAggregator(address newImplementation) external;

    function cancelUpgradeAggregator(address newImplementation) external;

    function upgradeAggregator(address newImplementation, bytes memory callData) external;

    // ----- Management Upgrades -----

    event ManagementUpgradeSubmitted(address indexed newImplementation, uint256 unlockTimestamp);
    event ManagementUpgradeCancelled(address indexed newImplementation);
    event ManagementUpgradeAuthorized(address indexed newImplementation);

    function submitUpgradeManagement(address newImplementation) external;

    function cancelUpgradeManagement(address newImplementation) external;

    // ----- Vault management -----

    event VaultAdditionSubmitted(address indexed vault, uint256 unlockTimestamp);
    event VaultAdditionCancelled(address indexed vault);

    event VaultForceRemovalSubmitted(address indexed vault, uint256 unlockTimestamp);
    event VaultForceRemovalCancelled(address indexed vault);

    error PendingVaultForceRemoval(IERC4626 vault);
    error VaultAdditionAlreadyPending(IERC4626 vault);

    function submitAddVault(IERC4626 vault) external;
    function cancelAddVault(IERC4626 vault) external;
    function addVault(IERC4626 vault) external;

    function removeVault(IERC4626 vault) external;

    function submitForceRemoveVault(IERC4626 vault) external;

    function cancelForceRemoveVault(IERC4626 vault) external;

    function forceRemoveVault(IERC4626 vault) external;

    // ----- Rebalancing -----

    function pushFunds(uint256 assets, IERC4626 vault) external;

    function pullFunds(uint256 assets, IERC4626 vault) external;

    function pullFundsByShares(uint256 shares, IERC4626 vault) external;

    // ----- Allocation Limits -----

    function setLimit(IERC4626 vault, uint256 newLimitBps) external;

    // ----- Fee management -----

    function setProtocolFee(uint256 _protocolFeeBps) external;

    function setProtocolFeeReceiver(address protocolFeeReceiver) external;

    // ----- Non-asset rewards trading -----

    event SetRewardsTraderSubmitted(
        address indexed rewardToken, address indexed traderAddress, uint256 unlockTimestamp
    );
    event SetRewardsTraderCancelled(address indexed rewardToken, address indexed traderAddress);
    event RewardsTraderSet(address indexed rewardToken, address indexed traderAddress);

    error InvalidRewardToken(address token);
    error NoTraderSetForToken(address token);

    function submitSetRewardTrader(address rewardToken, address traderAddress) external;

    function setRewardTrader(address rewardToken, address traderAddress) external;

    function cancelSetRewardTrader(address rewardToken, address traderAddress) external;

    function transferRewardsForSale(address token) external;

    // ----- Pausing -----

    error PendingVaultForceRemovals(uint256 count);

    function pauseUserInteractions() external;

    function unpauseUserInteractions() external;

    // ----- Access control -----

    enum Roles {
        Manager,
        Rebalancer,
        Guardian
    }

    event RoleGranted(Roles role, address indexed account);
    event RoleRevoked(Roles role, address indexed account);

    error CallerNotRebalancerOrWithHigherRole();
    error CallerNotManagerNorOwner();
    error CallerNotGuardianOrWithHigherRole();
}
