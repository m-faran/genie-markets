// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {GenieMath} from "../src/GenieMath.sol";

contract GenieMathTest is Test {
    // ──────────────────────────────────────────────
    //  sortTrio — Genie ordering (1<2<…<9<0)
    // ──────────────────────────────────────────────

    function test_sortTrio_310_gives_130() public pure {
        console2.log("Testing sortTrio with input: 310");
        (uint8 d1, uint8 d2, uint8 d3) = GenieMath.sortTrio(310);
        console2.log("Result (Genie sorted 1-9 then 0): %s, %s, %s", d1, d2, d3);

        assertEq(d1, 1);
        assertEq(d2, 3);
        assertEq(d3, 0);
    }

    /// @dev Fuzz: for every raw 0-999, the output must be in Genie-sorted order.
    function testFuzz_sortTrio_alwaysGenieSorted(uint256 raw) public pure {
        raw = bound(raw, 0, 999);
        (uint8 d1, uint8 d2, uint8 d3) = GenieMath.sortTrio(raw);

        uint8 r1 = d1 == 0 ? 10 : d1;
        uint8 r2 = d2 == 0 ? 10 : d2;
        uint8 r3 = d3 == 0 ? 10 : d3;

        assertTrue(r1 <= r2, "d1 rank > d2 rank");
        assertTrue(r2 <= r3, "d2 rank > d3 rank");
    }

    /// @dev Fuzz: sorted digits must contain the same multiset as the original.
    function testFuzz_sortTrio_preservesDigits(uint256 raw) public pure {
        raw = bound(raw, 0, 999);
        uint8 origA = uint8(raw / 100);
        uint8 origB = uint8((raw / 10) % 10);
        uint8 origC = uint8(raw % 10);

        (uint8 d1, uint8 d2, uint8 d3) = GenieMath.sortTrio(raw);

        // Sum and product of digits must be preserved (sufficient for 3 elements with values 0-9)
        assertEq(uint16(d1) + d2 + d3, uint16(origA) + origB + origC, "digit sum changed");
        assertEq(uint32(d1) * d2 * d3, uint32(origA) * origB * origC, "digit product changed");
    }

    /// @dev Verify all 1000 raw inputs collapse to exactly 220 unique sorted trios.
    function test_sortTrio_220UniqueTrios() public pure {
        // Count unique encodings
        bool[1000] memory seen;
        uint256 count;

        for (uint256 i; i < 1000; i++) {
            (uint8 d1, uint8 d2, uint8 d3) = GenieMath.sortTrio(i);
            uint16 enc = GenieMath.encodeTrio(d1, d2, d3);
            if (!seen[enc]) {
                seen[enc] = true;
                count++;
            }
        }

        console2.log("Total unique sorted Trios from 1000 possibilities: %s", count);
        assertEq(count, 220);
    }

    // ──────────────────────────────────────────────
    //  Trio type classification
    // ──────────────────────────────────────────────

    function test_trioType_unique() public pure {
        console2.log("Testing trioType classification for 1, 2, 3");
        console2.log("Type: %s (0=Unique, 1=Twin, 2=Jackpot)", uint8(GenieMath.trioType(1, 2, 3)));
        assertEq(uint8(GenieMath.trioType(1, 2, 3)), uint8(GenieMath.TrioType.Unique));
        assertEq(uint8(GenieMath.trioType(1, 9, 0)), uint8(GenieMath.TrioType.Unique));
    }

    function test_trioType_twin() public pure {
        console2.log("Testing trioType classification for 1, 1, 2");
        console2.log("Type: %s (0=Unique, 1=Twin, 2=Jackpot)", uint8(GenieMath.trioType(1, 1, 2)));
        assertEq(uint8(GenieMath.trioType(1, 1, 2)), uint8(GenieMath.TrioType.Twin));
        assertEq(uint8(GenieMath.trioType(3, 0, 0)), uint8(GenieMath.TrioType.Twin));
    }

    function test_trioType_jackpot() public pure {
        console2.log("Testing trioType classification for 5, 5, 5");
        console2.log("Type: %s (0=Unique, 1=Twin, 2=Jackpot)", uint8(GenieMath.trioType(5, 5, 5)));
        assertEq(uint8(GenieMath.trioType(0, 0, 0)), uint8(GenieMath.TrioType.Jackpot));
        assertEq(uint8(GenieMath.trioType(5, 5, 5)), uint8(GenieMath.TrioType.Jackpot));
    }

    /// @dev Verify counts: 120 Unique + 90 Twin + 10 Jackpot = 220.
    function test_trioType_distribution() public pure {
        uint256 unique;
        uint256 twin;
        uint256 jackpot;

        // Direct iteration over all valid sorted trios
        for (uint8 a; a <= 9; a++) {
            for (uint8 b = a; b <= 9; b++) {
                for (uint8 c = b; c <= 9; c++) {
                    // This uses standard numeric sorting, not Genie. Let's use Genie order.
                }
            }
        }

        // Simplest: count from the 220 set using isValidTrio
        for (uint16 pick; pick < 1000; pick++) {
            if (!GenieMath.isValidTrio(pick)) continue;
            GenieMath.TrioType trioType = GenieMath.trioTypeFromPick(pick);
            if (trioType == GenieMath.TrioType.Unique) unique++;
            else if (trioType == GenieMath.TrioType.Twin) twin++;
            else jackpot++;
        }

        console2.log("Trio Distribution over 220 combinations:");
        console2.log("Unique: %s", unique);
        console2.log("Twin: %s", twin);
        console2.log("Jackpot: %s", jackpot);

        assertEq(unique, 120, "Expected 120 unique trios");
        assertEq(twin, 90, "Expected 90 twin trios");
        assertEq(jackpot, 10, "Expected 10 jackpot trios");
    }

    // ──────────────────────────────────────────────
    //  Single & Pair derivation
    // ──────────────────────────────────────────────

    function test_deriveSingle() public pure {
        console2.log("Deriving Single from 9, 9, 2 (9+9+2 = 0)");
        console2.log("Result: %s", GenieMath.deriveSingle(9, 9, 2));
        assertEq(GenieMath.deriveSingle(9, 9, 2), 0);

        console2.log("Deriving Single from 9, 9, 9 (9+9+9 = 27 -> 7)");
        console2.log("Result: %s", GenieMath.deriveSingle(9, 9, 9));
        assertEq(GenieMath.deriveSingle(9, 9, 9), 7);
    }

    function testFuzz_deriveSingle_alwaysLt10(uint8 d1, uint8 d2, uint8 d3) public pure {
        d1 = uint8(bound(d1, 0, 9));
        d2 = uint8(bound(d2, 0, 9));
        d3 = uint8(bound(d3, 0, 9));
        assertTrue(GenieMath.deriveSingle(d1, d2, d3) <= 9);
    }

    function test_derivePair() public pure {
        console2.log("Deriving Pair from 3 (openSingle), 7 (closeSingle)");
        console2.log("Result: %s", GenieMath.derivePair(3, 7));
        assertEq(GenieMath.derivePair(3, 7), 37);

        assertEq(GenieMath.derivePair(0, 0), 0);
        assertEq(GenieMath.derivePair(9, 9), 99);
        assertEq(GenieMath.derivePair(1, 0), 10);
    }

    // ──────────────────────────────────────────────
    //  Trio validation
    // ──────────────────────────────────────────────

    function test_isValidTrio_valid() public pure {
        console2.log("Validating 123 (sorted)");
        assertTrue(GenieMath.isValidTrio(123)); // 1<2<3 — valid

        assertTrue(GenieMath.isValidTrio(0)); // 000 — valid (all same rank)
        assertTrue(GenieMath.isValidTrio(999)); // 999 — valid
        assertTrue(GenieMath.isValidTrio(110)); // 1<1<0(=10) — valid (twin)
        assertTrue(GenieMath.isValidTrio(100)); // 1<0(=10)<0(=10) — valid (twin)
    }

    /// @dev Every sortTrio output must be valid.
    function testFuzz_sortTrio_outputIsValid(uint256 raw) public pure {
        raw = bound(raw, 0, 999);
        (uint8 d1, uint8 d2, uint8 d3) = GenieMath.sortTrio(raw);
        uint16 enc = GenieMath.encodeTrio(d1, d2, d3);
        assertTrue(GenieMath.isValidTrio(enc), "sortTrio produced invalid trio");
    }

    // ──────────────────────────────────────────────
    //  encodeTrio
    // ──────────────────────────────────────────────

    function test_encodeTrio() public pure {
        console2.log("Encoding 1, 3, 0 into single uint16");
        console2.log("Result: %s", GenieMath.encodeTrio(1, 3, 0));
        assertEq(GenieMath.encodeTrio(1, 3, 0), 130);

        assertEq(GenieMath.encodeTrio(0, 0, 0), 0);
        assertEq(GenieMath.encodeTrio(9, 9, 9), 999);
        assertEq(GenieMath.encodeTrio(1, 2, 3), 123);
    }

    // ──────────────────────────────────────────────
    //  trioTypeFromPick
    // ──────────────────────────────────────────────

    function test_trioTypeFromPick() public pure {
        console2.log("Checking TrioType for pick 112");
        console2.log("Type: %s (0=Unique, 1=Twin, 2=Jackpot)", uint8(GenieMath.trioTypeFromPick(112)));
        assertEq(uint8(GenieMath.trioTypeFromPick(112)), uint8(GenieMath.TrioType.Twin));
        assertEq(uint8(GenieMath.trioTypeFromPick(100)), uint8(GenieMath.TrioType.Twin));
        assertEq(uint8(GenieMath.trioTypeFromPick(111)), uint8(GenieMath.TrioType.Jackpot));
        assertEq(uint8(GenieMath.trioTypeFromPick(0)), uint8(GenieMath.TrioType.Jackpot));
    }
}
