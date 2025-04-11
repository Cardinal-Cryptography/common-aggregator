// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IAggregatorInitializator, IManagementInitializator} from "contracts/interfaces/Initialiators.sol";

contract CommonAggregatorDeployer {
    address public immutable DEPLOYER;
    bool public deployed;

    constructor() {
        DEPLOYER = msg.sender;
    }

    function deployAggregator(
        address aggregatorImplementation,
        address managementImplementation,
        address owner,
        IERC20Metadata asset,
        IERC4626[] calldata vaults
    ) external returns (address aggregator, address management) {
        assert(msg.sender == DEPLOYER);
        assert(!deployed);

        deployed = true;

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
