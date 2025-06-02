// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

interface IShielder {
    function newAccountERC20(
        bytes3 expectedContractVersion,
        address tokenAddress,
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
    ) external;

    function depositERC20(
        bytes3 expectedContractVersion,
        address tokenAddress,
        uint256 amount,
        uint256 oldNullifierHash,
        uint256 newNote,
        uint256 merkleRoot,
        uint256 macSalt,
        uint256 macCommitment,
        bytes calldata proof
    ) external;
}
