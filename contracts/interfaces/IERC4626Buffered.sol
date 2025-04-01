// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

interface IERC4626Buffered is IERC4626 {
    event HoldingsStateUpdated(uint256 oldCachedAssets, uint256 newCachedAssets);

    function updateHoldingsState() external;
}
