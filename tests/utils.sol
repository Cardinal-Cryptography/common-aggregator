// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {CommonFactory, CommonAggregator, CommonManagement} from "contracts/CommonFactory.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC20Mock} from "tests/mock/ERC20Mock.sol";

function setUpAggregator(address owner, ERC20Mock asset, IERC4626[] memory vaults)
    returns (CommonAggregator aggregator, CommonManagement management)
{
    CommonFactory factory = new CommonFactory();
    return factory.deployAggregator(owner, asset, vaults);
}
