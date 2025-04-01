// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

uint256 constant MAX_BPS = 10_000;

error AdditionOverflow(uint256 fileId, uint256 id);
error MultiplicationOverflow(uint256 fileId, uint256 id);
error DivisionByZero(uint256 fileId, uint256 id);
error SubtractionOverflow(uint256 fileId, uint256 id);

function checkedAdd(uint256 a, uint256 b, uint256 fileId, uint256 id) pure returns (uint256 result) {
    bool success;
    (success, result) = Math.tryAdd(a, b);
    if (!success) revert AdditionOverflow(fileId, id);
}

function checkedMul(uint256 a, uint256 b, uint256 fileId, uint256 id) pure returns (uint256 result) {
    bool success;
    (success, result) = Math.tryMul(a, b);
    if (!success) revert MultiplicationOverflow(fileId, id);
}

function checkedDiv(uint256 a, uint256 b, uint256 fileId, uint256 id) pure returns (uint256 result) {
    bool success;
    (success, result) = Math.tryDiv(a, b);
    if (!success) revert DivisionByZero(fileId, id);
}

function checkedSub(uint256 a, uint256 b, uint256 fileId, uint256 id) pure returns (uint256 result) {
    bool success;
    (success, result) = Math.trySub(a, b);
    if (!success) revert SubtractionOverflow(fileId, id);
}

/// @notice Returns weighted average of v1 and v2, rounded down.
/// Reverts if w1+w2 is zero, overflows uint256, or if the result overflows uint256.
function weightedAvg(uint256 v1, uint256 w1, uint256 v2, uint256 w2) pure returns (uint256 result) {
    uint256 weightSum = checkedAdd(w1, w2, 0, 1);

    (uint256 a, uint256 rA) = mulDivWithRemainder(v1, w1, weightSum);
    (uint256 b, uint256 rB) = mulDivWithRemainder(v2, w2, weightSum);

    result = a + b;

    if (weightSum - rA <= rB) {
        ++result;
    }
}

/// @notice Computes a.mulDiv(b,c) with full precision and returns also the remainder.
/// Reverts if c is zero, or if the result overflows uint256.
function mulDivWithRemainder(uint256 a, uint256 b, uint256 c) pure returns (uint256 result, uint256 remainder) {
    result = Math.mulDiv(a, b, c);
    unchecked {
        uint256 x = a * b;
        uint256 y = result * c;
        remainder = x - y;
    }
}
