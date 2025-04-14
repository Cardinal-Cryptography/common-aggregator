// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @dev Maximum basis points (BPS) value. 1 BPS = 0.01%
uint256 constant MAX_BPS = 10_000;

error AdditionOverflow(uint256 id);
error SubtractionOverflow(uint256 id);

function checkedAdd(uint256 a, uint256 b, uint256 id) pure returns (uint256 result) {
    bool success;
    (success, result) = Math.tryAdd(a, b);
    if (!success) revert AdditionOverflow(id);
}

function checkedSub(uint256 a, uint256 b, uint256 id) pure returns (uint256 result) {
    bool success;
    (success, result) = Math.trySub(a, b);
    if (!success) revert SubtractionOverflow(id);
}

/// @notice Returns `a + b`, or `type(uint256).max` if it would overflow. The function never reverts.
function saturatingAdd(uint256 a, uint256 b) pure returns (uint256 result) {
    unchecked {
        if (type(uint256).max - a < b) {
            result = type(uint256).max;
        } else {
            result = a + b;
        }
    }
}

/// @notice Returns `a - b`, or `0` if it would overflow. The function never reverts.
function saturatingSub(uint256 a, uint256 b) pure returns (uint256 result) {
    unchecked {
        if (b > a) {
            result = 0;
        } else {
            result = a - b;
        }
    }
}

/// @notice Returns weighted average of `v1` and `v2`, rounded down.
/// Reverts if `w1 + w2` is zero or it overflows `uint256`.
function weightedAvg(uint256 v1, uint256 w1, uint256 v2, uint256 w2) pure returns (uint256 result) {
    uint256 weightSum = checkedAdd(w1, w2, type(uint256).max);

    uint256 a = Math.mulDiv(v1, w1, weightSum);
    uint256 rA = mulmod(v1, w1, weightSum);
    uint256 b = Math.mulDiv(v2, w2, weightSum);
    uint256 rB = mulmod(v2, w2, weightSum);

    result = a + b;

    if (weightSum - rA <= rB) {
        ++result;
    }
}
