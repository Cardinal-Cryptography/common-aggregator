// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

interface ICommonAggregator is IERC4626 {
    // ----- Reporting -----

    event HoldingsStateUpdated(uint256 oldCachedAssets, uint256 newCachedAssets);

    function updateHoldingsState() external;

    // ----- Fee management -----

    event ProtocolFeeChanged(uint256 oldProtocolFee, uint256 newProtocolFee);

    event ProtocolFeeReceiverChanged(address indexed oldPorotocolFeeReceiver, address indexed newPorotocolFeeReceiver);

    error ProtocolFeeTooHigh();

    /// @notice Sets bps-wise protocol fee.
    /// The protocol fee is applied on the profit made, with each holdings state update.
    /// It's a no-op if `_protocolFeeBps` is the same as the current `protocolFeeBps`.
    function setProtocolFee(uint256 protocolFeeBps) external;

    /// @notice Sets the protocol fee receiver.
    /// It's a no-op if `protocolFeeReceiver` is the same as the current `protocolFeeReceiver`.
    function setProtocolFeeReceiver(address protocolFeeReceiver) external;
}
