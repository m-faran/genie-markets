### System Architecture Specification: On-Chain Genie Markets Protocol

---

### Core Mechanics and Outcome Derivation

The protocol operates a decentralized, provably fair daily number prediction protocol under the **Genie Markets** architecture, covering three primary game modes: **Single**, **Pair**, and **Trio**. A complete round result consists of an Open phase and a Close phase, formatted as: `[Open Trio] - [Open Single][Close Single] - [Close Trio]`.

* **Trio (3-digit draw):**
* Drawn from 1,000 uniform permutations (`000` to `999`), which collapse into **220 valid Trios** by sorting the 3 digits in ascending order ($d_1 \le d_2 \le d_3$).
* **Unique Trio:** All 3 digits unique ($d_1 < d_2 < d_3$). 120 combinations. Payout: **140x**.
* **Twin Trio:** Exactly 2 digits identical. 90 combinations. Payout: **280x**.
* **Jackpot Trio:** All 3 digits identical (`000`, `111`, etc.). 10 combinations. Payout: **600x**.
* Digit Sorting Order: Standard numeric ascending ($0 \le d_1 \le d_2 \le d_3 \le 9$) must be strictly enforced on both user input and VRF resolution.

* **Single (1-digit outcome):**
* Derived mathematically from the sum of the winning Trio digits modulo 10: $(d_1 + d_2 + d_3) \pmod{10}$.
* Valid range is `0` through `9`.
* Played independently as **Open Single** or **Close Single**. Payout: **9x**.

* **Pair (2-digit outcome):**
* Formed by concatenating the Open Single and Close Single digits: $(\text{Open Single} \times 10) + \text{Close Single}$.
* Valid range is `00` through `99`. Payout: **90x**.

---

### Verifiable Randomness & Mathematical Integrity

* **Uniform VRF Sampling:**
* The contract requests a single random word from Chainlink VRF for each draw and extracts a number between `000` and `999` using the modulo operator `randomWord % 1000`.
* **Never map directly to an index of 220 Trios (`randomWord % 220`).** Extracting 3 uniform digits and sorting them preserves the native real-world probability distribution:
* Unique Trios have 6 permutations per number (0.6% probability each; 84% RTP at 140x).
* Twin Trios have 3 permutations per number (0.3% probability each; 84% RTP at 280x).
* Jackpot Trios have 1 permutation per number (0.1% probability each; 60% RTP at 600x).

---

### Round Lifecycle & 24/7 State Machine

The market operates continuously in 24-hour cycles, with each round identified by an auto-incrementing `roundId`. State transitions follow a strict sequence:

* **Phase 1: Open Betting (`OpenBetting`)**
* Active from round initialization until the Open Cutoff timestamp (e.g., 9:00 PM).
* Eligible markets: Open Single, Open Trio, and **Pair**.

* **Phase 2: Open Draw Pending (`OpenPending`)**
* Triggered automatically by Chainlink Automation or permissionlessly by any user once the Open Cutoff elapses.
* Betting on Open Single, Open Trio, and Pair is permanently frozen.
* A Chainlink VRF request is dispatched.

* **Phase 3: Close Betting (`CloseBetting`)**
* Triggered upon VRF fulfillment of the Open draw.
* The contract records the winning Open Trio and Open Single.
* Only Close Single and Close Trio bets are accepted. Pair betting remains strictly locked.

* **Phase 4: Close Draw Pending (`ClosePending`)**
* Triggered once the Close Cutoff timestamp elapses (e.g., 12:00 AM midnight).
* Close betting is permanently frozen.
* A second Chainlink VRF request is dispatched.

* **Phase 5: Settlement & Continuous Handover (`Settled`)**
* Upon VRF fulfillment of the Close draw, the contract:
* Derives Close Trio, Close Single, and the final winning Pair.
* Marks the current round as `Settled`, permanently unlocking the pull-based claim window for that round's winners.
* Atomically increments `currentRoundId` and initializes the next round with fresh 24-hour cutoff timestamps.

---

### Critical Security Constraints & Attack Mitigations

* **Anti-Frontrunning & MEV Protection:**
* Betting functions must strictly check that the current block timestamp is prior to the cutoff time and that the round is in the appropriate betting state.
* Under no circumstances can bets be placed while a VRF request is pending in the mempool.

* **Pair Timing Arbitrage Prevention:**
* Pair bets must be locked before or at the exact moment the Open draw is initiated. Allowing Pair betting after the Open Single is known reduces odds from 1:100 to 1:10 and guarantees contract insolvency.

* **Pull-Payment Pattern (DoS Gas Limit Mitigation):**
* The VRF callback must **never** iterate over winning bets or push transfers directly. It only records the winning numbers and flips the state.
* Winners must independently trigger an external claim function supplying the round ID and bet ID to withdraw payouts.

* **Emergency Stale VRF Recovery:**
* If a VRF callback fails or drops beyond an emergency threshold (e.g., 24 hours), allow transitioning the round to `Cancelled`, enabling players to claim full refunds on their principal.

Start a plan and if clarity is missing on some part of this protocol ask further questions.