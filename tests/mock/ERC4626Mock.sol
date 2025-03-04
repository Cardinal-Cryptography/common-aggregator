// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {IERC20, ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract ERC4626Mock is ERC4626 {
    using Math for uint256;

    constructor(address asset) ERC20("ERC4626Mock", "E4626M") ERC4626(IERC20(asset)) {}

    uint256 private _maxWithdraw = type(uint256).max;
    uint256 private _maxRedeem = type(uint256).max;

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function burn(address account, uint256 amount) external {
        _burn(account, amount);
    }

    function setMaxWithdrawAndMaxRedeem(uint256 newMaxWithdraw, uint256 newMaxRedeem) external {
        _maxWithdraw = newMaxWithdraw;
        _maxRedeem = newMaxRedeem;
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        return _maxWithdraw.min(super.maxWithdraw(owner));
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        return _maxRedeem.min(super.maxRedeem(owner));
    }
}
