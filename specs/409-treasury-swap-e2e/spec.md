# Spec — #409 Prove the treasury SundaeSwap swap end-to-end on devnet

GitHub: lambdasistemi/amaru-treasury-tx#409
Branch: `409-treasury-swap-e2e` (stacked on `devnet-sundae-scoop-e2e`)

## P1 user story

As an Amaru treasury operator, I need proof that a treasury SundaeSwap swap
order — built with the **shipped** swap path and a **treasury-script
destination** — actually *fills* against a real SundaeSwap V3 pool and the
**treasury receives the swapped asset**, not merely that the order builds. This
closes the live-boundary gap left by the foundation `scoop-e2e` smoke, which
proved the scoop mechanics with a *generic wallet* destination stand-in.

## Background (verified this session)

- Foundation `scoop-e2e` (HEAD `4d3e1e8d`) stands up a fresh SundaeSwap V3
  cascade (settings → pool → pool_stake → order, parameter-applied in Haskell at
  the devnet boot UTxO), creates a liquid ADA/test-token pool, places a
  **generic wallet-destination** order, scoops it, and asserts the wallet
  received the token. Verified GREEN here: `orderConsumed=true`,
  `walletTokenQuantity=9896088`, `scoopTx=9f15b0d7…`.
- The shipped `swapOrderDatum` (lib/Amaru/Treasury/Tx/Swap.hs:210) already
  encodes destination = treasury script credential.
- The SundaeSwap order validator is PlutusV2; the scoop trigger is the
  pool_stake reward-account withdraw-zero (scoop ignores order owner). The
  harness already handles both.

## User stories

1. **Treasury-destination order fills.** A swap order whose destination is a
   treasury script credential is scooped against the fresh-cascade pool and is
   consumed (no longer at the order address).
2. **Treasury receives the swapped asset.** After the scoop, the treasury
   address holds a positive quantity of the swapped token.
3. **Reproducible evidence.** One devnet run writes `summary.json` capturing the
   outcome and the cascade identity, so the proof is auditable and re-runnable.

## Functional requirements

- FR-001: The placed order is built via the shipped swap order-datum path
  (`Amaru.Treasury.Tx.Swap.swapOrderDatum`), with a **treasury-script
  destination**, re-derived against THIS run's fresh-cascade identity (pool
  ident / order address) — not a fixture or a generic wallet stand-in.
- FR-002: The order is scooped against the fresh-cascade SundaeSwap V3 pool
  using the existing pool_stake withdraw-zero + constant-product payout
  mechanics.
- FR-003: The scoop routes the swapped token to the treasury address implied by
  the order's destination credential.
- FR-004: The smoke asserts (a) the order UTxO is consumed and (b) the treasury
  address's swapped-token balance is `> 0`.
- FR-005: The smoke writes `summary.json` recording at least: `orderConsumed`
  (true), `treasuryTokenQuantity` (> 0), the scoop tx id, and the fresh-cascade
  script hashes (settings / pool / pool_stake / order).
- FR-006: Uses the real SundaeSwap V3 validators (fresh cascade), not toy/fixture
  scripts (per readiness spec #132).
- FR-007 (scope-dependent, pending Q-001): whether the treasury is *deployed*
  (spendable, devnet-re-rooted scope/registry) and whether the order is funded
  by `swapProgram` spending treasury UTxOs (+ permissions withdraw-zero + owner
  signers), or the treasury destination is derived-and-paid-to without an
  on-chain deploy. See `questions/Q-001-swap-fidelity.md`.

## Success criteria (acceptance)

- A devnet phase (extend `scoop-e2e` or a new `treasury-swap-e2e`) that, in one
  run: builds a treasury swap order via the shipped builder, scoops it against
  the fresh-cascade pool, and proves the treasury received the asset —
  `summary.json` records `orderConsumed=true` and `treasuryTokenQuantity > 0`,
  plus the scoop tx id and the cascade hashes.
- RED → GREEN, bisect-safe commits; `./gate.sh` green.
- The draft PR names the live-boundary artifact (the `summary.json` with
  `treasuryTokenQuantity > 0` + scoop tx id) before leaving draft.

## Out of scope

- The bot-validator wrapper / safety envelope (#396) — deferred.
- Preview/mainnet live scoops.
- Cancel/recall path (#396 concern).

## Clarifications

- Q-001 (open): fidelity/scope of "the shipped swap path" — datum-faithful
  derive-and-pay (A) vs full deploy + `swapProgram` (B) vs deploy-but-wallet-fund
  (C). Plan.md/tasks.md and the slice breakdown depend on the answer.
