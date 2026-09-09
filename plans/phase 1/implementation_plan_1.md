# Genie Markets — Onchain Daily Number Prediction Protocol

A provably fair, pull-based daily number prediction game using Chainlink VRF for randomness. Three game modes (Single, Pair, Trio) with a 5-phase round state machine running in 24-hour cycles.

---

## User Review Required

> [!IMPORTANT]
> **Target chain is unspecified.** The contract uses Chainlink VRF v2.5. I'll code against the abstract VRF consumer interface so it deploys to any chain with VRF support (mainnet, Base, Arbitrum, Polygon, etc.). You'll supply the subscription ID, coordinator address, and key hash at deploy time. Is that acceptable, or do you want to hardcode a specific chain?

> [!IMPORTANT]
> **Bet denomination is unspecified.** Two options:
> 1. **Native ETH** — simpler, no approve flow, but harder to reason about payouts in USD terms.
> 2. **ERC-20 (e.g. USDC)** — cleaner accounting, explicit approve, SafeERC20.
>
> I'll default to **native ETH** unless you say otherwise. Switching later is a small diff.

> [!IMPORTANT]
> **Funding model is unspecified.** The contract needs liquidity to pay winners. Options:
> 1. **House-funded** — owner deposits a bankroll, contract pays from it. Simple. Owner takes the risk.
> 2. **Pool-funded** — LPs deposit into a pool, winners are paid from the pool, LPs share house edge. More complex.
>
> I'll default to **house-funded (owner bankroll)** for the MVP. The owner can deposit/withdraw the bankroll. The contract enforces a minimum bankroll to accept bets (so it can always cover max payout).

> [!WARNING]
> **Bet size limits.** Without a maximum bet, a single player could bet an amount whose payout (up to 600x for Jackpot Trio) exceeds the contract's bankroll. The contract **must** enforce `bet * maxPayout <= availableBankroll` at bet placement time. I'll implement this.

---

## Open Questions

> [!IMPORTANT]
> **1. Chainlink Automation vs. permissionless keeper.** The spec mentions "Chainlink Automation or permissionlessly by any user." I'll implement **permissionless-only** — anyone can call `requestOpenDraw()` / `requestCloseDraw()` once the cutoff elapses. This avoids an Automation dependency and is simpler. Chainlink Automation can be pointed at these functions later without any contract changes. OK?

> [!IMPORTANT]
> **2. Round timing configuration.** The spec gives examples (9 PM open cutoff, midnight close cutoff). Should these be:
> - **Immutable at deploy** (e.g. open duration = 21 hours, close duration = 3 hours)?
> - **Configurable by owner** per-round or globally?
>
> I'll default to **owner-configurable globally** (two `uint32` durations: `openDuration` and `closeDuration`). Each new round calculates its cutoffs from the settlement timestamp + durations.

> [!IMPORTANT]
> **3. Claim window.** The spec says claims are "permanently unlocked" once settled. That means no expiry on claims — winners can claim forever. This is simpler but means the contract must hold funds indefinitely. I'll implement it this way. If you want an expiry (e.g. 30 days, after which unclaimed funds return to bankroll), say so.

> [!IMPORTANT]
> **4. Maximum bet count per user per round.** Should there be a limit? Without one, a user could place thousands of small bets and the claim loop (even user-initiated) could be expensive. I'll track bets in an array per-round and let users claim by bet index — no loop needed. But do you want a cap anyway?

> [!IMPORTANT]  
> **5. Emergency cancel granularity.** The spec says if VRF fails, the round becomes `Cancelled` and players get refunds. Two sub-questions:
> - Who can trigger cancel? **Owner only**, or **anyone after the emergency timeout**?
> - If the Open draw succeeds but the Close draw fails, should we cancel just the Close portion (refunding Close bets but paying Open winners), or cancel the entire round?
>
> I'll default to: **anyone can cancel after 24h timeout**, and **the entire round is cancelled** (simplest — partial settlement adds significant complexity).

---

## Proposed Changes

### Core Contract

#### [NEW] [GenieMath.sol](file:///home/faran/foundry-projects/genie-markets/src/GenieMath.sol)

Pure library with the derivation math:
- `sortTrio(uint256 raw)` → extracts 3 digits from `raw % 1000`, sorts ascending, returns `(d1, d2, d3)`.
- `trioType(d1, d2, d3)` → returns `Unique | Twin | Jackpot`.
- `deriveSingle(d1, d2, d3)` → `(d1 + d2 + d3) % 10`.
- `derivePair(openSingle, closeSingle)` → `openSingle * 10 + closeSingle`.
- `encodeTrio(d1, d2, d3)` → `d1 * 100 + d2 * 10 + d3` (canonical sorted encoding for bet matching).

#### [NEW] [GenieMarkets.sol](file:///home/faran/foundry-projects/genie-markets/src/GenieMarkets.sol)

The main contract. Single file (no proxies — immutable is the value proposition for a betting protocol). Inherits Chainlink `VRFConsumerBaseV2Plus`.

