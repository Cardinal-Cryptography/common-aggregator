// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {IExample} from "./interfaces/IExample.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

contract Example is IExample {
    constructor() {}

    function example() external {}
}
