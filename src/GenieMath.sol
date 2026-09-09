// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title GenieMath
/// @notice Pure derivation math for Genie Markets number prediction protocol.
/// @dev Genie digit ordering: 1 < 2 < 3 < 4 < 5 < 6 < 7 < 8 < 9 < 0
///      Zero is the HIGHEST digit, not the lowest.
library GenieMath {
    enum TrioType {
        Unique, // 3 distinct digits — 120 combos — 140x payout
        Twin, //   2 identical digits — 90 combos  — 280x payout
        Jackpot // 3 identical digits — 10 combos  — 600x payout
    }

    // ──────────────────────────────────────────────
    //  Internal helpers
    // ──────────────────────────────────────────────

    /// @dev Maps a digit to its Genie-order rank for comparison.
    ///      0 → 10 (highest), 1-9 → 1-9.
    function _rank(uint8 d) private pure returns (uint8) {
        return d == 0 ? 10 : d;
    }

    // ──────────────────────────────────────────────
    //  Core derivation functions
    // ──────────────────────────────────────────────

    /// @notice Extract 3 digits from a raw VRF number and sort them in Genie order.
    /// @param raw The random word from VRF. Only `raw % 1000` is used.
    /// @return d1 d2 d3 Digits sorted so _rank(d1) <= _rank(d2) <= _rank(d3).
    function sortTrio(uint256 raw) internal pure returns (uint8 d1, uint8 d2, uint8 d3) {
        uint256 n = raw % 1000;
        d1 = uint8(n / 100);
        d2 = uint8((n / 10) % 10);
        d3 = uint8(n % 10);

        // 3-element sorting network (Genie rank comparison)
        if (_rank(d1) > _rank(d2)) (d1, d2) = (d2, d1);
        if (_rank(d2) > _rank(d3)) (d2, d3) = (d3, d2);
        if (_rank(d1) > _rank(d2)) (d1, d2) = (d2, d1);
    }

    /// @notice Classify a trio as Unique, Twin, or Jackpot.
    /// @dev Expects digits already sorted in Genie order. After sorting,
    ///      d1==d3 implies d1==d2==d3 (Jackpot), so Twin only needs d1==d2 || d2==d3.
    function trioType(uint8 d1, uint8 d2, uint8 d3) internal pure returns (TrioType) {
        if (d1 == d2 && d2 == d3) return TrioType.Jackpot;
        if (d1 == d2 || d2 == d3) return TrioType.Twin;
        return TrioType.Unique;
    }

    /// @notice Derive Single digit from trio: (d1 + d2 + d3) mod 10.
    /// @dev Uses standard arithmetic (not Genie ordering).
    function deriveSingle(uint8 d1, uint8 d2, uint8 d3) internal pure returns (uint8) {
        return uint8((uint16(d1) + d2 + d3) % 10);
    }

    /// @notice Derive Pair from Open Single and Close Single.
    function derivePair(uint8 openSingle, uint8 closeSingle) internal pure returns (uint8) {
        return openSingle * 10 + closeSingle;
    }

    /// @notice Encode sorted trio digits into canonical uint16: d1*100 + d2*10 + d3.
    function encodeTrio(uint8 d1, uint8 d2, uint8 d3) internal pure returns (uint16) {
        return uint16(d1) * 100 + uint16(d2) * 10 + d3;
    }

    // ──────────────────────────────────────────────
    //  Validation
    // ──────────────────────────────────────────────

    /// @notice Check that a trio pick's digits are in valid Genie-sorted order.
    /// @param pick Encoded trio (d1*100 + d2*10 + d3), must be <= 999.
    function isValidTrio(uint16 pick) internal pure returns (bool) {
        uint8 a = uint8(pick / 100);
        uint8 b = uint8((pick / 10) % 10);
        uint8 c = uint8(pick % 10);
        return _rank(a) <= _rank(b) && _rank(b) <= _rank(c);
    }

    /// @notice Get the TrioType of an encoded trio pick.
    function trioTypeFromPick(uint16 pick) internal pure returns (TrioType) {
        uint8 a = uint8(pick / 100);
        uint8 b = uint8((pick / 10) % 10);
        uint8 c = uint8(pick % 10);
        return trioType(a, b, c);
    }
}
