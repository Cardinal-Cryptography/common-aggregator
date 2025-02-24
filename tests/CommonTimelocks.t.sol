// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {CommonTimelocks} from "contracts/CommonTimelocks.sol";

contract CommonTimelocksTest is Test {
    CommonTimelocks timelocks;
    
    function setUp() public {
        timelocks = new CommonTimelocks();
    }

    // Simple scenarios

    function testSingleActionRegisterExecute() public {
        vm.warp(1000);
        bytes32 actionHash = bytes32(0);
        timelocks.register(actionHash, 100);

        vm.warp(1100);
        vm.expectRevert(abi.encodeWithSelector(CommonTimelocks.ActionTimelocked.selector, actionHash, 1100));
        timelocks.execute(actionHash);

        vm.warp(1101);
        timelocks.execute(actionHash);
    }

    function testSingleActionRegisterCancel() public {
        vm.warp(1000);
        bytes32 actionHash = bytes32(0);
        timelocks.register(actionHash, 100);

        vm.warp(1101);
        vm.expectRevert(abi.encodeWithSelector(CommonTimelocks.ActionNotTimelocked.selector, actionHash, 1100));
        timelocks.cancel(actionHash);

        vm.warp(1100); // earlier time
        timelocks.cancel(actionHash);
    }

    function testManyActions() public {
        vm.warp(2000);
        bytes32 actionHash0 = bytes32(0);
        bytes32 actionHash1 = bytes32(uint256(1));
        bytes32 actionHash2 = bytes32(uint256(2));

        timelocks.register(actionHash0, 150); // ends in 2150
        vm.warp(2100);
        timelocks.register(actionHash1, 40); // ends in 2140
        vm.warp(2130);

        vm.expectRevert(abi.encodeWithSelector(CommonTimelocks.ActionTimelocked.selector, actionHash0, 2150));
        timelocks.execute(actionHash0);
        vm.expectRevert(abi.encodeWithSelector(CommonTimelocks.ActionTimelocked.selector, actionHash1, 2140));
        timelocks.execute(actionHash1);
        vm.expectRevert(abi.encodeWithSelector(CommonTimelocks.ActionNotRegistered.selector, actionHash2));
        timelocks.execute(actionHash2);

        timelocks.register(actionHash2, 0); // lock only for the current second
        vm.expectRevert(abi.encodeWithSelector(CommonTimelocks.ActionTimelocked.selector, actionHash2, 2130));
        timelocks.execute(actionHash2); // immediate execution fails
        timelocks.cancel(actionHash2); // immediate cancellation succeeds
        vm.expectRevert(abi.encodeWithSelector(CommonTimelocks.ActionNotRegistered.selector, actionHash2));
        timelocks.execute(actionHash2); // action got erased
        timelocks.register(actionHash2, 10); // ends in 2140

        vm.warp(2140);
        timelocks.cancel(actionHash1);
        timelocks.cancel(actionHash2);

        vm.warp(2200);
        timelocks.execute(actionHash0);

        // No action remaining
        vm.expectRevert(abi.encodeWithSelector(CommonTimelocks.ActionNotRegistered.selector, actionHash0));
        timelocks.execute(actionHash0);
        vm.expectRevert(abi.encodeWithSelector(CommonTimelocks.ActionNotRegistered.selector, actionHash1));
        timelocks.execute(actionHash1);
        vm.expectRevert(abi.encodeWithSelector(CommonTimelocks.ActionNotRegistered.selector, actionHash2));
        timelocks.execute(actionHash2);
    }

    // Operations on not registered actions

    function testExecuceUnregisteredFails() public {
        bytes32 actionHash = bytes32(0);
        vm.expectRevert(abi.encodeWithSelector(CommonTimelocks.ActionNotRegistered.selector, actionHash));
        timelocks.execute(actionHash);
    }

    function testCancelUnregisteredFails() public {
        bytes32 actionHash = bytes32(0);
        vm.expectRevert(abi.encodeWithSelector(CommonTimelocks.ActionNotRegistered.selector, actionHash));
        timelocks.cancel(actionHash);
    }

    // When there are multiple identical operations, only the first one should succeed

    function testRegisterTwiceFails() public {
        vm.warp(500);
        bytes32 actionHash = bytes32(0);
        timelocks.register(actionHash, 200);
        vm.expectRevert(abi.encodeWithSelector(CommonTimelocks.ActionAlreadyRegistered.selector, actionHash));

        vm.warp(3500);
        timelocks.register(actionHash, 300);
    }

    function testExecuteTwiceFails() public {
        vm.warp(500);
        bytes32 actionHash = bytes32(0);
        timelocks.register(actionHash, 400);

        vm.warp(901);
        timelocks.execute(actionHash);
        vm.expectRevert(abi.encodeWithSelector(CommonTimelocks.ActionNotRegistered.selector, actionHash));
        timelocks.execute(actionHash);
    }

    function testCancelTwiceFails() public {
        vm.warp(500);
        bytes32 actionHash = bytes32(0);
        timelocks.register(actionHash, 400);

        vm.warp(900);
        timelocks.cancel(actionHash);
        vm.expectRevert(abi.encodeWithSelector(CommonTimelocks.ActionNotRegistered.selector, actionHash));
        timelocks.execute(actionHash);
    }
}
