// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract CommonAggregatorTestnetAsset is ERC20, Ownable {
    constructor(address owner) ERC20("CommonAggregatorTestnetAsset", "CATA") Ownable(owner) {}

    error CallerNotMinter(address caller);

    mapping(address => bool) public minters;

    modifier onlyMinter() {
        require(minters[msg.sender], CallerNotMinter(msg.sender));
        _;
    }

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function burn(address account, uint256 amount) external {
        _burn(account, amount);
    }

    function addMintPermission(address account) external onlyOwner {
        minters[account] = true;
    }

    function revokeMintPermission(address account) external onlyOwner {
        minters[account] = false;
    }
}
