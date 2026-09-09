# Genie Markets — Onchain Daily Number Prediction Protocol

A provably fair, pull-based daily number prediction game on **Ethereum Sepolia** using Chainlink VRF v2.5 for randomness and **USDC** for bet denomination. Three game modes (Single, Pair, Trio) with a 5-phase round state machine running in 24-hour cycles.

---

## Decisions (Resolved)

| Question | Decision |
|----------|----------|
| Target chain | Ethereum Sepolia |
| Bet denomination | USDC (ERC-20, SafeERC20) |
| Funding model | House-funded (owner bankroll) |
| Bet size / exposure limits | None — no cap, no exposure tracking |
| Draw trigger | Permissionless (anyone calls after cutoff) |
| Round timing | Owner-configurable globally (`openDuration`, `closeDuration`) |
| Claim window | 30-day expiry; unclaimed funds return to bankroll |
| Max bets per user | No cap |
| Emergency cancel | **Partial** — see below |

### Partial Emergency Cancel

If the Open VRF succeeds but the Close VRF stalls beyond 24h:
- Open Single and Open Trio winners **are settled** and can claim payouts.
- Close Single, Close Trio, and **Pair** bets are **refunded** (Pair depends on Close Single, so it cannot be settled).
- Round phase becomes `PartiallySettled`.

If the Open VRF itself stalls beyond 24h:
- Entire round is `Cancelled`. All bets refunded.

### Custom Digit Ordering

> [!IMPORTANT]
> **0 is greater than 9 in Genie Markets.** The digit sort order is: `1 < 2 < 3 < 4 < 5 < 6 < 7 < 8 < 9 < 0`.
>
> Example: raw draw `310` → digits `3, 1, 0` → sorted as `1, 3, 0` (not `0, 1, 3`).
>
> This applies to trio sorting and all digit comparisons. Arithmetic operations (Single derivation via `(d1+d2+d3) % 10`) use standard math — only the **ordering/sorting** follows the custom rule.

---

## Proposed Changes

### Dependencies

#### Chainlink VRF v2.5

```bash
forge install smartcontractkit/chainlink
```

Add remappings in `foundry.toml`:
```toml
remappings = ["@chainlink/=lib/chainlink/"]
```

#### OpenZeppelin (for SafeERC20, Ownable, ReentrancyGuard)

```bash
forge install OpenZeppelin/openzeppelin-contracts
```

Add remapping:
```toml
remappings = [
  "@chainlink/=lib/chainlink/",
  "@openzeppelin/=lib/openzeppelin-contracts/"
]
```

---

### Core Library

#### [NEW] [GenieMath.sol](file:///home/faran/foundry-projects/genie-markets/src/GenieMath.sol)

Pure library — zero state, all derivation math:

- `sortTrio(uint256 raw)` → extracts 3 digits from `raw % 1000`, sorts ascending using **Genie ordering** (`1<2<…<9<0`), returns `(d1, d2, d3)`.
  - Internally maps `0 → 10` for comparison, sorts, maps back.
- `trioType(d1, d2, d3)` → returns `Unique | Twin | Jackpot`.
- `deriveSingle(d1, d2, d3)` → `(d1 + d2 + d3) % 10` (standard arithmetic).
- `derivePair(openSingle, closeSingle)` → `openSingle * 10 + closeSingle`.
- `encodeTrio(d1, d2, d3)` → `d1 * 100 + d2 * 10 + d3` (canonical sorted encoding for bet matching).
- `isValidTrio(uint16 pick)` → verifies the 3 digits are in Genie-sorted order.
- `trioTypeFromPick(uint16 pick)` → extracts digits, returns trio type.

---

### Main Contract

#### [NEW] [GenieMarkets.sol](file:///home/faran/foundry-projects/genie-markets/src/GenieMarkets.sol)

Single immutable contract. Inherits `VRFConsumerBaseV2Plus`, `Ownable`, `ReentrancyGuard`.

**State:**

```solidity
enum RoundPhase {
    OpenBetting,       // Accepting Open Single, Open Trio, Pair bets
    OpenPending,       // VRF requested for Open draw
    CloseBetting,      // Accepting Close Single, Close Trio bets only
    ClosePending,      // VRF requested for Close draw
    Settled,           // Fully settled, claims open
    PartiallySettled,  // Open settled, Close cancelled (stale VRF)
    Cancelled          // Entire round cancelled (stale Open VRF)
}

enum BetType { OpenSingle, CloseSingle, OpenTrio, CloseTrio, Pair }

struct Round {
    RoundPhase phase;
    uint40 openCutoff;
    uint40 closeCutoff;
    uint40 settledAt;          // timestamp for claim expiry calculation
    uint256 openVrfRequestId;
    uint256 closeVrfRequestId;
    // Winning digits (set after VRF fulfillment)
    uint8 openD1; uint8 openD2; uint8 openD3;
    uint8 closeD1; uint8 closeD2; uint8 closeD3;
    uint8 openSingle;
    uint8 closeSingle;
    uint8 pairResult;          // 0-99
}

struct Bet {
    address player;
    BetType betType;
    uint16 pick;               // 0-9 for Single, 0-99 for Pair, 0-999 for Trio (sorted encoding)
    uint128 amount;            // USDC amount (6 decimals)
    bool claimed;
}
```

