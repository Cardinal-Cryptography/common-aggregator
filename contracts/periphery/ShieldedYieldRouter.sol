// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import {IERC20, IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IShielder} from "./IShielder.sol";

contract ShieldedYieldRouter {
    constructor() {}

    /// @notice Mint exactly `amount` shares and deposit them in the `shielder`.
    /// @dev    The `msg.sender` must approve sufficient assets to this contract.
    /// @param shielder Shielder contract address
    /// @param vault ERC4626 Vault contract address
    /// @param amount Amount of the Vault shares to mint and shield
    function mintAndShieldWithNewAccount(
        address shielder,
        bytes3 expectedContractVersion,
        address vault,
        uint256 amount,
        uint256 newNote,
        uint256 prenullifier,
        uint256 symKeyEncryptionC1X,
        uint256 symKeyEncryptionC1Y,
        uint256 symKeyEncryptionC2X,
        uint256 symKeyEncryptionC2Y,
        uint256 macSalt,
        uint256 macCommitment,
        bytes calldata proof
    ) external {
        _mintShares(IERC4626(vault), amount);
        IERC20(vault).approve(shielder, amount);
        IShielder(shielder).newAccountERC20(
            expectedContractVersion,
            vault,
            amount,
            newNote,
            prenullifier,
            symKeyEncryptionC1X,
            symKeyEncryptionC1Y,
            symKeyEncryptionC2X,
            symKeyEncryptionC2Y,
            macSalt,
            macCommitment,
            proof
        );
    }

    /// @notice Mint exactly `amount` shares and deposit them in the `shielder`.
    /// @dev    The `msg.sender` must approve sufficient assets to this contract.
    /// @param shielder Shielder contract address
    /// @param vault ERC4626 Vault contract address
    /// @param amount Amount of the Vault shares to mint and shield
    function mintAndShield(
        address shielder,
        bytes3 expectedContractVersion,
        address vault,
        uint256 amount,
        uint256 oldNullifierHash,
        uint256 newNote,
        uint256 merkleRoot,
        uint256 macSalt,
        uint256 macCommitment,
        bytes calldata proof
    ) external {
        _mintShares(IERC4626(vault), amount);
        IERC20(vault).approve(shielder, amount);
        IShielder(shielder).depositERC20(
            expectedContractVersion, vault, amount, oldNullifierHash, newNote, merkleRoot, macSalt, macCommitment, proof
        );
    }

    function _mintShares(IERC4626 vault, uint256 shareAmount) private {
        IERC20 asset = IERC20(vault.asset());
        // compute how much asset is required to get `amount` shares
        uint256 assetAmount = vault.previewMint(shareAmount);
        // transfer assets from the msg.sender
        asset.transferFrom(msg.sender, address(this), assetAmount);
        // approve vault to spend assets
        asset.approve(address(vault), assetAmount);
        // mint shares
        vault.mint(shareAmount, address(this));
    }
}
