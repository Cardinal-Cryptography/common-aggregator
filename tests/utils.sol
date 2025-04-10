// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {CommonDeployer} from "contracts/CommonDeployer.sol";
import {CommonAggregator} from "contracts/CommonAggregator.sol";
import {CommonManagement} from "contracts/CommonManagement.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC20Mock} from "tests/mock/ERC20Mock.sol";

function setUpAggregator(address owner, ERC20Mock asset, IERC4626[] memory vaults)
    returns (CommonAggregator aggregator, CommonManagement management)
{
    CommonDeployer factory = new CommonDeployer(owner);
    address aggregatorImpl = address(new CommonAggregator());
    address managementImpl = address(new CommonManagement());

    (address aggregatorAddr, address managementAddr) =
        factory.deployAggregator(aggregatorImpl, managementImpl, asset, vaults);

    aggregator = CommonAggregator(aggregatorAddr);
    management = CommonManagement(managementAddr);
}
