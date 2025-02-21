// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {CommonAggregator} from "contracts/CommonAggregator.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

contract CommonAggregatorTest is Test {
    CommonAggregator commonAggregator;
    address owner = address(0x123);

    function setUp() public {
        CommonAggregator implementation = new CommonAggregator();
        IERC4626[] memory vaults = new IERC4626[](2);
        vaults[0] = IERC4626(0x0000000000000000000000000000000000000001);
        vaults[1] = IERC4626(0x0000000000000000000000000000000000000002);

        bytes memory initializeData = abi.encodeWithSelector(CommonAggregator.initialize.selector, owner, vaults);

        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initializeData);
        commonAggregator = CommonAggregator(address(proxy));
    }

    function testRoleGranting() public {
        assertTrue(commonAggregator.hasRole(commonAggregator.DEFAULT_ADMIN_ROLE(), owner));
        assertTrue(commonAggregator.hasRole(commonAggregator.OWNER(), owner));

        address otherAccount = address(0x456);
        assertFalse(commonAggregator.hasRole(commonAggregator.OWNER(), otherAccount));
        assertFalse(commonAggregator.hasRole(commonAggregator.MANAGER(), otherAccount));

        vm.prank(owner);
        commonAggregator.grantRole(keccak256("MANAGER"), otherAccount);
        assertTrue(commonAggregator.hasRole(commonAggregator.MANAGER(), otherAccount));
    }
}
