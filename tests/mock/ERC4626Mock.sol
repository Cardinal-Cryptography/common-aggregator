// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {IERC20, ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

contract ERC4626Mock is ERC4626 {
    constructor(address asset) ERC20("ERC4626Mock", "E4626M") ERC4626(IERC20(asset)) {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function burn(address account, uint256 amount) external {
        _burn(account, amount);
    }
}
