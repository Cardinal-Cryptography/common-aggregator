// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {IERC20, ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract ERC4626Mock is ERC4626 {
    uint256 depositLimit;
    uint256 mintLimit;
    uint256 withdrawLimit;
    uint256 redeemLimit;
    bool reverting;

    constructor(address asset) ERC20("ERC4626Mock", "E4626M") ERC4626(IERC20(asset)) {
        depositLimit = type(uint256).max;
        mintLimit = type(uint256).max;
        withdrawLimit = type(uint256).max;
        redeemLimit = type(uint256).max;
        reverting = false;
    }

    function maxDeposit(address) public view override returns (uint256) {
        if (reverting) {
            revert();
        }

        return depositLimit;
    }

    function maxMint(address) public view override returns (uint256) {
        if (reverting) {
            revert();
        }

        return mintLimit;
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        if (reverting) {
            revert();
        }

        return Math.min(super.maxWithdraw(owner), withdrawLimit);
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        if (reverting) {
            revert();
        }

        return Math.min(super.maxRedeem(owner), redeemLimit);
    }

    function setDepositLimit(uint256 limit) external {
        depositLimit = limit;
    }

    function setMintLimit(uint256 limit) external {
        mintLimit = limit;
    }

    function setWithdrawLimit(uint256 limit) external {
        withdrawLimit = limit;
    }

    function setRedeemLimit(uint256 limit) external {
        redeemLimit = limit;
    }

    function setReverting(bool _reverting) external {
        reverting = _reverting;
    }

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function burn(address account, uint256 amount) external {
        _burn(account, amount);
    }
}
