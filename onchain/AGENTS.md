# AGENTS.md — `onchain/` (bounded swap-vault)

Read this before touching anything in `onchain/`. It is the whole context an agent
needs to work this package **without** loading the rest of `amaru-treasury-tx`.
That isolation is the point: the on-chain validator has a clean seam (its compiled
blueprint), so keep your working set here.

## What this is
The on-chain half of the bot-validator (amaru-treasury-tx **#396**): a
**non-custodial, bounded swap-vault**. Owner/treasury funds are locked under a
constraints datum (the "safety envelope"); a permissioned bot ("placer") may only
emit SundaeSwap V3 `Swap` orders that conform to that datum; the scope owner can
always reclaim. A fully compromised placer can place *worse-but-bounded* orders —
never steal, redirect, change asset/pool/terms, or sell below the floor.

**Treasury-agnostic.** Every datum field is a parameter (`payout`, `placer`,
`floor_rate`, …); nothing assumes Amaru. The compiled **blueprint (`plutus.json`)
is the only interface** to the off-chain consumer — the placer bot, the disburse
path, and the devnet harness all live in `amaru-treasury-tx` and **stay there**.
This package can be lifted to its own repo along the blueprint seam later (exactly
like `sundae-contracts`), once the validator + interface stabilize. Don't extract
early — co-developing the validator with its harness in one place is why the swap
got proven at all.

## Architecture — ONE validator, the wrapper script
`validators/swap_vault.ak`, two handlers on the SAME script:
- `spend` — `Place` (permissioned placer) | `Reclaim` (scope owner → payout).
- `withdraw` — the **recall** handler: post-expiry, double-satisfaction-safe return
  of cancelled orders to the wrapper. Invoked via the order owner's
  `Script(wrapperStake)` withdraw-zero. **This is the crux of the audit.**

## Invariants — each is a RED-test gate (`lib/swap_vault/red_tests.ak`)
Full prose + theorems T1 (Place compromise-bounded) / T2 (cancel/recall safe) in #396.

**Place (T1):** 1 placer signature · 2 floor as a *rate* · 3 **total decoder** pins
`Swap{offer,min_received}` + `destination=Fixed{payout}` (reject `Self` + every
non-`Swap` constructor) + `asset=get_asset` · 4 `pool_ident ∈ allowed_pools` ·
5 `scooper_fee ≤ max_scooper_fee` · 6 change→wrapper, datum verbatim · 7 value
conserved incl. native assets, placer funds its own fee · **8 (THE crux)** count
**all inputs at the wrapper spend credential** — exactly one, NEVER datum/out-ref
scoped (anti batch-drain) · **11** dust-tranche fee-churn: `floor_rate·offer` is
*not* a complete bound (each order burns a fixed protocol fee) → require
`offer ≥ min_offer_lovelace` AND a relative fee cap, and `min_received = ceil(floor_rate·offer)`.

**Recall (T2)** — the withdraw handler must: account for **every**
`Script(wrapperStake)`-owned cancelled order **1:1** (reject N cancelled / <N returned —
anti batch-cancel, **inv 8**); verify each returned wrapper output's datum **==** the
cancelled order's `extension` (**B3**, datum conservation — the staking validator
can't read a spent input's datum, so carry the vault datum in the order extension at
`Place`); and **reject any tx that also spends a wrapper-script input** (**B5**,
isolate Recall from Place). Plus: 9 timelock gates cancel not fill (expired orders
stay scoopable; a late fill is still safe at ≥ floor) · 10 `cancel_authority` is
arbitrary-destination trusted-root power (emergency only).

Two independent adversarial passes (Codex gpt-5.5-high, Gemini) found **no
source-level bypass** of inv 8; **B3/B5 were the second pass's additions**. See the
validation comments on #396.

## SundaeSwap V3 facts you must align with (pinned `be33466b`)
Source: `/tmp/attx-409/sundae-contracts` (or fetch the commit).
- Order owner is a recursive `MultisigScript` (Signature/AllOf/AnyOf/AtLeast/Before/
  After/Script). `Script{h}` = a withdraw-zero of `h` in `withdrawals`
  (`lib/sundae/multisig.ak`); `After(t)` = ledger timelock.
- **Place this owner:** `AnyOf[ AllOf[After(expiry), Script(wrapperStake)], cancel_authority ]`.
  Before expiry only `cancel_authority` cancels; after, the only permissionless
  recall runs via the `wrapperStake` withdraw-zero → forces our `withdraw` handler.
- `order.spend` `Cancel` = `multisig.satisfied(owner)` only, **no** destination
  constraint (`validators/order.ak`). `Scoop` ignores the owner; checks only the
  pool stake script is in `withdrawals`.
- `do_swap` pays the AMM output (not skimmable to `min_received`):
  `give_takes = (pool_take·difference·order_give) / (pool_give·10000 + order_give·difference)`,
  `difference = 10000 − fee_bps` (`lib/calculation/swap.ak`). It pins the destination
  output == computed `give_takes`, then checks `takes ≥ min_received`.
- Verified live: 10 ADA offer, 0.05% fee, 1e9:1e9 reserves → **9_896_088** tokens;
  the 2.5-ADA protocol fee accrues into the pool's `protocolFees`.

## Build / test
No `aiken` on PATH — use nix (first run builds aiken: slow, then caches):
```sh
cd onchain
nix run github:aiken-lang/aiken -- check    # type-check + run tests
nix run github:aiken-lang/aiken -- build    # emit plutus.json (the blueprint = the interface)
```
TODO (its own slice): wire `aiken check` into the repo's nix `checks` so CI gates it.

## Discipline
- **RED before GREEN**: a failing adversarial test per invariant before the code
  that makes it pass. One bisect-safe commit per slice.
- The off-chain side (placer bot, disburse, devnet harness) is **not here** — it
  consumes the blueprint from `amaru-treasury-tx`. This package's only export is the
  blueprint.

## Status
**Scaffold only** — validators are `todo` stubs; the datum/redeemer types and the
red-test roadmap are in place. Part A slices: A1 datum/types → A2 `Place` → A3
`Reclaim` → A4 recall (the crux) → A5 order conformance / total decoder.
