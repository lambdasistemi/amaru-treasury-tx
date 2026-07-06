# ops_and_use_cases — Swap ADA<->USDM (4-way split)

- **txid:** `3f4eec70eb2dd3b69a9d93653b84c86f4185d14a90f87ad822ce47ef43ff4e08`
- **status:** submitted (block 13635205, slot 191621107, 2026-07-04T17:49:58Z)
- **scope:** `ops_and_use_cases`
- **event:** `disburse` (SundaeSwap V3 swap, split into 4 orders)

## What it does

Spends its single treasury input (`4fdd9cd0…#8`, 1,163,066.831345 ADA)
into four SundaeSwap V3
escrow swap orders of 25,644.305641 ADA each (net swap amount
25,641.025641 ADA per leg after order deposit + Sundae fee), pool
`64f35d26b2…40ef` (ADA/USDM), each with a floor of 0.195000 USDM/ADA
(5,000 USDM minimum out per leg, 20,000 USDM combined). Treasury
change (1,060,489.608781 ADA) returns to the `ops_and_use_cases`
account. Fee (0.472854 ADA) and collateral are drawn from the
`network_compliance` scope owner's wallet UTxO (the change output of
the same-session `network_compliance` swap, txid `efff271a…`), which
also stood as the required extra signer for this swap.

Metadata (label/description/justification, tx metadata key 1694):
label "Swap ADA<->USDM", description "Swap ADA to 20k USDM",
destination "ops_and_use_cases", justification "Convert treasury ADA
balance".

## Signers

Required: `f3ab64b0…` (ops_and_use_cases, scope owner) +
`8bd03209…` (network_compliance, extra signer) — satisfies the
"scope owner + one other owner" swap/disburse policy. Both witnesses
collected via `amaru-treasury-tx witness` against
`~/.secrets/treasury.vault.age` and merged with `attach-witness`;
`tx-validate` reported `witness_completeness_count: 0` before submit.

## Build provenance note

The unsigned tx was handed to the operator session as pre-built CBOR
rather than produced by a wizard run in-session. An earlier hex paste
of this same intent, delivered inline in chat, failed to decode
(`tx-inspect`/`tx-validate` both errored at the same byte offset) —
almost certainly chat-transport truncation of a very long hex string,
not a real defect. The operator then supplied the same transaction via
a file (`~/file.txt`), which decoded cleanly and structurally matches
a genuine 4-way equal split (all four legs carry identical size/floor
values, consistent with an even division of the target). No
`intent.json`/`wizard.log`/`build.log`/`report.json` exist in this
archive for the same reason as the `efff271a…` entry.

## Rate economics and operator decision

At the time this transaction was built and initially witnessed, a live
SundaeSwap quote for one leg (25,641.025641 ADA) priced at only
~3,415 USDM — about 32% below the 0.195 floor — apparently because the
same-session `network_compliance` swap (`efff271a…`) had just scooped
against the same ADA/USDM pool moments earlier, consuming liquidity
and moving the price. This was flagged to the operator prior to
submission, along with the standing recommendation (from the
`network_compliance` tx's independent pre-submit brief) that this
tx's floor rate should be checked against live pool depth before
broadcasting.

The operator instructed to **submit without further verification**,
stating the pool had recovered. Per operator instruction, no
independent pre-submit brief was dispatched and no additional
inspect/validate round was run immediately before this submit (the
last `tx-validate` prior to submit was the one taken right after
attaching both witnesses, `witness_completeness_count: 0`,
`structurally_clean`).

## Known gaps in this archive entry

- No `intent.json` / `wizard.log` / `build.log` / `report.json` (see
  above).
- No independent pre-submit brief or final pre-submit re-validation —
  explicitly waived by operator instruction ("submit, no verification,
  the pool is ok").
- Follow-up needed: check whether all four legs scoop given the rate
  concern noted above; if some do not, cancel via
  `amaru-treasury-tx swap-cancel`.

## Provenance

`amaru-treasury-tx 0.2.19.0`, `tx-inspect 0.2.0.0`, `tx-validate 0.2.0.0`.
Last `tx-validate --output json` before submit (post-witnessing):
`status: structurally_clean`, `exit_code: 0`, `witness_completeness_count: 0`,
all UTxO/pparams/slot sources `n2c` (live node). Blockfrost `/txs/{hash}`
confirms `valid_contract: true`.
