// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {CommonManagement} from "contracts/CommonManagement.sol";

/// Trivial implementation of `CommonTimelocks`
contract CommonManagementImpl is CommonManagement {
    function register(bytes32 actionHash, bytes32 actionData, uint256 delay)
        external
        registersAction(actionHash, actionData, delay)
    {}
    function execute(bytes32 actionHash, bytes32 actionData) external executesAction(actionHash, actionData) {}
    function cancel(bytes32 actionHash) external cancelsAction(actionHash) {}
}

contract TimelocksTest is Test {
    CommonManagementImpl management = new CommonManagementImpl();
    bytes32 emptyActionData = 0;
    bytes32 nonemptyActionData = bytes32(uint256(1));

    // Basic success / failure scenarios

    function testExecuteAfterTimelockSucceeds() public {
        vm.warp(1000);
        bytes32 actionHash = bytes32(0);
        management.register(actionHash, emptyActionData, 100);

        vm.warp(1101);
        management.execute(actionHash, emptyActionData);
    }

    function testExecuteDuringTimelockFails() public {
        vm.warp(1000);
        bytes32 actionHash = bytes32(0);
        management.register(actionHash, emptyActionData, 100);

        vm.warp(1100);
        vm.expectRevert(abi.encodeWithSelector(CommonManagement.ActionTimelocked.selector, actionHash, 1100));
        management.execute(actionHash, emptyActionData);
    }

    function testCancelDuringTimelockSucceeds() public {
        vm.warp(1000);
        bytes32 actionHash = bytes32(0);
        management.register(actionHash, emptyActionData, 100);

        vm.warp(1100);
        management.cancel(actionHash);
    }

    function testCancelAfterTimelockSucceeds() public {
        vm.warp(1000);
        bytes32 actionHash = bytes32(0);
        management.register(actionHash, emptyActionData, 100);

        vm.warp(1101);
        management.cancel(actionHash);
    }

    function testExecuteWithBadActionDataFails() public {
        vm.warp(1000);
        bytes32 actionHash = bytes32(0);
        management.register(actionHash, nonemptyActionData, 200);

        vm.warp(1201);
        vm.expectRevert(
            abi.encodeWithSelector(CommonManagement.IncorrectActionData.selector, actionHash, emptyActionData)
        );
        management.execute(actionHash, emptyActionData);
    }

    // More complex scenario

    function testManyActions() public {
        vm.warp(2000);
        bytes32 actionHash0 = bytes32(0);
        bytes32 actionHash1 = bytes32(uint256(1));
        bytes32 actionHash2 = bytes32(uint256(2));

        management.register(actionHash0, emptyActionData, 150); // ends in 2150
        vm.warp(2100);
        management.register(actionHash1, nonemptyActionData, 40); // ends in 2140
        vm.warp(2130);

        vm.expectRevert(abi.encodeWithSelector(CommonManagement.ActionTimelocked.selector, actionHash0, 2150));
        management.execute(actionHash0, emptyActionData);
        // Non-empty action data was used in submission for `actionHash1` but the timelock check goes first
        vm.expectRevert(abi.encodeWithSelector(CommonManagement.ActionTimelocked.selector, actionHash1, 2140));
        management.execute(actionHash1, emptyActionData);
        vm.expectRevert(abi.encodeWithSelector(CommonManagement.ActionNotRegistered.selector, actionHash2));
        management.execute(actionHash2, emptyActionData);

        management.register(actionHash2, emptyActionData, 0); // lock only for the current second
        vm.expectRevert(abi.encodeWithSelector(CommonManagement.ActionTimelocked.selector, actionHash2, 2130));
        management.execute(actionHash2, emptyActionData); // immediate execution fails
        management.cancel(actionHash2); // immediate cancellation succeeds
        vm.expectRevert(abi.encodeWithSelector(CommonManagement.ActionNotRegistered.selector, actionHash2));
        management.execute(actionHash2, emptyActionData); // action got erased
        management.register(actionHash2, emptyActionData, 20); // ends in 2150

        vm.warp(2150);
        // After the timelock passes, wrong `actionData` is the reason of the revert.
        vm.expectRevert(
            abi.encodeWithSelector(CommonManagement.IncorrectActionData.selector, actionHash1, emptyActionData)
        );
        management.execute(actionHash1, emptyActionData);
        // Correct action data passed, should succeed.
        management.execute(actionHash1, nonemptyActionData);
        management.cancel(actionHash2);

        vm.warp(2200);
        management.execute(actionHash0, emptyActionData);

        // No action remaining
        vm.expectRevert(abi.encodeWithSelector(CommonManagement.ActionNotRegistered.selector, actionHash0));
        management.execute(actionHash0, emptyActionData);
        vm.expectRevert(abi.encodeWithSelector(CommonManagement.ActionNotRegistered.selector, actionHash1));
        management.execute(actionHash1, nonemptyActionData);
        vm.expectRevert(abi.encodeWithSelector(CommonManagement.ActionNotRegistered.selector, actionHash2));
        management.execute(actionHash2, emptyActionData);
    }

    // Operations on not registered actions

    function testExecuceUnregisteredFails() public {
        bytes32 actionHash = bytes32(0);
        vm.expectRevert(abi.encodeWithSelector(CommonManagement.ActionNotRegistered.selector, actionHash));
        management.execute(actionHash, emptyActionData);
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
        management.register(actionHash, emptyActionData, 200);
        vm.expectRevert(abi.encodeWithSelector(CommonManagement.ActionAlreadyRegistered.selector, actionHash));

        vm.warp(3500);
        management.register(actionHash, emptyActionData, 300);
    }

    function testExecuteTwiceFails() public {
        vm.warp(500);
        bytes32 actionHash = bytes32(0);
        management.register(actionHash, emptyActionData, 400);

        vm.warp(901);
        management.execute(actionHash, emptyActionData);
        vm.expectRevert(abi.encodeWithSelector(CommonManagement.ActionNotRegistered.selector, actionHash));
        management.execute(actionHash, emptyActionData);
    }

    function testCancelTwiceFails() public {
        vm.warp(500);
        bytes32 actionHash = bytes32(0);
        management.register(actionHash, emptyActionData, 400);

        vm.warp(900);
        management.cancel(actionHash);
        vm.expectRevert(abi.encodeWithSelector(CommonManagement.ActionNotRegistered.selector, actionHash));
        management.execute(actionHash, emptyActionData);
    }

    // Arithmetic

    function testRegisterOverflowingTimelockSucceeds() public {
        vm.warp(type(uint256).max);
        bytes32 actionHash = bytes32(0);
        management.register(actionHash, emptyActionData, type(uint256).max);
    }
}
