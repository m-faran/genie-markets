// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {GenieMarkets} from "../src/GenieMarkets.sol";
import {GenieMath} from "../src/GenieMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

// ──────────────────────────────────────────────
//  Mocks
// ──────────────────────────────────────────────

/// @dev Minimal mock USDC (6 decimals).
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Minimal mock VRF coordinator that accepts requests and lets tests trigger fulfillment.
contract MockVRFCoordinator {
    uint256 private _requestId;

    function requestRandomWords(VRFV2PlusClient.RandomWordsRequest calldata) external returns (uint256) {
        return ++_requestId;
    }

    /// @dev Simulate VRF fulfillment by calling rawFulfillRandomWords on the consumer.
    function fulfillRandomWords(uint256 requestId, address consumer, uint256 rawNumber) external {
        uint256[] memory words = new uint256[](1);
        words[0] = rawNumber;
        // Call rawFulfillRandomWords — it checks msg.sender == coordinator
        (bool ok,) =
            consumer.call(abi.encodeWithSignature("rawFulfillRandomWords(uint256,uint256[])", requestId, words));
        require(ok, "VRF fulfillment failed");
    }

    function lastRequestId() external view returns (uint256) {
        return _requestId;
    }
}

// ──────────────────────────────────────────────
//  Test Contract
// ──────────────────────────────────────────────

