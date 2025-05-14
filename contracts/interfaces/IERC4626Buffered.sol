// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

interface IERC4626Buffered is IERC4626 {
    event HoldingsStateUpdated(
        uint256 oldCachedAssets, uint256 newCachedAssets, uint256 newBufferEnd, uint256 bufferedSharesAfter
    );

    function setProtocolFee(uint256 protocolFee) external;
    function setProtocolFeeReceiver(address protocolFeeReceiver) external;
    function updateHoldingsState() external;

    error IncorrectProtocolFee();
    error ZeroProtocolFeeReceiver();

    function getProtocolFee() external view returns (uint256);
    function getProtocolFeeReceiver() external view returns (address);
    function getLastUpdate() external view returns (uint256);
    function getBufferedShares() external view returns (uint256);
    function getCurrentBufferEnd() external view returns (uint256);
}
