// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";
import {weightedAvg, saturatingAdd} from "./../contracts/Math.sol";

contract MathTest is Test {
    using Math for uint256;

    function test_saturatingAdd() public pure {
        assertEq(saturatingAdd(1, 2), 3);
        assertEq(saturatingAdd(1, type(uint256).max), type(uint256).max);
        assertEq(saturatingAdd(0, type(uint256).max), type(uint256).max);
        assertEq(saturatingAdd(5, type(uint256).max - 6), type(uint256).max - 1);
        assertEq(saturatingAdd(type(uint256).max, type(uint256).max), type(uint256).max);
    }

    /// forge-config: default.fuzz.runs = 5000
    function testFuzz_weightedAvg(uint256 v1, uint256 w1, uint256 v2, uint256 w2) public pure {
        v1 = bound(v1, 0, (1 << 127));
        w1 = bound(w1, 0, (1 << 127) - 1);
        v2 = bound(v2, 0, (1 << 127));
        w2 = bound(w2, 0, (1 << 127) - 1);
        vm.assume(w1 + w2 > 0);

        uint256 result = weightedAvg(v1, w1, v2, w2);
        assertEq(result, (v1 * w1 + v2 * w2) / (w1 + w2));
    }
}
