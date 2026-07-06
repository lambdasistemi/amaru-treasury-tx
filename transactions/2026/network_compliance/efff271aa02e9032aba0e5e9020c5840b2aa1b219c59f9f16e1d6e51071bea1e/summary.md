# network_compliance — Swap ADA<->USDM (2-way split)

- **txid:** `efff271aa02e9032aba0e5e9020c5840b2aa1b219c59f9f16e1d6e51071bea1e`
- **status:** submitted (block 13635136, slot 191619804, 2026-07-04T17:28:15Z)
- **scope:** `network_compliance`
- **event:** `disburse` (SundaeSwap V3 swap, split into 2 orders)

## What it does

Spends 52,631.578947 ADA from the `network_compliance` treasury account
into two SundaeSwap V3 escrow swap orders (26,315.789474 / 26,315.789473
ADA), pool `64f35d26b2…40ef` (ADA/USDM), each with a floor of
0.190000 USDM/ADA (~5,000 USDM minimum out per leg, ~10,000 USDM
combined). Treasury change (610,923.506020 ADA) returns to the
`network_compliance` account. Fee (0.434780 ADA) and collateral are
paid from the `network_compliance` scope owner's own wallet UTxO.

Metadata (label/description/justification, on-chain in tx metadata key
1694): label "Swap ADA<->USDM", description "Swap ADA to 10k USDM",
destination "network_compliance", justification "Convert treasury ADA
balance".

## Signers

Required: `8bd03209…` (network_compliance, scope owner) +
`f3ab64b0…` (ops_and_use_cases, extra signer) — satisfies the
"scope owner + one other owner" swap/disburse policy. Both witnesses
collected via `amaru-treasury-tx witness` against
`~/.secrets/treasury.vault.age` and merged with `attach-witness`;
`tx-validate` reported `witness_completeness_count: 0` before submit.

## Pre-submit brief and operator decision

An independent pre-submit brief (fresh subagent, no build context)
flagged a **NO-GO**: at build time the floor left under 1% headroom
on order 1's live SundaeSwap quote, and a sequential-fill estimate
(order 2 executing after order 1 shifts the pool) projected order 2
landing *below* its own 5,000 USDM floor — i.e. a likely partial fill,
not the full ~10k USDM objective. A live re-check immediately before
submit (pool reserves ~2.18M ADA / ~428K USDM, 0.6% LP fee, ADA spot
having rallied to ~$0.1964) confirmed the same conclusion: a combined-
size quote implied order 2's marginal share at ~4,944 USDM, still
short of its floor.

The operator reviewed both the brief and the live re-check and chose
to **submit as-is**, accepting the risk that order 2 may sit unfilled
as a cancellable SundaeSwap escrow order rather than rebuilding with
smaller chunks. If order 2 does not scoop, it can be cancelled via
`amaru-treasury-tx swap-cancel` against its order UTxO once identified
on-chain.

## Known gaps in this archive entry

- No `intent.json` / `wizard.log` / `build.log` / `report.json`: this
  transaction was supplied to the operator session as a pre-built
  unsigned CBOR hex rather than produced by a wizard run in-session,
  so the original build provenance beyond on-chain content is
  unverifiable. `tx-inspect.txt` (captured pre-submit) and live
  `tx-validate` runs stand in for that verification.
- Follow-up needed: check whether order 2 scoops; if not, cancel and
  consider a resize (smaller chunks) on a future swap.

## Provenance

`amaru-treasury-tx 0.2.19.0`, `tx-inspect 0.2.0.0`, `tx-validate 0.2.0.0`.
Final pre-submit `tx-validate --output json`: `status: structurally_clean`,
`exit_code: 0`, `witness_completeness_count: 0`, all UTxO/pparams/slot
sources `n2c` (live node). Blockfrost `/txs/{hash}` confirms
`valid_contract: true`.
