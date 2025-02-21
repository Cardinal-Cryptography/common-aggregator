// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {ICommonAggregator} from "./interfaces/ICommonAggregator.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

contract CommonAggregator is ICommonAggregator, UUPSUpgradeable, AccessControlUpgradeable {
    bytes32 public constant OWNER = keccak256("OWNER");
    bytes32 public constant MANAGER = keccak256("MANAGER");
    bytes32 public constant REBALANCER = keccak256("REBALANCER");
    bytes32 public constant GUARDIAN = keccak256("GUARDIAN");

    uint256 public constant MAX_VAULTS = 5;
    uint256 public constant MAX_BPS = 10000;

    /// @custom:storage-location erc7201:common.storage.aggregator
    struct AggregatorStorage {
        uint256 assetsCached;
        IERC4626[] vaults; // Both for iterating and a fallback queue.
        mapping(address vault => uint256 limit) allocationLimit; 
    }

    // keccak256(abi.encode(uint256(keccak256("common.storage.aggregator")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant AGGREGATOR_STORAGE_LOCATION = 0x1344fc1d9208ab003bf22755fd527b5337aabe73460e3f8720ef6cfd49b61d00;
    function _getAggregatorStorage() private pure returns (AggregatorStorage storage $) {
        assembly {
            $.slot := AGGREGATOR_STORAGE_LOCATION
        }
    }

    function initialize(address owner, IERC4626[] memory vaults) public initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, owner);
        _grantRole(OWNER, owner);

        AggregatorStorage storage $ = _getAggregatorStorage();
        $.assetsCached = 0;

        for (uint256 i = 0; i < vaults.length; i++) {
            _ensureVaultCanBeAdded(address(vaults[i]));
            $.vaults.push(vaults[i]);
            $.allocationLimit[address(vaults[i])] = MAX_BPS;
        }
    }

    function _ensureVaultCanBeAdded(address vault) private view {
        require(vault != address(0), "CommonAggregator: zero address");

        AggregatorStorage storage $ = _getAggregatorStorage();
        require($.vaults.length <  MAX_VAULTS, "CommonAggregator: too many vaults");
        for (uint256 i = 0; i < $.vaults.length; i++) {
            require(address($.vaults[i]) != vault, "CommonAggregator: vault already exists");
        }
    }

    constructor() {
        _disableInitializers();
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(OWNER) {}
}
