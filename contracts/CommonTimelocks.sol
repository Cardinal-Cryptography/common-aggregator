// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

/// @title An abstract contract which manages timelocked actions.
/// @notice A timelocked action can be registered to be executed after the timelock passes. A registered action
/// can be cancelled anytime.
/// @dev The contract only exposes modifiers which can be used to guard access to action management functions
/// in the implementation.
abstract contract CommonTimelocks {
    error ActionAlreadyRegistered(bytes32 actionHash);
    error ActionNotRegistered(bytes32 actionHash);
    error ActionTimelocked(bytes32 actionHash, uint256 lockedUntil);

    // A special value for the timelock, which denotes that there is no registered timelock for the given action.
    uint256 private constant NOT_REGISTERED = 0;

    /// @custom:storage-location erc7201:common.storage.timelocks
    struct TimelocksStorage {
        mapping(bytes32 actionHash => uint256 lockedUntil) registeredTimelocks;
    }

    // keccak256(abi.encode(uint256(keccak256("common.storage.timelocks")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant TIMELOCKS_STORAGE_LOCATION =
        0xb4b5f37798c0578cab1322f006334977322f38ac9cf72880f6abeef244238800;

    function _getTimelocksStorage() private pure returns (TimelocksStorage storage $) {
        assembly {
            $.slot := TIMELOCKS_STORAGE_LOCATION
        }
    }

    /// @dev Utility function for addition which returns the maximal uint256 value if the result would overflow.
    function _saturatingAdd(uint256 a, uint256 b) private pure returns (uint256 result) {
        if (type(uint256).max - a < b) {
            result = type(uint256).max;
        } else {
            result = a + b;
        }
    }

    /// @dev Adds a timelock entry for the given action if it doesn't exist yet. It is safely assumed that `block.timestamp`
    /// is greater than zero. A zero `delay` means that the action is locked only for the current timestamp.
    function _register(bytes32 actionHash, uint256 delay) private {
        TimelocksStorage storage $ = _getTimelocksStorage();
        if ($.registeredTimelocks[actionHash] != NOT_REGISTERED) {
            revert ActionAlreadyRegistered(actionHash);
        }
        $.registeredTimelocks[actionHash] = _saturatingAdd(block.timestamp, delay);
    }

    /// @dev Removes a timelock entry for the given action if it exists and the timelock has passed.
    function _execute(bytes32 actionHash) private {
        TimelocksStorage storage $ = _getTimelocksStorage();
        uint256 lockedUntil = $.registeredTimelocks[actionHash];
        if (lockedUntil == NOT_REGISTERED) {
            revert ActionNotRegistered(actionHash);
        }
        if (lockedUntil >= block.timestamp) {
            revert ActionTimelocked(actionHash, lockedUntil);
        }
        delete $.registeredTimelocks[actionHash];
    }

    /// @dev Removes a timelock entry for the given action if it exists. Cancellation works both during
    /// and after the timelock period.
    function _cancel(bytes32 actionHash) private {
        TimelocksStorage storage $ = _getTimelocksStorage();
        if ($.registeredTimelocks[actionHash] == NOT_REGISTERED) {
            revert ActionNotRegistered(actionHash);
        }
        delete $.registeredTimelocks[actionHash];
    }

    /// @notice Use this modifier for functions which submit a timelocked action proposal.
    modifier registersTimelockedAction(bytes32 actionHash, uint256 delay) {
        _register(actionHash, delay);
        _;
    }

    /// @notice Use this modifier for functions which execute a previously submitted action whose timelock
    /// period has passed.
    modifier executesUnlockedAction(bytes32 actionHash) {
        _execute(actionHash);
        _;
    }

    /// @notice Use this modifier to cancel a previously submitted action, so that it can't be executed.
    modifier cancelsAction(bytes32 actionHash) {
        _cancel(actionHash);
        _;
    }
}
