// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

interface IAggregatorInitializer {
    function initialize(address management, IERC20Metadata asset, address protocolFeeReceiver, IERC4626[] memory vaults)
        external;
}

interface IManagementInitializer {
    function initialize(address owner, address aggregator) external;
}