**State:**
```
enum RoundPhase { OpenBetting, OpenPending, CloseBetting, ClosePending, Settled, Cancelled }
enum BetType { OpenSingle, CloseSingle, OpenTrio, CloseTrio, Pair }

struct Round {
    RoundPhase phase;
    uint40 openCutoff;
    uint40 closeCutoff;
    uint40 settledAt;
    uint256 openVrfRequestId;
    uint256 closeVrfRequestId;
    // Winning numbers (set after VRF)
    uint8 openD1; uint8 openD2; uint8 openD3;  // sorted trio digits
    uint8 closeD1; uint8 closeD2; uint8 closeD3;
    uint8 openSingle;
    uint8 closeSingle;
    uint8 pairResult;  // 0-99
    uint256 totalBetAmount;  // total ETH bet this round (for bankroll accounting)
    uint256 totalPotentialPayout; // worst-case payout exposure
}

struct Bet {
    address player;
    BetType betType;
    uint16 pick;        // 0-9 for Single, 0-99 for Pair, 0-999 for Trio (sorted encoding)
    uint128 amount;
    bool claimed;
}
```

**Key functions:**
- `placeBet(uint256 roundId, BetType betType, uint16 pick)` payable — validates phase, pick range, bet amount, exposure limit. Stores bet, updates exposure tracking.
- `requestOpenDraw(uint256 roundId)` — permissionless, requires `block.timestamp >= openCutoff && phase == OpenBetting`. Requests VRF, transitions to `OpenPending`.
- `requestCloseDraw(uint256 roundId)` — same pattern for close.
- `fulfillRandomWords(uint256 requestId, uint256[] memory randomWords)` — VRF callback. Derives numbers, transitions state. On close fulfillment: settles round, increments `currentRoundId`, initializes next round.
- `claimWinnings(uint256 roundId, uint256 betIndex)` — pull-based. Checks bet is a winner, marks claimed, transfers ETH.
- `claimRefund(uint256 roundId, uint256 betIndex)` — for `Cancelled` rounds.
- `cancelStaleRound(uint256 roundId)` — anyone, after 24h emergency timeout.
- `depositBankroll()` payable — owner adds funds.
- `withdrawBankroll(uint256 amount)` — owner removes excess funds (cannot withdraw below outstanding exposure).

**Payout multipliers (hardcoded constants):**
| Bet Type | Payout | RTP |
|----------|--------|-----|
| Single | 9x | 90% |
| Pair | 90x | 90% |
| Unique Trio | 140x | 84% |
| Twin Trio | 280x | 84% |
| Jackpot Trio | 600x | 60% |

**Exposure tracking:** When a bet is placed, the contract adds `bet.amount * maxPayoutMultiplier` to the round's `totalPotentialPayout`. It requires `totalPotentialPayout <= address(this).balance`. This is conservative (assumes every bet wins at max payout) but safe and gas-efficient. The alternative (tracking per-outcome exposure) is more capital-efficient but significantly more complex.

> [!NOTE]
> Trio payout depends on type (Unique/Twin/Jackpot), but at bet placement time we don't know which type the user's pick is — actually, we DO know, because the user picks a specific sorted trio like `123` (Unique) or `112` (Twin) or `111` (Jackpot). So the exposure calculation uses the correct multiplier for the user's specific pick.

---

### Tests

#### [NEW] [GenieMath.t.sol](file:///home/faran/foundry-projects/genie-markets/test/GenieMath.t.sol)

- Fuzz `sortTrio` with all 1000 raw inputs — verify output is always sorted and digits are correct.
- Verify all 220 valid trios are reachable.
- Verify `deriveSingle` and `derivePair` math.
- Verify trio type classification for known values.

#### [NEW] [GenieMarkets.t.sol](file:///home/faran/foundry-projects/genie-markets/test/GenieMarkets.t.sol)

- Full round lifecycle: place bets → open draw → place close bets → close draw → claim.
- Phase enforcement: cannot place Open bets during CloseBetting, cannot place Pair bets during CloseBetting, etc.
- Frontrunning prevention: cannot bet after cutoff, cannot bet during Pending.
- Claim mechanics: winner gets correct payout, loser gets nothing, double-claim reverts.
- Cancel flow: stale VRF → cancel → refund.
- Exposure limits: bet rejected when bankroll insufficient.
- Edge cases: zero bet, max bet, bet on invalid pick.

Uses a mock VRF coordinator to simulate `fulfillRandomWords` callbacks.

---

### Dependencies

#### Chainlink VRF v2.5

Install via:
```bash
forge install smartcontractkit/chainlink --no-commit
```

Add remapping in `foundry.toml`:
```toml
remappings = ["@chainlink/=lib/chainlink/"]
```

We inherit from `VRFConsumerBaseV2Plus` and use `VRFV2PlusClient` for request construction.

---

## Verification Plan

### Automated Tests

```bash
forge test -vvv                    # All unit tests
forge test --fuzz-runs 5000 -vvv   # Extended fuzz coverage
forge test --gas-report            # Gas analysis
```

### Key Invariants to Verify
- A bet placed in phase X can only be for bet types valid in phase X.
- VRF callback never iterates over bets (no push payments — O(1) callback).
- `claimWinnings` correctly computes whether a bet is a winner by comparing the pick to the derived result.
- After settlement, `currentRoundId` has incremented and the new round is in `OpenBetting`.
- A cancelled round allows refunds for all bets and no claims.
- Contract balance is always ≥ sum of all unclaimed winning payouts + bankroll obligations.

### Manual Verification
- Deploy to a testnet with Chainlink VRF and run a full round lifecycle.
