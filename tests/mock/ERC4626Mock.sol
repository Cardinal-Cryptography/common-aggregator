// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {IERC20, ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

contract ERC4626Mock is ERC4626 {
    uint256 depositLimit;
    uint256 mintLimit;

    constructor(address asset) ERC20("ERC4626Mock", "E4626M") ERC4626(IERC20(asset)) {
        depositLimit = type(uint256).max;
        mintLimit = type(uint256).max;
    }

    function maxDeposit(address) public view override returns (uint256) {
        return depositLimit;
    }

    function maxMint(address) public view override returns (uint256) {
        return mintLimit;
    }

    function setDepositLimit(uint256 limit) external {
        depositLimit = limit;
    }

    function setMintLimit(uint256 limit) external {
        mintLimit = limit;
    }

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function burn(address account, uint256 amount) external {
        _burn(account, amount);
    }
}
