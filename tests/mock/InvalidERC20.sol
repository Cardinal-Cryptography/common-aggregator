// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev ERC-20 like token with too many decimals
contract InvalidERC20 is ERC20 {
    constructor() ERC20("", "") {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function burn(address account, uint256 amount) external {
        _burn(account, amount);
    }

    function decimals() public view virtual override returns (uint8) {
        revert();
    }
}
