// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {CommonAggregatorDeployer} from "contracts/CommonAggregatorDeployer.sol";
import {CommonAggregator, IERC4626} from "contracts/CommonAggregator.sol";
import {CommonManagement} from "contracts/CommonManagement.sol";
import {ERC20Mock} from "tests/mock/ERC20Mock.sol";

function setUpAggregator(address owner, ERC20Mock asset, IERC4626[] memory vaults)
    returns (CommonAggregator aggregator, CommonManagement management)
{
    CommonAggregatorDeployer factory = new CommonAggregatorDeployer();
    address aggregatorImpl = address(new CommonAggregator());
    address managementImpl = address(new CommonManagement());

    (address aggregatorAddr, address managementAddr) =
        factory.deployAggregator(aggregatorImpl, managementImpl, owner, asset, vaults);

    aggregator = CommonAggregator(aggregatorAddr);
    management = CommonManagement(managementAddr);
}
