// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {CommonAggregator} from "contracts/CommonAggregator.sol";
import {CommonManagement} from "contracts/CommonManagement.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC20Mock} from "tests/mock/ERC20Mock.sol";

function setUpAggregator(address owner, ERC20Mock asset, IERC4626[] memory vaults)
    returns (CommonAggregator aggregator, CommonManagement management)
{
    CommonAggregator aggregatorImplementation = new CommonAggregator();
    CommonManagement managementImplementation = new CommonManagement();
    ERC1967Proxy aggregatorProxy = new ERC1967Proxy(address(aggregatorImplementation), "");
    ERC1967Proxy managementProxy = new ERC1967Proxy(address(managementImplementation), "");
    aggregator = CommonAggregator(address(aggregatorProxy));
    management = CommonManagement(address(managementProxy));
    aggregator.initialize(address(management), asset, vaults);
    management.initialize(owner, aggregator);
}