**Key functions:**

| Function | Access | Description |
|----------|--------|-------------|
| `placeBet(roundId, betType, pick, amount)` | anyone | Validates phase + pick range. Transfers USDC via `safeTransferFrom`. Stores bet. |
| `requestOpenDraw(roundId)` | anyone | Requires `block.timestamp >= openCutoff && phase == OpenBetting`. Requests VRF → `OpenPending`. |
| `requestCloseDraw(roundId)` | anyone | Requires `block.timestamp >= closeCutoff && phase == CloseBetting`. Requests VRF → `ClosePending`. |
| `fulfillRandomWords(requestId, randomWords)` | VRF coordinator | Derives winning numbers, transitions state. On close fulfillment: settles round, inits next round. |
| `claimWinnings(roundId, betIndex)` | bet owner | Pull-based. Checks winner + not expired + not claimed. Transfers USDC payout. |
| `claimRefund(roundId, betIndex)` | bet owner | For `Cancelled` or `PartiallySettled` (close-side bets only). |
| `cancelStaleRound(roundId)` | anyone | After 24h emergency timeout on pending VRF. Full cancel if Open pending; partial if Close pending. |
| `depositBankroll(amount)` | owner | Transfers USDC into contract bankroll. |
| `withdrawBankroll(amount)` | owner | Withdraws excess bankroll USDC. |
| `reclaimExpired(roundId)` | owner | After 30-day claim window closes, sweeps unclaimed winnings back to bankroll. |
| `setDurations(openDuration, closeDuration)` | owner | Updates global round durations. |

**Payout multipliers (hardcoded constants):**

| Bet Type | Payout | RTP |
|----------|--------|-----|
| Single (Open or Close) | 9x | 90% |
| Pair | 90x | 90% |
| Unique Trio | 140x | 84% |
| Twin Trio | 280x | 84% |
| Jackpot Trio | 600x | 60% |

**USDC handling:**
- USDC address passed as immutable constructor arg (Sepolia USDC).
- All transfers via `SafeERC20.safeTransferFrom` / `safeTransfer`.
- Amounts in 6-decimal USDC units.
- Owner must `approve` the contract before calling `depositBankroll`.
- Players must `approve` before calling `placeBet`.

**Claim expiry:**
- `round.settledAt + 30 days` is the claim deadline.
- After expiry, `claimWinnings` reverts. Owner can call `reclaimExpired` to sweep unclaimed funds.

---

### Tests

#### [NEW] [GenieMath.t.sol](file:///home/faran/foundry-projects/genie-markets/test/GenieMath.t.sol)

- **Custom sort order**: verify `310 → 130`, `902 → 290`, `013 → 130`, `100 → 100`, `000 → 000`, `999 → 999`.
- Fuzz `sortTrio` across all 1000 raw inputs — verify output always respects Genie ordering.
- Verify all 220 valid trios are reachable from the 1000 raw inputs.
- Verify `deriveSingle` and `derivePair` arithmetic.
- Verify trio type classification: `123` = Unique, `112` = Twin, `111` = Jackpot.
- Verify `isValidTrio` rejects misordered picks.

#### [NEW] [GenieMarkets.t.sol](file:///home/faran/foundry-projects/genie-markets/test/GenieMarkets.t.sol)

Uses a mock VRF coordinator for deterministic callback simulation.

- **Full lifecycle**: place bets → open draw → place close bets → close draw → claim winners → verify losers can't claim.
- **Phase enforcement**: Open bets rejected during `CloseBetting`; Pair bets rejected during `CloseBetting`; no bets during `Pending` phases.
- **Frontrunning**: bets rejected after cutoff timestamp.
- **Claim mechanics**: correct USDC payout per bet type, double-claim reverts, expired claim reverts.
- **Partial cancel**: Open VRF succeeds → Close VRF stalls → `cancelStaleRound` → Open winners claim, Close/Pair bets refund.
- **Full cancel**: Open VRF stalls → `cancelStaleRound` → all bets refund.
- **Claim expiry**: after 30 days, claims revert; `reclaimExpired` sweeps funds.
- **Edge cases**: zero-amount bet reverts, invalid pick reverts, non-owner bankroll withdrawal reverts.
- **USDC integration**: verify `safeTransferFrom` on bet placement, `safeTransfer` on claim/refund.

---

## Verification Plan

### Automated Tests

```bash
forge test -vvv                    # All unit tests
forge test --fuzz-runs 5000 -vvv   # Extended fuzz coverage on GenieMath
forge test --gas-report            # Gas analysis
```

### Key Properties to Verify
- VRF callback is O(1) — never iterates over bets (pull, not push).
- Genie digit ordering is consistently applied in sort and validation.
- `claimWinnings` correctly matches pick against derived result for each bet type.
- After settlement, `currentRoundId` increments and new round enters `OpenBetting`.
- Partial cancel settles Open winners and refunds Close/Pair bets.
- After 30-day expiry, no more claims; `reclaimExpired` recovers funds.

### Manual Verification
- Deploy to Sepolia with real Chainlink VRF subscription.
- Run a full round lifecycle end-to-end.
