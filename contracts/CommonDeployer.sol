// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

interface IAggregatorInitializator {
    function initialize(address management, IERC20Metadata asset, IERC4626[] memory vaults) external;
}

interface IManagementInitializator {
    function initialize(address owner, address aggregator) external;
}

contract CommonDeployer {
    address public immutable owner;

    constructor(address _owner) {
        owner = _owner;
    }

    function deployAggregator(
        address aggregatorImplementation,
        address managementImplementation,
        IERC20Metadata asset,
        IERC4626[] memory vaults
    ) external returns (address aggregator, address management) {
        ERC1967Proxy aggregatorProxy = new ERC1967Proxy(address(aggregatorImplementation), "");
        ERC1967Proxy managementProxy = new ERC1967Proxy(address(managementImplementation), "");

        aggregator = address(aggregatorProxy);
        management = address(managementProxy);

        IAggregatorInitializator aggregatorInit = IAggregatorInitializator(aggregator);
        IManagementInitializator managementInit = IManagementInitializator(management);

        aggregatorInit.initialize(management, asset, vaults);
        managementInit.initialize(owner, aggregator);
    }
}
