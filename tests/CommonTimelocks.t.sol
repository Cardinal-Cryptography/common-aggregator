// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {CommonTimelocks} from "contracts/CommonTimelocks.sol";

contract CommonTimelocksTest is Test {
    CommonTimelocks timelocks;
    
    function setUp() public {
        timelocks = new CommonTimelocks();
    }

    function testSingleActionRegisterExecute() public {
        vm.roll(1);
        vm.warp(1000);

        bytes32 actionHash = bytes32(0);
        timelocks.register(actionHash, 100);

        vm.roll(2);
        vm.warp(1100);

        vm.expectRevert(abi.encodeWithSelector(CommonTimelocks.ActionTimelocked.selector, actionHash, 1100));
        timelocks.execute(actionHash);

        vm.roll(3);
        vm.warp(1101);
        timelocks.execute(actionHash);
    }

    function testSingleActionRegisterCancel() public {
        vm.roll(1);
        vm.warp(1000);

        bytes32 actionHash = bytes32(0);
        timelocks.register(actionHash, 100);

        vm.roll(2);
        vm.warp(1101);

        vm.expectRevert(abi.encodeWithSelector(CommonTimelocks.ActionNotTimelocked.selector, actionHash, 1100));
        timelocks.cancel(actionHash);

        vm.warp(1100); // earlier time, no roll
        timelocks.cancel(actionHash);
    }
}
