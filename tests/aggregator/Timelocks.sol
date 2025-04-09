// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {CommonManagement} from "contracts/CommonManagement.sol";

/// Trivial implementation of `CommonTimelocks`
contract CommonManagementImpl is CommonManagement {
    function register(bytes32 actionHash, uint256 delay) external registersTimelockedAction(actionHash, delay) {}
    function execute(bytes32 actionHash) external executesUnlockedAction(actionHash) {}
    function cancel(bytes32 actionHash) external cancelsAction(actionHash) {}
}

contract CommonTimelocksTest is Test {
    CommonManagementImpl management = new CommonManagementImpl();

    // Basic success / failure scenarios

    function testExecuteAfterTimelockSucceeds() public {
        vm.warp(1000);
        bytes32 actionHash = bytes32(0);
        management.register(actionHash, 100);

        vm.warp(1101);
        management.execute(actionHash);
    }

    function testExecuteDuringTimelockFails() public {
        vm.warp(1000);
        bytes32 actionHash = bytes32(0);
        management.register(actionHash, 100);

        vm.warp(1100);
        vm.expectRevert(abi.encodeWithSelector(CommonManagement.ActionTimelocked.selector, actionHash, 1100));
        management.execute(actionHash);
    }

    function testCancelDuringTimelockSucceeds() public {
        vm.warp(1000);
        bytes32 actionHash = bytes32(0);
        management.register(actionHash, 100);

        vm.warp(1100);
        management.cancel(actionHash);
    }

    function testCancelAfterTimelockSucceeds() public {
        vm.warp(1000);
        bytes32 actionHash = bytes32(0);
        management.register(actionHash, 100);

        vm.warp(1101);
        management.cancel(actionHash);
    }

    // More complex scenario

    function testManyActions() public {
        vm.warp(2000);
        bytes32 actionHash0 = bytes32(0);
        bytes32 actionHash1 = bytes32(uint256(1));
        bytes32 actionHash2 = bytes32(uint256(2));

        management.register(actionHash0, 150); // ends in 2150
        vm.warp(2100);
        management.register(actionHash1, 40); // ends in 2140
        vm.warp(2130);

        vm.expectRevert(abi.encodeWithSelector(CommonManagement.ActionTimelocked.selector, actionHash0, 2150));
        management.execute(actionHash0);
        vm.expectRevert(abi.encodeWithSelector(CommonManagement.ActionTimelocked.selector, actionHash1, 2140));
        management.execute(actionHash1);
        vm.expectRevert(abi.encodeWithSelector(CommonManagement.ActionNotRegistered.selector, actionHash2));
        management.execute(actionHash2);

        management.register(actionHash2, 0); // lock only for the current second
        vm.expectRevert(abi.encodeWithSelector(CommonManagement.ActionTimelocked.selector, actionHash2, 2130));
        management.execute(actionHash2); // immediate execution fails
        management.cancel(actionHash2); // immediate cancellation succeeds
        vm.expectRevert(abi.encodeWithSelector(CommonManagement.ActionNotRegistered.selector, actionHash2));
        management.execute(actionHash2); // action got erased
        management.register(actionHash2, 10); // ends in 2140

        vm.warp(2140);
        management.cancel(actionHash1);
        management.cancel(actionHash2);

        vm.warp(2200);
        management.execute(actionHash0);

        // No action remaining
        vm.expectRevert(abi.encodeWithSelector(CommonManagement.ActionNotRegistered.selector, actionHash0));
        management.execute(actionHash0);
        vm.expectRevert(abi.encodeWithSelector(CommonManagement.ActionNotRegistered.selector, actionHash1));
        management.execute(actionHash1);
        vm.expectRevert(abi.encodeWithSelector(CommonManagement.ActionNotRegistered.selector, actionHash2));
        management.execute(actionHash2);
    }

    // Operations on not registered actions

    function testExecuceUnregisteredFails() public {
        bytes32 actionHash = bytes32(0);
        vm.expectRevert(abi.encodeWithSelector(CommonManagement.ActionNotRegistered.selector, actionHash));
        management.execute(actionHash);
    }

    function testCancelUnregisteredFails() public {
        bytes32 actionHash = bytes32(0);
        vm.expectRevert(abi.encodeWithSelector(CommonManagement.ActionNotRegistered.selector, actionHash));
        management.cancel(actionHash);
    }

    // When there are multiple identical operations, only the first one should succeed

    function testRegisterTwiceFails() public {
        vm.warp(500);
        bytes32 actionHash = bytes32(0);
        management.register(actionHash, 200);
        vm.expectRevert(abi.encodeWithSelector(CommonManagement.ActionAlreadyRegistered.selector, actionHash));

        vm.warp(3500);
        management.register(actionHash, 300);
    }

    function testExecuteTwiceFails() public {
        vm.warp(500);
        bytes32 actionHash = bytes32(0);
        management.register(actionHash, 400);

        vm.warp(901);
        management.execute(actionHash);
        vm.expectRevert(abi.encodeWithSelector(CommonManagement.ActionNotRegistered.selector, actionHash));
        management.execute(actionHash);
    }

    function testCancelTwiceFails() public {
        vm.warp(500);
        bytes32 actionHash = bytes32(0);
        management.register(actionHash, 400);

        vm.warp(900);
        management.cancel(actionHash);
        vm.expectRevert(abi.encodeWithSelector(CommonManagement.ActionNotRegistered.selector, actionHash));
        management.execute(actionHash);
    }

    // Arithmetic

    function testRegisterOverflowingTimelockSucceeds() public {
        vm.warp(type(uint256).max);
        bytes32 actionHash = bytes32(0);
        management.register(actionHash, type(uint256).max);
    }
}
