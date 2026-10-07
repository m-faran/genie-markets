# Run 1 — solidity-auditor

<!--RUN pass=1 of=1 stamp=20261007-203112 sha=1f5bc89 agents=12/12-->

Pass 1 of 1 · 2026-10-07 · `1f5bc89` · 12/12 specialties applied — this runtime has no sub-agent tool, so one reader applied all twelve lenses.

## Findings

<!--F key=geniemarkets|cancelstaleround|stale-anchor conf=75 kind=FINDING agents=1-->

[75] **Staleness is measured from the market cutoff, not the draw request**

`GenieMarkets.cancelStaleRound` · Confidence: 75

**Description**
A caller can request a draw 24 hours after the market cutoff and then cancel the round, so winners receive a refund instead of their payout.

**Fix**

```diff
@@ -238,6 +238,7 @@ contract GenieMarkets is IEntropyConsumer, ReentrancyGuard, Ownable {
     round.phase = RoundPhase.OpenPending;
+    round.openRequestedAt = uint40(block.timestamp);
 
     uint256 fee = i_entropy.getFee(i_provider);
@@ -355,10 +356,10 @@
     if (round.phase == RoundPhase.OpenPending) {
-        if (block.timestamp <= round.openCutoff + EMERGENCY_TIMEOUT) {
+        if (block.timestamp <= round.openRequestedAt + EMERGENCY_TIMEOUT) {
             revert NotStaleYet();
         }
     } else if (round.phase == RoundPhase.ClosePending) {
-        if (block.timestamp <= round.closeCutoff + EMERGENCY_TIMEOUT) {
+        if (block.timestamp <= round.closeRequestedAt + EMERGENCY_TIMEOUT) {
             revert NotStaleYet();
         }
```

<!--/F-->

## Leads

<!--F key=geniemarkets|requestopendraw|uninitialized-round-reachable kind=LEAD agents=1-->

- **An uninitialized round id can be drawn and settled** — `GenieMarkets.requestOpenDraw` — Code smells: an unknown round id defaults to `RoundPhase.OpenBetting` with `openCutoff == 0`, so the cutoff guard passes — Any caller can call `requestOpenDraw` with a round id that nobody initialized, because the default phase is `OpenBetting` and the default cutoff is zero. The open callback moves that round to `CloseBetting`, a second request and callback settle it, and `_initNextRound()` then creates a round out of band, so `s_currentRoundId` no longer names the only round that takes bets. We did not find a path that moves user funds through it.

<!--/F-->

<!--F key=geniemarkets|requestopendraw|raw-call-refund-reentrant kind=LEAD agents=1-->

- **Request functions refund excess ETH with a raw call and no guard** — `GenieMarkets.requestOpenDraw` — Code smells: `.call{value:}` to `msg.sender` inside a function that is not `nonReentrant` — `requestOpenDraw` sets the phase and then sends the excess fee to the caller with a raw `call`, so the caller runs code while the round is already `OpenPending`. The only useful re-entry is `cancelStaleRound`, and that call needs the stale window, so this lead alone has no impact. Add `nonReentrant` or refund by pull.

<!--/F-->

<!--F key=geniemarkets|checkpayout|view-write-divergence kind=LEAD agents=1-->

- **checkPayout ignores the claimed flag and the claim window** — `GenieMarkets.checkPayout` — Code smells: the view skips the `bet.claimed` check and the `settledAt + CLAIM_PERIOD` check that `claimWinnings` applies — The view returns a payout for a bet that the caller already claimed or that passed the 30-day window. An integrator that trusts the view shows a claim that reverts.

<!--/F-->

<!--F key=geniemarkets|withdrawbankroll|unbounded-admin-withdraw kind=LEAD agents=1-->

- **Owner withdrawal is not capped to the house bankroll** — `GenieMarkets.withdrawBankroll` — Code smells: no `bankroll` accounting and no separation between house funds and player wagers — The contract holds the bankroll and the wagers in one balance, so the owner can withdraw the wagers that a later refund or payout needs. The README records this risk as a known issue that the next version fixes.

<!--/F-->

<!--F key=deploygeniemarkets|run|wrong-chain-token-address kind=LEAD agents=1-->

- **The deploy script keeps the Ethereum Sepolia token on Monad** — `DeployGenieMarkets.run` — Code smells: the `usdc` literal `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238` moved from the Sepolia block to the Monad Testnet block unchanged — The script passes the Sepolia USDC address to a Monad Testnet deployment, so `SafeERC20` reverts with `AddressEmptyCode` on every transfer and the contract can take no bet and pay no claim. We did not check whether another token holds that address on Monad.

<!--/F-->
