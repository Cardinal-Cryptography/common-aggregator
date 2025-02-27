// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

uint256 constant MAX_BPS = 10_000;

/// @notice Returns weighted average of v1 and v2, rounded down.
/// Reverts if w1+w2 is zero, overflows uint256, or if the result overflows uint256.
function weightedAvg(uint256 v1, uint256 w1, uint256 v2, uint256 w2) pure returns (uint256 result) {
    uint256 weightSum = w1 + w2;

    (uint256 a, uint256 rA) = mulDivWithRest(v1, w1, weightSum);
    (uint256 b, uint256 rB) = mulDivWithRest(v2, w2, weightSum);

    result = a + b;

    if (weightSum - rA <= rB) {
        result += 1;
    }
}

/// @notice Computes a.mulDiv(b,c) with full precision and returns also the remainder.
/// Reverts if c is zero, or if the result overflows uint256.
function mulDivWithRest(uint256 a, uint256 b, uint256 c) pure returns (uint256 result, uint256 rest) {
    result = Math.mulDiv(a, b, c);
    unchecked {
        uint256 x = a * b;
        uint256 y = result * c;
        rest = x - y;
    }
}
