// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

contract CommonTimelocks {
    error ActionAlreadyRegistered(bytes32 actionHash);
    error ActionNotRegistered(bytes32 actionHash);
    error ActionTimelocked(bytes32 actionHash, uint256 lockedUntil);
    error ActionNotTimelocked(bytes32 actionHash, uint256 lockedUntil);

    // A special value for the timelock, which denotes that there is no registered timelock for the given action.
    uint256 private constant NOT_REGISTERED = 0;

    /// @custom:storage-location erc7201:common.storage.timelocks
    struct TimelocksStorage {
        mapping(bytes32 actionHash => uint256 lockedUntil) registeredTimelocks;
    }

    // keccak256(abi.encode(uint256(keccak256("common.storage.timelocks")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant TIMELOCKS_STORAGE_LOCATION = 0xb4b5f37798c0578cab1322f006334977322f38ac9cf72880f6abeef244238800;
    function _getTimelocksStorage() private pure returns (TimelocksStorage storage $) {
        assembly {
            $.slot := TIMELOCKS_STORAGE_LOCATION
        }
    }

    // Adds a timelock entry for the given action if it doesn't exist yet. It is safely assumed that
    // `block.timestamp` is greater than 0.
    function register(bytes32 actionHash, uint256 delay) public {
        TimelocksStorage storage $ = _getTimelocksStorage();
        if ($.registeredTimelocks[actionHash] != NOT_REGISTERED) {
            revert ActionAlreadyRegistered(actionHash);
        }
        $.registeredTimelocks[actionHash] = block.timestamp + delay;
    }

    // Removes a timelock entry for the given action, if it exists, and the timelock has passed.
    function execute(bytes32 actionHash) public {
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

    // Removes a timelock entry for the given action, if it exists, and the timelock has not passed yet.
    function cancel(bytes32 actionHash) public {
        TimelocksStorage storage $ = _getTimelocksStorage();
        uint256 lockedUntil = $.registeredTimelocks[actionHash];
        if (lockedUntil == NOT_REGISTERED) {
            revert ActionNotRegistered(actionHash);
        }
        if (lockedUntil < block.timestamp) {
            revert ActionNotTimelocked(actionHash, lockedUntil);
        }
        delete $.registeredTimelocks[actionHash];
    }
}