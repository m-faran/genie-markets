<p align="center">
  <img src="GenieMarkets_Logo.png" alt="Genie Markets Logo" width="200" />
</p>

<h1 align="center">Genie Markets</h1>

<p align="center">
  Onchain daily number-prediction protocol with Chainlink VRF randomness.
</p>

<p align="center">
  <a href="https://github.com/m-faran/genie-markets/actions"><img src="https://github.com/m-faran/genie-markets/actions/workflows/test.yml/badge.svg" alt="CI" /></a>
  <img src="https://img.shields.io/badge/solidity-^0.8.24-363636?logo=solidity" alt="Solidity" />
  <img src="https://img.shields.io/badge/framework-Foundry-orange?logo=data:image/svg+xml;base64," alt="Foundry" />
</p>

---

## Overview

Genie Markets is a **house-funded, USDC-denominated** number prediction market where players wager on digit outcomes derived from Chainlink VRF v2.5 randomness. Each round has two draws — **Open** and **Close** — generating three random digits each. Players can bet on Singles, Trios, or cross-draw Pairs.

All payouts are pull-based with a **30-day claim window**. A 24-hour emergency timeout protects against stale VRF responses.

## How It Works

Each round runs for 24 hours across two market windows. Chainlink VRF settles each window independently, producing five prediction types in total.

### 🕒 Market Windows

1. **Open Market** (configurable, default 18h) — Players wager on **Open Single**, **Open Trio**, and **Pair**.
2. **Close Market** (configurable, default 6h) — Players wager on **Close Single** and **Close Trio**. Close-side bets can also be placed during the Open window, but Open Single, Open Trio, and Pair betting closes at the end of the Open window.

> **Why two windows?** Splitting into Open and Close markets enables the cross-draw **Pair** bet type — you need two independent draws to combine their singles.

### 🎯 Prediction Types

**1. Single Digits (0–9) — 9× payout**

Derived via `(digit1 + digit2 + digit3) mod 10`. There are two variants: **Open Single** (from the Open draw) and **Close Single** (from the Close draw).

*Example:* VRF returns digits `1, 2, 3` → Single = `(1+2+3) % 10` = **6**.

**2. Pairs (00–99) — 90× payout**

Formed by combining the Open Single and Close Single outcomes into a two-digit number.

*Example:*
- Open draw `1, 2, 3` → Open Single = **6**
- Close draw `4, 5, 6` → Close Single = **5**
- Pair = **65**

**3. Trios (000–999) — tiered payouts**

Three-digit predictions sorted canonically under Genie ordering (`1 < 2 < 3 < 4 < 5 < 6 < 7 < 8 < 9 < 0` — zero is the **highest** digit). Enforcing canonical sorting reduces 1,000 raw permutations to exactly **220 unique combinations** with tiered returns:

| Trio Type | Description | Combos | Payout |
|:---|:---|:---:|:---:|
| **Unique** | 3 distinct digits (e.g., `123`) | 120 | 140× |
| **Twin** | 2 identical digits (e.g., `100`) | 90 | 280× |
| **Jackpot** | 3 identical digits (e.g., `000`) | 10 | 600× |

There are two variants: **Open Trio** and **Close Trio**. The Open and Close Singles are derived from their respective Trios.

**Hence the 5 prediction types:** Open Single, Close Single, Open Trio, Close Trio, and Pair.

### Payouts At a Glance

| Bet Type | Range | Payout |
|:---|:---:|:---:|
| Open / Close Single | 0–9 | 9× |
| Pair | 00–99 | 90× |
| Trio (Unique) | 000–999 | 140× |
| Trio (Twin) | 000–999 | 280× |
| Trio (Jackpot) | 000–999 | 600× |

### 🔄 Round Flow

1. Players place wagers on singles, trios, and pairs during the Open window.
2. **Open draw** — Chainlink VRF returns a 3-digit number (e.g., `123`). This is the **Open Trio**. The **Open Single** is derived from it (e.g., `6`).
3. **Close draw** — A second VRF call returns another 3-digit number (e.g., `456`). This is the **Close Trio**. The **Close Single** is derived (e.g., `5`), and the **Pair** is formed from both singles (e.g., `65`). The round settles and the next round begins automatically.

**Round Settlement Example:**

| Result | Value |
|:---|:---:|
| Open Trio | `123` |
| Open Single | `6` |
| Close Trio | `456` |
| Close Single | `5` |
| Pair | `65` |

### Round Lifecycle (Contract States)

```
OpenBetting → OpenPending → CloseBetting → ClosePending → Settled
     │              │                              │
     │         (VRF callback)                 (VRF callback → next round)
     │              │                              │
     └──── (stale 24h) ──→ Cancelled         (stale 24h) ──→ PartiallySettled
```

### 🔒 Security & Escrow

All wagers are locked in a non-custodial smart contract. Payouts are **pull-based** — winners call `claimWinnings()` within a 30-day claim window. Draw requests (`requestOpenDraw()`, `requestCloseDraw()`) and emergency recovery (`cancelStaleRound()`) are **permissionless** — callable by anyone, no keeper dependency.

**Emergency paths:** If VRF doesn't respond within 24 hours:
- Stale Open VRF → **Cancelled** — all bets refundable via `claimRefund()`.
- Stale Close VRF → **PartiallySettled** — open-side winners can claim, close-side and Pair bets refundable.

## Architecture

```
src/
├── GenieMarkets.sol   # Core protocol — betting, draws, claims, bankroll
└── GenieMath.sol      # Pure library — digit sorting, derivation, validation

script/
└── DeployGenieMarkets.s.sol   # Sepolia deployment script

test/
├── GenieMarkets.t.sol   # 31 integration tests covering full lifecycle
├── GenieMath.t.sol      # 15 unit tests + fuzz tests for math library
└── mocks/
    ├── MockUSDC.sol
    └── MockVRFCoordinator.sol
```

### Dependencies

| Dependency | Purpose |
|:---|:---|
| [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts) | `SafeERC20`, `ReentrancyGuard` |
| [Chainlink EVM](https://github.com/smartcontractkit/chainlink-evm) | `VRFConsumerBaseV2Plus`, `VRFV2PlusClient` |
| [Forge Std](https://github.com/foundry-rs/forge-std) | Testing utilities |

## Getting Started

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)

### Install

```bash
git clone https://github.com/m-faran/genie-markets.git
cd genie-markets
forge install
```

### Build

```bash
forge build
```

### Test

```bash
forge test -vvv
```

Fuzz tests run with 1,000 iterations by default (configurable in `foundry.toml`).

## Security Considerations

- **Reentrancy** — All external USDC transfers are guarded by OpenZeppelin's `ReentrancyGuard`.
- **SafeERC20** — All USDC interactions use `SafeERC20` to handle non-standard return values.
- **Stale VRF recovery** — If VRF never responds, a 24-hour timeout lets anyone cancel the stuck round and refund players.

## Known Issues

- **Permissionless draws** — `requestOpenDraw()`, `requestCloseDraw()`, and `cancelStaleRound()` are callable by anyone — no keeper. Chainlink Automation/Keeper will be added in next version.
- **Admin can withdraw funds** - before the settlement of the funds the admin can withdraw funds and rug the protocol/users. Logic to not allow the admin to withdraw more funds than the current open round wagers and all user winning claims will be added in next version. 

## 📜 License

All rights reserved. This code is proprietary and may not be copied, modified, or distributed without explicit permission.