contract GenieMarketsTest is Test {
    GenieMarkets public markets;
    MockUSDC public usdc;
    MockVRFCoordinator public vrfCoordinator;

    address public owner = makeAddr("owner");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    uint32 constant OPEN_DURATION = 21 hours;
    uint32 constant CLOSE_DURATION = 3 hours;
    uint256 constant BET_AMOUNT = 10e6; // 10 USDC
    uint256 constant BANKROLL = 1_000_000e6; // 1M USDC

    function setUp() public {
        vm.startPrank(owner);

        usdc = new MockUSDC();
        vrfCoordinator = new MockVRFCoordinator();

        markets = new GenieMarkets(
            address(vrfCoordinator),
            1, // subscriptionId
            bytes32(0), // keyHash
            500_000, // callbackGasLimit
            address(usdc),
            OPEN_DURATION,
            CLOSE_DURATION
        );

        // Fund bankroll
        usdc.mint(owner, BANKROLL);
        usdc.approve(address(markets), BANKROLL);
        markets.depositBankroll(BANKROLL);

        vm.stopPrank();

        // Give players USDC
        usdc.mint(alice, 100_000e6);
        usdc.mint(bob, 100_000e6);

        vm.prank(alice);
        usdc.approve(address(markets), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(markets), type(uint256).max);
    }

    // ──────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────

    function _placeBet(address player, uint256 roundId, GenieMarkets.BetType betType, uint16 pick, uint128 wagerAmount)
        internal
    {
        vm.prank(player);
        markets.placeBet(roundId, betType, pick, wagerAmount);
    }

    function _advancePastOpenCutoff() internal {
        (, uint40 openCutoff,,,,,,,,,,,,,) = markets.s_rounds(markets.s_currentRoundId());
        vm.warp(openCutoff);
    }

    function _advancePastCloseCutoff() internal {
        (,, uint40 closeCutoff,,,,,,,,,,,,) = markets.s_rounds(markets.s_currentRoundId());
        vm.warp(closeCutoff);
    }

    function _requestAndFulfillOpenDraw(uint256 roundId, uint256 rawNumber) internal {
        markets.requestOpenDraw(roundId);
        uint256 reqId = vrfCoordinator.lastRequestId();
        vrfCoordinator.fulfillRandomWords(reqId, address(markets), rawNumber);
    }

    function _requestAndFulfillCloseDraw(uint256 roundId, uint256 rawNumber) internal {
        markets.requestCloseDraw(roundId);
        uint256 reqId = vrfCoordinator.lastRequestId();
        vrfCoordinator.fulfillRandomWords(reqId, address(markets), rawNumber);
    }

    // ──────────────────────────────────────────────
    //  Full Lifecycle
    // ──────────────────────────────────────────────

    function test_fullRoundLifecycle() public {
        uint256 roundId = markets.s_currentRoundId();
        assertEq(roundId, 1);

        // Phase: OpenBetting — place Open Single bet on digit 6
        // VRF raw = 123 → sorted 123 → single = (1+2+3)%10 = 6
        _placeBet(alice, roundId, GenieMarkets.BetType.OpenSingle, 6, uint128(BET_AMOUNT));
        // Place a Pair bet: openSingle=6, let's guess closeSingle will be 4 → pair = 64
        _placeBet(bob, roundId, GenieMarkets.BetType.Pair, 64, uint128(BET_AMOUNT));

        assertEq(markets.getRoundBetCount(roundId), 2);

        // Advance past open cutoff and trigger open draw
        _advancePastOpenCutoff();
        _requestAndFulfillOpenDraw(roundId, 123); // → trio 123, single 6

        // Phase should now be CloseBetting
        (GenieMarkets.RoundPhase phase,,,,,,,,,,,,,,) = markets.s_rounds(roundId);
        assertEq(uint8(phase), uint8(GenieMarkets.RoundPhase.CloseBetting));

        // Place Close Single bet: VRF raw = 456 → sorted 456 → single = (4+5+6)%10 = 5
        _placeBet(alice, roundId, GenieMarkets.BetType.CloseSingle, 5, uint128(BET_AMOUNT));

        // Advance past close cutoff and trigger close draw
        _advancePastCloseCutoff();
        _requestAndFulfillCloseDraw(roundId, 456); // → trio 456, single 5, pair = 65

        // Round should be Settled
        (phase,,,,,,,,,,,,,,) = markets.s_rounds(roundId);
        assertEq(uint8(phase), uint8(GenieMarkets.RoundPhase.Settled));

        // Alice's Open Single bet on 6 should win (9x)
        uint256 payout = markets.checkPayout(roundId, 0);
        assertEq(payout, BET_AMOUNT * 9);

        // Bob's Pair bet on 64 should lose (pair result is 65)
        assertEq(markets.checkPayout(roundId, 1), 0);

        // Alice's Close Single bet on 5 should win (9x)
        assertEq(markets.checkPayout(roundId, 2), BET_AMOUNT * 9);

        // Claim winnings
        uint256 aliceBalBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        markets.claimWinnings(roundId, 0);
        vm.prank(alice);
        markets.claimWinnings(roundId, 2);
        assertEq(usdc.balanceOf(alice), aliceBalBefore + BET_AMOUNT * 9 * 2);

        // Next round should be initialized
        assertEq(markets.s_currentRoundId(), 2);
    }

    // ──────────────────────────────────────────────
    //  Trio Bets
    // ──────────────────────────────────────────────

    function test_trioBet_uniqueWin() public {
        uint256 roundId = 1;
        // Bet on trio 123 (Unique). VRF raw = 213 → sorted = 123.
        _placeBet(alice, roundId, GenieMarkets.BetType.OpenTrio, 123, uint128(BET_AMOUNT));

        _advancePastOpenCutoff();
        _requestAndFulfillOpenDraw(roundId, 213);

        // Open trio is 123 → alice wins 140x
        assertEq(markets.checkPayout(roundId, 0), BET_AMOUNT * 140);
    }

    function test_trioBet_twinWin() public {
        uint256 roundId = 1;
        // Bet on trio 112 (Twin). VRF raw = 211 → sorted = 112.
        _placeBet(alice, roundId, GenieMarkets.BetType.OpenTrio, 112, uint128(BET_AMOUNT));

        _advancePastOpenCutoff();
        _requestAndFulfillOpenDraw(roundId, 211);

        assertEq(markets.checkPayout(roundId, 0), BET_AMOUNT * 280);
    }

    function test_trioBet_jackpotWin() public {
        uint256 roundId = 1;
        // Bet on trio 555 (Jackpot). VRF raw = 555.
        _placeBet(alice, roundId, GenieMarkets.BetType.OpenTrio, 555, uint128(BET_AMOUNT));

        _advancePastOpenCutoff();
        _requestAndFulfillOpenDraw(roundId, 555);

        assertEq(markets.checkPayout(roundId, 0), BET_AMOUNT * 600);
    }

    function test_trioBet_genieSort_withZero() public {
        uint256 roundId = 1;
        // Bet on trio 130 (Genie sorted: rank 1<3<10). VRF raw = 310 → sorted = 130.
        _placeBet(alice, roundId, GenieMarkets.BetType.OpenTrio, 130, uint128(BET_AMOUNT));

        _advancePastOpenCutoff();
        _requestAndFulfillOpenDraw(roundId, 310);

        // Should win — 310 sorts to 130
        assertEq(markets.checkPayout(roundId, 0), BET_AMOUNT * 140);
    }

    // ──────────────────────────────────────────────
    //  Phase Enforcement
    // ──────────────────────────────────────────────

    function test_revert_requestOpenDrawBeforeCutoff() public {
        uint256 roundId = 1;
        vm.expectRevert(GenieMarkets.CutoffNotReached.selector);
        markets.requestOpenDraw(roundId);
    }

    function test_revert_requestCloseDrawBeforeCutoff() public {
        uint256 roundId = 1;
        _advancePastOpenCutoff();
        _requestAndFulfillOpenDraw(roundId, 123);

        vm.expectRevert(GenieMarkets.CutoffNotReached.selector);
        markets.requestCloseDraw(roundId);
    }

    function test_revert_openBetDuringCloseBetting() public {
        uint256 roundId = 1;
        _advancePastOpenCutoff();
        _requestAndFulfillOpenDraw(roundId, 123);

        // Now in CloseBetting — OpenSingle should revert
        vm.expectRevert();
        _placeBet(alice, roundId, GenieMarkets.BetType.OpenSingle, 5, uint128(BET_AMOUNT));
    }

    function test_revert_pairBetDuringCloseBetting() public {
        uint256 roundId = 1;
        _advancePastOpenCutoff();
        _requestAndFulfillOpenDraw(roundId, 123);

        // Pair should revert during CloseBetting
        vm.expectRevert();
        _placeBet(alice, roundId, GenieMarkets.BetType.Pair, 55, uint128(BET_AMOUNT));
    }

    function test_revert_closeBetDuringOpenBetting() public {
        uint256 roundId = 1;

        vm.expectRevert();
        _placeBet(alice, roundId, GenieMarkets.BetType.CloseSingle, 5, uint128(BET_AMOUNT));
    }

    function test_revert_betAfterOpenCutoff() public {
        uint256 roundId = 1;
        _advancePastOpenCutoff();

        vm.expectRevert(GenieMarkets.PastCutoff.selector);
        _placeBet(alice, roundId, GenieMarkets.BetType.OpenSingle, 5, uint128(BET_AMOUNT));
    }

    function test_revert_betDuringPendingPhase() public {
        uint256 roundId = 1;
        _advancePastOpenCutoff();
        markets.requestOpenDraw(roundId);
        // Now in OpenPending — cannot bet
        vm.expectRevert();
        _placeBet(alice, roundId, GenieMarkets.BetType.OpenSingle, 5, uint128(BET_AMOUNT));
    }

    // ──────────────────────────────────────────────
    //  Claim Edge Cases
    // ──────────────────────────────────────────────

    function test_revert_claimAsLoser() public {
        uint256 roundId = 1;
        _placeBet(alice, roundId, GenieMarkets.BetType.OpenSingle, 5, uint128(BET_AMOUNT));

        _advancePastOpenCutoff();
        _requestAndFulfillOpenDraw(roundId, 123); // single = 6, not 5

        _advancePastCloseCutoff();
        _requestAndFulfillCloseDraw(roundId, 456);

        vm.prank(alice);
        vm.expectRevert(GenieMarkets.NotAWinner.selector);
        markets.claimWinnings(roundId, 0);
    }

    function test_revert_doubleClaim() public {
        uint256 roundId = 1;
        _placeBet(alice, roundId, GenieMarkets.BetType.OpenSingle, 6, uint128(BET_AMOUNT));

        _advancePastOpenCutoff();
        _requestAndFulfillOpenDraw(roundId, 123);
        _advancePastCloseCutoff();
        _requestAndFulfillCloseDraw(roundId, 456);

        vm.prank(alice);
        markets.claimWinnings(roundId, 0);

        vm.prank(alice);
        vm.expectRevert(GenieMarkets.AlreadyClaimed.selector);
        markets.claimWinnings(roundId, 0);
    }

    function test_revert_claimByWrongPlayer() public {
        uint256 roundId = 1;
        _placeBet(alice, roundId, GenieMarkets.BetType.OpenSingle, 6, uint128(BET_AMOUNT));

        _advancePastOpenCutoff();
        _requestAndFulfillOpenDraw(roundId, 123);
        _advancePastCloseCutoff();
        _requestAndFulfillCloseDraw(roundId, 456);

        vm.prank(bob);
        vm.expectRevert(GenieMarkets.NotYourBet.selector);
        markets.claimWinnings(roundId, 0);
    }

    function test_revert_claimExpired() public {
        uint256 roundId = 1;
        _placeBet(alice, roundId, GenieMarkets.BetType.OpenSingle, 6, uint128(BET_AMOUNT));

        _advancePastOpenCutoff();
        _requestAndFulfillOpenDraw(roundId, 123);
        _advancePastCloseCutoff();
        _requestAndFulfillCloseDraw(roundId, 456);

        // Advance past 30-day claim period
        vm.warp(block.timestamp + 31 days);

        vm.prank(alice);
        vm.expectRevert(GenieMarkets.ClaimExpired.selector);
        markets.claimWinnings(roundId, 0);
    }

    // ──────────────────────────────────────────────
    //  Emergency Cancel — Full Cancel (Stale Open VRF)
    // ──────────────────────────────────────────────

    function test_fullCancel_staleOpenVRF() public {
        uint256 roundId = 1;
        _placeBet(alice, roundId, GenieMarkets.BetType.OpenSingle, 5, uint128(BET_AMOUNT));
        _placeBet(bob, roundId, GenieMarkets.BetType.Pair, 55, uint128(BET_AMOUNT));

        _advancePastOpenCutoff();
        markets.requestOpenDraw(roundId);
        // VRF never responds...

        // Advance past emergency timeout (24h after openCutoff)
        (, uint40 openCutoff,,,,,,,,,,,,,) = markets.s_rounds(roundId);
        vm.warp(uint256(openCutoff) + 24 hours + 1);

        markets.cancelStaleRound(roundId);

        (GenieMarkets.RoundPhase phase,,,,,,,,,,,,,,) = markets.s_rounds(roundId);
        assertEq(uint8(phase), uint8(GenieMarkets.RoundPhase.Cancelled));

        // Both can claim refunds
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        markets.claimRefund(roundId, 0);
        assertEq(usdc.balanceOf(alice), aliceBefore + BET_AMOUNT);

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        markets.claimRefund(roundId, 1);
        assertEq(usdc.balanceOf(bob), bobBefore + BET_AMOUNT);

        // Next round initialized
        assertEq(markets.s_currentRoundId(), 2);
    }

    // ──────────────────────────────────────────────
    //  Emergency Cancel — Partial (Stale Close VRF)
    // ──────────────────────────────────────────────

    function test_partialCancel_staleCloseVRF() public {
        uint256 roundId = 1;

        // Open bets
        _placeBet(alice, roundId, GenieMarkets.BetType.OpenSingle, 6, uint128(BET_AMOUNT)); // will win
        _placeBet(alice, roundId, GenieMarkets.BetType.Pair, 64, uint128(BET_AMOUNT)); // pair — gets refunded

        _advancePastOpenCutoff();
        _requestAndFulfillOpenDraw(roundId, 123); // single = 6

        // Close bet
        _placeBet(bob, roundId, GenieMarkets.BetType.CloseSingle, 5, uint128(BET_AMOUNT));

        _advancePastCloseCutoff();
        markets.requestCloseDraw(roundId);
        // VRF never responds for close draw...

        (,, uint40 closeCutoff,,,,,,,,,,,,) = markets.s_rounds(roundId);
        vm.warp(uint256(closeCutoff) + 24 hours + 1);

        markets.cancelStaleRound(roundId);

        (GenieMarkets.RoundPhase phase,,,,,,,,,,,,,,) = markets.s_rounds(roundId);
        assertEq(uint8(phase), uint8(GenieMarkets.RoundPhase.PartiallySettled));

        // Alice's Open Single bet on 6 is a winner — can claim
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        markets.claimWinnings(roundId, 0);
        assertEq(usdc.balanceOf(alice), aliceBefore + BET_AMOUNT * 9);

        // Alice's Pair bet — refundable (close side)
        aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        markets.claimRefund(roundId, 1);
        assertEq(usdc.balanceOf(alice), aliceBefore + BET_AMOUNT);

        // Bob's Close Single bet — refundable
        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        markets.claimRefund(roundId, 2);
        assertEq(usdc.balanceOf(bob), bobBefore + BET_AMOUNT);
    }

    function test_revert_partialCancel_openBetNotRefundable() public {
        uint256 roundId = 1;
        _placeBet(alice, roundId, GenieMarkets.BetType.OpenSingle, 5, uint128(BET_AMOUNT)); // loser

        _advancePastOpenCutoff();
        _requestAndFulfillOpenDraw(roundId, 123); // single = 6

        _placeBet(bob, roundId, GenieMarkets.BetType.CloseSingle, 5, uint128(BET_AMOUNT));
        _advancePastCloseCutoff();
        markets.requestCloseDraw(roundId);

        (,, uint40 closeCutoff,,,,,,,,,,,,) = markets.s_rounds(roundId);
        vm.warp(uint256(closeCutoff) + 24 hours + 1);
        markets.cancelStaleRound(roundId);

        // Alice's Open Single bet (bet 0) is NOT refundable — it was settled (she lost)
        vm.prank(alice);
        vm.expectRevert(GenieMarkets.OnlyCloseSideRefundable.selector);
        markets.claimRefund(roundId, 0);
    }

    // ──────────────────────────────────────────────
    //  Input Validation
    // ──────────────────────────────────────────────

    function test_revert_zeroAmountBet() public {
        vm.prank(alice);
        vm.expectRevert(GenieMarkets.ZeroAmount.selector);
        markets.placeBet(1, GenieMarkets.BetType.OpenSingle, 5, 0);
    }

    function test_revert_invalidSinglePick() public {
        vm.expectRevert();
        _placeBet(alice, 1, GenieMarkets.BetType.OpenSingle, 10, uint128(BET_AMOUNT));
    }

    function test_revert_invalidPairPick() public {
        vm.expectRevert();
        _placeBet(alice, 1, GenieMarkets.BetType.Pair, 100, uint128(BET_AMOUNT));
    }

    function test_revert_unsortedTrioPick() public {
        // 321 is not Genie-sorted
        vm.expectRevert(GenieMarkets.TrioNotSorted.selector);
        _placeBet(alice, 1, GenieMarkets.BetType.OpenTrio, 321, uint128(BET_AMOUNT));
    }

    function test_revert_trioPick_013_notGenieSorted() public {
        // 013 → digits 0,1,3 → ranks 10,1,3 → NOT sorted
        vm.expectRevert(GenieMarkets.TrioNotSorted.selector);
        _placeBet(alice, 1, GenieMarkets.BetType.OpenTrio, 13, uint128(BET_AMOUNT));
    }

    // ──────────────────────────────────────────────
    //  Bankroll Management
    // ──────────────────────────────────────────────

    function test_revert_nonOwnerDeposit() public {
        vm.prank(alice);
        vm.expectRevert();
        markets.depositBankroll(100e6);
    }

    function test_revert_nonOwnerWithdraw() public {
        vm.prank(alice);
        vm.expectRevert();
        markets.withdrawBankroll(100e6);
    }

    function test_ownerWithdrawBankroll() public {
        uint256 ownerBefore = usdc.balanceOf(owner);
        vm.prank(owner);
        markets.withdrawBankroll(100e6);
        assertEq(usdc.balanceOf(owner), ownerBefore + 100e6);
    }

    // ──────────────────────────────────────────────
    //  Duration Configuration
    // ──────────────────────────────────────────────

    function test_setDurations() public {
        vm.prank(owner);
        markets.setDurations(12 hours, 12 hours);
        assertEq(markets.s_openDuration(), 12 hours);
        assertEq(markets.s_closeDuration(), 12 hours);
    }

    function test_revert_nonOwnerSetDurations() public {
        vm.prank(alice);
        vm.expectRevert();
        markets.setDurations(12 hours, 12 hours);
    }

    // ──────────────────────────────────────────────
    //  Stale VRF arrives late (should be no-op)
    // ──────────────────────────────────────────────

    function test_lateVRF_afterCancel_isNoOp() public {
        uint256 roundId = 1;
        _placeBet(alice, roundId, GenieMarkets.BetType.OpenSingle, 5, uint128(BET_AMOUNT));

        _advancePastOpenCutoff();
        markets.requestOpenDraw(roundId);
        uint256 reqId = vrfCoordinator.lastRequestId();

        // Cancel before VRF arrives
        (, uint40 openCutoff,,,,,,,,,,,,,) = markets.s_rounds(roundId);
        vm.warp(uint256(openCutoff) + 24 hours + 1);
        markets.cancelStaleRound(roundId);

        // Now VRF arrives late — should be silently ignored
        vrfCoordinator.fulfillRandomWords(reqId, address(markets), 123);

        // Round should still be Cancelled
        (GenieMarkets.RoundPhase phase,,,,,,,,,,,,,,) = markets.s_rounds(roundId);
        assertEq(uint8(phase), uint8(GenieMarkets.RoundPhase.Cancelled));
    }

    // ──────────────────────────────────────────────
    //  Multi-round continuity
    // ──────────────────────────────────────────────

    function test_multiRound_continuity() public {
        // Complete round 1
        uint256 r1 = 1;
        _placeBet(alice, r1, GenieMarkets.BetType.OpenSingle, 6, uint128(BET_AMOUNT));
        _advancePastOpenCutoff();
        _requestAndFulfillOpenDraw(r1, 123);
        _advancePastCloseCutoff();
        _requestAndFulfillCloseDraw(r1, 456);

        // Round 2 should be active
        uint256 r2 = markets.s_currentRoundId();
        assertEq(r2, 2);

        // Can place bets on round 2
        _placeBet(alice, r2, GenieMarkets.BetType.OpenSingle, 3, uint128(BET_AMOUNT));
        assertEq(markets.getRoundBetCount(r2), 1);
    }
}
