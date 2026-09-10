// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {GenieMath} from "./GenieMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

/// @title GenieMarkets
/// @notice Onchain daily number prediction protocol with Chainlink VRF randomness.
/// @dev House-funded model. USDC denomination. Pull-based claims with 30-day expiry.
///      Round lifecycle: OpenBetting → OpenPending → CloseBetting → ClosePending → Settled.
///      Emergency paths: Cancelled (stale Open VRF) or PartiallySettled (stale Close VRF).
contract GenieMarkets is VRFConsumerBaseV2Plus, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────
    //  Constants
    // ──────────────────────────────────────────────

    uint16 public constant SINGLE_PAYOUT = 9;
    uint16 public constant PAIR_PAYOUT = 90;
    uint16 public constant UNIQUE_TRIO_PAYOUT = 140;
    uint16 public constant TWIN_TRIO_PAYOUT = 280;
    uint16 public constant JACKPOT_TRIO_PAYOUT = 600;

    uint32 public constant CLAIM_PERIOD = 30 days;
    uint32 public constant EMERGENCY_TIMEOUT = 24 hours;

    uint16 private constant VRF_REQUEST_CONFIRMATIONS = 3;
    uint32 private constant VRF_NUM_WORDS = 1;

    // ──────────────────────────────────────────────
    //  Immutables
    // ──────────────────────────────────────────────

    IERC20 public immutable i_usdc;
    uint256 public immutable i_subscriptionId;
    bytes32 public immutable i_keyHash;
    uint32 public immutable i_callbackGasLimit;

    // ──────────────────────────────────────────────
    //  Enums & Structs
    // ──────────────────────────────────────────────

    enum RoundPhase {
        OpenBetting,
        OpenPending,
        CloseBetting,
        ClosePending,
        Settled,
        PartiallySettled, // Open settled, Close cancelled (stale Close VRF)
        Cancelled // Entire round cancelled (stale Open VRF)
    }

    enum BetType {
        OpenSingle,
        CloseSingle,
        OpenTrio,
        CloseTrio,
        Pair
    }

    struct Round {
        RoundPhase phase;
        uint40 openCutoff;
        uint40 closeCutoff;
        uint40 settledAt;
        uint256 openVrfRequestId;
        uint256 closeVrfRequestId;
        // Winning digits (Genie-sorted)
        uint8 openD1;
        uint8 openD2;
        uint8 openD3;
        uint8 closeD1;
        uint8 closeD2;
        uint8 closeD3;
        uint8 openSingle;
        uint8 closeSingle;
        uint8 pairResult;
    }

    struct Bet {
        address player;
        BetType betType;
        uint16 pick; // 0-9 Single, 0-99 Pair, 0-999 Trio (Genie-sorted encoding)
        uint128 amount; // USDC (6 decimals)
        bool claimed;
    }

    // ──────────────────────────────────────────────
    //  State
    // ──────────────────────────────────────────────

    uint256 public s_currentRoundId;
    uint32 public s_openDuration;
    uint32 public s_closeDuration;

    mapping(uint256 => Round) public s_rounds;
    mapping(uint256 => Bet[]) internal s_roundBets;
    mapping(uint256 => uint256) private s_vrfRequestToRound;
    mapping(uint256 => bool) private s_vrfRequestIsClose;

    // ──────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────

    event BetPlaced(
        uint256 indexed roundId, uint256 betIndex, address indexed player, BetType betType, uint16 pick, uint128 amount
    );
    event DrawRequested(uint256 indexed roundId, bool isClose, uint256 vrfRequestId);
    event DrawFulfilled(uint256 indexed roundId, bool isClose, uint8 d1, uint8 d2, uint8 d3, uint8 single);
    event RoundSettled(uint256 indexed roundId, uint8 pairResult);
    event RoundPartiallySettled(uint256 indexed roundId);
    event RoundCancelled(uint256 indexed roundId);
    event WinningsClaimed(uint256 indexed roundId, uint256 betIndex, address indexed player, uint256 payout);
    event RefundClaimed(uint256 indexed roundId, uint256 betIndex, address indexed player, uint256 amount);
    event BankrollDeposited(address indexed depositor, uint256 amount);
    event BankrollWithdrawn(address indexed owner, uint256 amount);
    event DurationsUpdated(uint32 openDuration, uint32 closeDuration);
    event RoundInitialized(uint256 indexed roundId, uint40 openCutoff, uint40 closeCutoff);

    // ──────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────

    error WrongPhase(RoundPhase current, RoundPhase expected);
    error PastCutoff();
    error CutoffNotReached();
    error InvalidPick();
    error TrioNotSorted();
    error ZeroAmount();
    error NotYourBet();
    error AlreadyClaimed();
    error NotAWinner();
    error ClaimExpired();
    error NotStaleYet();
    error RoundNotPending();
    error OnlyCloseSideRefundable();
    error OnlyOpenSideClaimable();
    error RoundNotCancelledOrPartial();
    error RoundNotSettledOrPartial();

    // ──────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────

    constructor(
        address vrfCoordinator,
        uint256 subscriptionId,
        bytes32 keyHash,
        uint32 callbackGasLimit,
        address usdc,
        uint32 _openDuration,
        uint32 _closeDuration
    ) VRFConsumerBaseV2Plus(vrfCoordinator) {
        i_subscriptionId = subscriptionId;
        i_keyHash = keyHash;
        i_callbackGasLimit = callbackGasLimit;
        i_usdc = IERC20(usdc);
        s_openDuration = _openDuration;
        s_closeDuration = _closeDuration;

        // Initialize first round
        s_currentRoundId = 1;
        Round storage round = s_rounds[1];
        round.phase = RoundPhase.OpenBetting;
        round.openCutoff = uint40(block.timestamp + _openDuration);
        round.closeCutoff = uint40(block.timestamp + _openDuration + _closeDuration);

        emit RoundInitialized(1, round.openCutoff, round.closeCutoff);
    }

    // ──────────────────────────────────────────────
    //  Betting
    // ──────────────────────────────────────────────

    /// @notice Place a bet on the specified round, bet type, and pick.
    /// @param roundId The round to bet on (must be current and in correct phase).
    /// @param betType Which market to bet on.
    /// @param pick The predicted number (range depends on betType).
    /// @param wagerAmount USDC amount to wager (6 decimals). Caller must have approved this contract.
    function placeBet(uint256 roundId, BetType betType, uint16 pick, uint128 wagerAmount) external nonReentrant {
        if (wagerAmount == 0) revert ZeroAmount();

        Round storage round = s_rounds[roundId];

        // Phase + cutoff validation
        if (betType == BetType.OpenSingle || betType == BetType.OpenTrio || betType == BetType.Pair) {
            if (round.phase != RoundPhase.OpenBetting) {
                revert WrongPhase(round.phase, RoundPhase.OpenBetting);
            }
            if (block.timestamp >= round.openCutoff) revert PastCutoff();
        } else {
            if (
                round.phase != RoundPhase.OpenBetting && round.phase != RoundPhase.OpenPending
                    && round.phase != RoundPhase.CloseBetting
            ) {
                revert WrongPhase(round.phase, RoundPhase.CloseBetting);
            }
            if (block.timestamp >= round.closeCutoff) revert PastCutoff();
        }

        // Pick validation
        if (betType == BetType.OpenSingle || betType == BetType.CloseSingle) {
            if (pick > 9) revert InvalidPick();
        } else if (betType == BetType.Pair) {
            if (pick > 99) revert InvalidPick();
        } else {
            // Trio
            if (pick > 999) revert InvalidPick();
            if (!GenieMath.isValidTrio(pick)) revert TrioNotSorted();
        }

        // Transfer USDC from player
        i_usdc.safeTransferFrom(msg.sender, address(this), wagerAmount);

        // Store bet
        uint256 betIndex = s_roundBets[roundId].length;
        s_roundBets[roundId].push(
            Bet({player: msg.sender, betType: betType, pick: pick, amount: wagerAmount, claimed: false})
        );

        emit BetPlaced(roundId, betIndex, msg.sender, betType, pick, wagerAmount);
    }

    // ──────────────────────────────────────────────
    //  Draw Requests (permissionless)
    // ──────────────────────────────────────────────

    /// @notice Request the Open draw. Callable by anyone once the open cutoff has elapsed.
    function requestOpenDraw(uint256 roundId) external {
        Round storage round = s_rounds[roundId];
        if (round.phase != RoundPhase.OpenBetting) {
            revert WrongPhase(round.phase, RoundPhase.OpenBetting);
        }
        if (block.timestamp < round.openCutoff) revert CutoffNotReached();

        round.phase = RoundPhase.OpenPending;

        uint256 requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: i_keyHash,
                subId: i_subscriptionId,
                requestConfirmations: VRF_REQUEST_CONFIRMATIONS,
                callbackGasLimit: i_callbackGasLimit,
                numWords: VRF_NUM_WORDS,
                extraArgs: VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: false}))
            })
        );

        round.openVrfRequestId = requestId;
        s_vrfRequestToRound[requestId] = roundId;
        s_vrfRequestIsClose[requestId] = false;

        emit DrawRequested(roundId, false, requestId);
    }

    /// @notice Request the Close draw. Callable by anyone once the close cutoff has elapsed.
    function requestCloseDraw(uint256 roundId) external {
        Round storage round = s_rounds[roundId];
        if (round.phase != RoundPhase.CloseBetting) {
            revert WrongPhase(round.phase, RoundPhase.CloseBetting);
        }
        if (block.timestamp < round.closeCutoff) revert CutoffNotReached();

        round.phase = RoundPhase.ClosePending;

        uint256 requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: i_keyHash,
                subId: i_subscriptionId,
                requestConfirmations: VRF_REQUEST_CONFIRMATIONS,
                callbackGasLimit: i_callbackGasLimit,
                numWords: VRF_NUM_WORDS,
                extraArgs: VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: false}))
            })
        );

        round.closeVrfRequestId = requestId;
        s_vrfRequestToRound[requestId] = roundId;
        s_vrfRequestIsClose[requestId] = true;

        emit DrawRequested(roundId, true, requestId);
    }

    // ──────────────────────────────────────────────
    //  VRF Callback
    // ──────────────────────────────────────────────

    /// @dev Called by VRF coordinator. O(1) — never iterates bets.
    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) internal override {
        uint256 roundId = s_vrfRequestToRound[requestId];
        bool isClose = s_vrfRequestIsClose[requestId];
        Round storage round = s_rounds[roundId];

        (uint8 d1, uint8 d2, uint8 d3) = GenieMath.sortTrio(randomWords[0]);
        uint8 single = GenieMath.deriveSingle(d1, d2, d3);

        if (!isClose) {
            // Silently ignore if round was already cancelled (stale VRF arrived late)
            if (round.phase != RoundPhase.OpenPending) return;

            round.openD1 = d1;
            round.openD2 = d2;
            round.openD3 = d3;
            round.openSingle = single;
            round.phase = RoundPhase.CloseBetting;

            emit DrawFulfilled(roundId, false, d1, d2, d3, single);
        } else {
            // Silently ignore if round was already partially settled (stale VRF arrived late)
            if (round.phase != RoundPhase.ClosePending) return;

            round.closeD1 = d1;
            round.closeD2 = d2;
            round.closeD3 = d3;
            round.closeSingle = single;
            round.pairResult = GenieMath.derivePair(round.openSingle, single);
            round.phase = RoundPhase.Settled;
            round.settledAt = uint40(block.timestamp);

            emit DrawFulfilled(roundId, true, d1, d2, d3, single);
            emit RoundSettled(roundId, round.pairResult);

            _initNextRound();
        }
    }

    // ──────────────────────────────────────────────
    //  Claims
    // ──────────────────────────────────────────────

    /// @notice Claim winnings for a specific bet. Pull-based — winners must call this.
    /// @param roundId The settled round.
    /// @param betIndex Index of the bet in the round's bet array.
    function claimWinnings(uint256 roundId, uint256 betIndex) external nonReentrant {
        Round storage round = s_rounds[roundId];
        if (round.phase != RoundPhase.Settled && round.phase != RoundPhase.PartiallySettled) {
            revert RoundNotSettledOrPartial();
        }
        if (block.timestamp > round.settledAt + CLAIM_PERIOD) {
            revert ClaimExpired();
        }

        Bet storage bet = s_roundBets[roundId][betIndex];
        if (bet.player != msg.sender) revert NotYourBet();
        if (bet.claimed) revert AlreadyClaimed();

        // In PartiallySettled, only open-side bets are claimable
        if (round.phase == RoundPhase.PartiallySettled) {
            if (bet.betType != BetType.OpenSingle && bet.betType != BetType.OpenTrio) {
                revert OnlyOpenSideClaimable();
            }
        }

        uint256 payout = _calculatePayout(round, bet);
        if (payout == 0) revert NotAWinner();

        bet.claimed = true;
        i_usdc.safeTransfer(msg.sender, payout);

        emit WinningsClaimed(roundId, betIndex, msg.sender, payout);
    }

    /// @notice Claim a refund for a bet in a cancelled or partially-settled round.
    function claimRefund(uint256 roundId, uint256 betIndex) external nonReentrant {
        Round storage round = s_rounds[roundId];
        if (round.phase != RoundPhase.Cancelled && round.phase != RoundPhase.PartiallySettled) {
            revert RoundNotCancelledOrPartial();
        }
        if (block.timestamp > round.settledAt + CLAIM_PERIOD) {
            revert ClaimExpired();
        }

        Bet storage bet = s_roundBets[roundId][betIndex];
        if (bet.player != msg.sender) revert NotYourBet();
        if (bet.claimed) revert AlreadyClaimed();

        // In PartiallySettled, only close-side + Pair bets are refundable
        if (round.phase == RoundPhase.PartiallySettled) {
            if (bet.betType != BetType.CloseSingle && bet.betType != BetType.CloseTrio && bet.betType != BetType.Pair) {
                revert OnlyCloseSideRefundable();
            }
        }

        bet.claimed = true;
        i_usdc.safeTransfer(msg.sender, bet.amount);

        emit RefundClaimed(roundId, betIndex, msg.sender, bet.amount);
    }

    // ──────────────────────────────────────────────
    //  Emergency: Stale VRF Recovery
    // ──────────────────────────────────────────────

    /// @notice Cancel a round stuck in a pending VRF state. Callable by anyone after 24h timeout.
    /// @dev If Open VRF stale → full cancel. If Close VRF stale → partial settle (Open winners paid, Close refunded).
    function cancelStaleRound(uint256 roundId) external {
        Round storage round = s_rounds[roundId];

        if (round.phase == RoundPhase.OpenPending) {
            if (block.timestamp <= round.openCutoff + EMERGENCY_TIMEOUT) {
                revert NotStaleYet();
            }
            round.phase = RoundPhase.Cancelled;
            round.settledAt = uint40(block.timestamp);
            emit RoundCancelled(roundId);
            _initNextRound();
        } else if (round.phase == RoundPhase.ClosePending) {
            if (block.timestamp <= round.closeCutoff + EMERGENCY_TIMEOUT) {
                revert NotStaleYet();
            }
            round.phase = RoundPhase.PartiallySettled;
            round.settledAt = uint40(block.timestamp);
            emit RoundPartiallySettled(roundId);
            _initNextRound();
        } else {
            revert RoundNotPending();
        }
    }

    // ──────────────────────────────────────────────
    //  Bankroll Management (Owner)
    // ──────────────────────────────────────────────

    /// @notice Deposit USDC into the contract bankroll. Owner must approve first.
    function depositBankroll(uint256 amount) external onlyOwner {
        if (amount == 0) revert ZeroAmount();
        i_usdc.safeTransferFrom(msg.sender, address(this), amount);
        emit BankrollDeposited(msg.sender, amount);
    }

    /// @notice Withdraw USDC from the contract bankroll.
    function withdrawBankroll(uint256 amount) external onlyOwner {
        if (amount == 0) revert ZeroAmount();
        i_usdc.safeTransfer(msg.sender, amount);
        emit BankrollWithdrawn(msg.sender, amount);
    }

    /// @notice Update global round durations. Only affects future rounds.
    function setDurations(uint32 _openDuration, uint32 _closeDuration) external onlyOwner {
        require(_openDuration > 0 && _closeDuration > 0, "Zero duration");
        s_openDuration = _openDuration;
        s_closeDuration = _closeDuration;
        emit DurationsUpdated(_openDuration, _closeDuration);
    }

    // ──────────────────────────────────────────────
    //  View Helpers
    // ──────────────────────────────────────────────

    /// @notice Get the number of bets placed in a round.
    function getRoundBetCount(uint256 roundId) external view returns (uint256) {
        return s_roundBets[roundId].length;
    }

    /// @notice Get a specific bet's details.
    function getBet(uint256 roundId, uint256 betIndex)
        external
        view
        returns (address player, BetType betType, uint16 pick, uint128 amount, bool claimed)
    {
        Bet storage b = s_roundBets[roundId][betIndex];
        return (b.player, b.betType, b.pick, b.amount, b.claimed);
    }

    /// @notice Check if a bet is a winner and return the payout amount (0 if loser).
    function checkPayout(uint256 roundId, uint256 betIndex) external view returns (uint256) {
        Round storage round = s_rounds[roundId];
        if (round.phase != RoundPhase.Settled && round.phase != RoundPhase.PartiallySettled) return 0;
        Bet storage bet = s_roundBets[roundId][betIndex];
        if (round.phase == RoundPhase.PartiallySettled) {
            if (bet.betType != BetType.OpenSingle && bet.betType != BetType.OpenTrio) return 0;
        }
        return _calculatePayout(round, bet);
    }

    // ──────────────────────────────────────────────
    //  Internal
    // ──────────────────────────────────────────────

    function _initNextRound() private {
        uint256 nextId = ++s_currentRoundId;
        Round storage round = s_rounds[nextId];
        round.phase = RoundPhase.OpenBetting;
        round.openCutoff = uint40(block.timestamp + s_openDuration);
        round.closeCutoff = uint40(block.timestamp + s_openDuration + s_closeDuration);

        emit RoundInitialized(nextId, round.openCutoff, round.closeCutoff);
    }

    function _calculatePayout(Round storage round, Bet storage bet) private view returns (uint256) {
        uint256 wagerAmount = uint256(bet.amount);

        if (bet.betType == BetType.OpenSingle) {
            return bet.pick == round.openSingle ? wagerAmount * SINGLE_PAYOUT : 0;
        }
        if (bet.betType == BetType.CloseSingle) {
            return bet.pick == round.closeSingle ? wagerAmount * SINGLE_PAYOUT : 0;
        }
        if (bet.betType == BetType.Pair) {
            return bet.pick == round.pairResult ? wagerAmount * PAIR_PAYOUT : 0;
        }

        // Trio bets
        uint16 winningTrio;
        if (bet.betType == BetType.OpenTrio) {
            winningTrio = GenieMath.encodeTrio(round.openD1, round.openD2, round.openD3);
        } else {
            // CloseTrio
            winningTrio = GenieMath.encodeTrio(round.closeD1, round.closeD2, round.closeD3);
        }

        if (bet.pick != winningTrio) return 0;

        // Trio matched — payout depends on trio type
        GenieMath.TrioType trioType = GenieMath.trioTypeFromPick(bet.pick);
        if (trioType == GenieMath.TrioType.Jackpot) {
            return wagerAmount * JACKPOT_TRIO_PAYOUT;
        }
        if (trioType == GenieMath.TrioType.Twin) {
            return wagerAmount * TWIN_TRIO_PAYOUT;
        }
        return wagerAmount * UNIQUE_TRIO_PAYOUT;
    }
}
