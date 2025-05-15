// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IAggregatorInitializer, IManagementInitializer} from "contracts/interfaces/Initializers.sol";

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
        address protocolFeeReceiver,
        IERC4626[] calldata vaults
    ) external returns (address aggregator, address management) {
        assert(msg.sender == DEPLOYER);
        assert(!deployed);

        deployed = true;

        ERC1967Proxy aggregatorProxy = new ERC1967Proxy(address(aggregatorImplementation), "");
        ERC1967Proxy managementProxy = new ERC1967Proxy(address(managementImplementation), "");

        aggregator = address(aggregatorProxy);
        management = address(managementProxy);

        IAggregatorInitializer aggregatorInit = IAggregatorInitializer(aggregator);
        IManagementInitializer managementInit = IManagementInitializer(management);

        aggregatorInit.initialize(management, asset, protocolFeeReceiver, vaults);
        managementInit.initialize(owner, aggregator);
    }
}
