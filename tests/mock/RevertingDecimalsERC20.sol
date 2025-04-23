// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract RevertingDecimalsERC20 is ERC20 {
    constructor() ERC20("", "") {}

    function decimals() public view virtual override returns (uint8) {
        revert();
    }
}
