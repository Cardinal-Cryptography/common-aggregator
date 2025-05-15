// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {CommonAggregator, ICommonAggregator, ERC4626BufferedUpgradeable} from "contracts/CommonAggregator.sol";
import {CommonManagement} from "contracts/CommonManagement.sol";
import {ERC1967Proxy, ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC4626Mock} from "tests/mock/ERC4626Mock.sol";
import {ERC20Mock} from "tests/mock/ERC20Mock.sol";
import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {
    AccessControlUpgradeable,
    IAccessControl
} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {
    IERC20,
    IERC4626,
    IERC20Metadata,
    SafeERC20,
    ERC20Upgradeable,
    ERC4626Upgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {Upgrades, Options} from "@openzeppelin/foundry-upgrades/src/Upgrades.sol";

error ContractIsNoLongerPauseable();

/// @custom:oz-upgrades-from contracts/CommonAggregator.sol:CommonAggregator
contract CommonAggregatorCorrectUpgrade is CommonAggregator {
    /// @custom:storage-location erc7201:new_storage
    struct NewStorage {
        bool newField;
    }

    bytes32 private constant NEW_STORAGE_LOCATION = 0x749198412094812840710389102840de12034892471284071385013704182041;

    function _getNewStorage() private pure returns (AggregatorStorage storage $) {
        assembly {
            $.slot := NEW_STORAGE_LOCATION
        }
    }

    function _pause() internal pure override {
        revert ContractIsNoLongerPauseable();
    }

    function newMethod() public pure returns (uint256) {
        return 42;
    }
}

/// @custom:oz-upgrades-from contracts/CommonAggregator.sol:CommonAggregator
contract CommonAggregatorUpgradeMissingNamespaceStorage is UUPSUpgradeable {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address, IERC20Metadata, IERC4626[] memory) public initializer {
        __UUPSUpgradeable_init();
    }

    function _authorizeUpgrade(address newImplementation) internal override {}
}

/// @custom:oz-upgrades-from contracts/CommonAggregator.sol:CommonAggregator
contract CommonAggregatorUpgradeMissingStorageFields is
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ERC4626BufferedUpgradeable,
    PausableUpgradeable
{
    /// @custom:storage-location erc7201:common.storage.aggregator
    struct AggregatorStorage {
        IERC4626[] vaults; // Both for iterating and a fallback queue.
        mapping(address vault => uint256 limit) allocationLimitBps;
        mapping(address rewardToken => address traderAddress) rewardTrader;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address, IERC20Metadata asset, IERC4626[] memory) public initializer {
        __ERC20_init("", "");
        __ERC4626Buffered_init(asset, address(1));
        __Pausable_init();
        __AccessControl_init();
    }

    function _authorizeUpgrade(address newImplementation) internal override {}
    function updateHoldingsState() external override {}
}

contract CommonAggregatorTest is Test {
    uint256 constant STARTING_TIMESTAMP = 100_000_000;
    address owner = address(0x123);
    ERC20Mock asset = new ERC20Mock();
    address protocolFeeReceiver = address(1);
    IERC4626[] vaults = new IERC4626[](1);

    address aggregatorProxy;
    address managementProxy;

    function testValidation() public {
        vaults[0] = new ERC4626Mock(address(asset));
        managementProxy = Upgrades.deployUUPSProxy("CommonManagement.sol", "");
        aggregatorProxy = Upgrades.deployUUPSProxy("CommonAggregator.sol", "");
        CommonManagement(managementProxy).initialize(owner, CommonAggregator(aggregatorProxy));
        CommonAggregator(aggregatorProxy).initialize(address(managementProxy), asset, protocolFeeReceiver, vaults);

        Options memory options;
        Upgrades.validateUpgrade("UpgradesOpenZeppelin.t.sol:CommonAggregatorCorrectUpgrade", options);
    }

    function testValidationWithMissingNamespaceStorage() public {
        vaults[0] = new ERC4626Mock(address(asset));
        managementProxy = Upgrades.deployUUPSProxy("CommonManagement.sol", "");
        aggregatorProxy = Upgrades.deployUUPSProxy("CommonAggregator.sol", "");
        CommonManagement(managementProxy).initialize(owner, CommonAggregator(aggregatorProxy));
        CommonAggregator(aggregatorProxy).initialize(address(managementProxy), asset, protocolFeeReceiver, vaults);

        vm.expectRevert();
        this.validateUpgrade("UpgradesOpenZeppelin.t.sol:CommonAggregatorUpgradeMissingNamespaceStorage");
    }

    function testValidationWithMissingStorageFields() public {
        vaults[0] = new ERC4626Mock(address(asset));
        managementProxy = Upgrades.deployUUPSProxy("CommonManagement.sol", "");
        aggregatorProxy = Upgrades.deployUUPSProxy("CommonAggregator.sol", "");
        CommonManagement(managementProxy).initialize(owner, CommonAggregator(aggregatorProxy));
        CommonAggregator(aggregatorProxy).initialize(address(managementProxy), asset, protocolFeeReceiver, vaults);

        vm.expectRevert();
        this.validateUpgrade("UpgradesOpenZeppelin.t.sol:CommonAggregatorUpgradeMissingStorageFields");
    }

    function validateUpgrade(string calldata contractName) external {
        Options memory options;
        Upgrades.validateUpgrade(contractName, options);
    }
}
