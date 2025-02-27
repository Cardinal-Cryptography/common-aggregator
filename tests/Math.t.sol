// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {mulDivWithRemainder, weightedAvg} from "../contracts/Math.sol";

contract MathTest is Test {
    using Math for uint256;

    function testFuzz_mulDivWithRest(uint256 a, uint256 b, uint256 c) public pure {
        c = bound(c, 1, (1 << 128));
        vm.assumeNoRevert();
        (uint256 result, uint256 remainder) = mulDivWithRemainder(a, b, c);

        assertEq(result, a.mulDiv(b, c));
        assertEq(remainder, ((a % c) * (b % c)) % c);
    }

    function testMulDivWithRestLargeC() public pure {
        uint256 a = 4732897652781643758234093141043853274932473125407432865;
        uint256 b = 728459023840348932574398734983274893580249038523047231493720402341441241;
        uint256 c = 10479995995237589649817928471289472894736782356287583657831;

        (uint256 result, uint256 remainder) = mulDivWithRemainder(a, b, c);
        assertEq(result, 328981232974548708214186098105237842163293481781749818122271454362570);
        assertEq(remainder, 226693107087029110362538539735492156198367250174955999795);
    }

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
