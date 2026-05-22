# May 2026 — Reorganize batch-02 (network_compliance USDM consolidation)

**Status:** submitted on mainnet 2026-05-22T18:03:06Z
(cardanoscan: <https://cardanoscan.io/transaction/019586ee09f54155379d36ea2c6aa010296dcf5b8e28564a668bec1a44d8f503>).

Second of the consolidation batches. Selection: greedy largest-USDM,
which picked the batch-01 leftover
(`cb8f1a1254d650afc1c5b2a1e677df24ac72c4540e96eff52072bcb04b7274ba#0`,
71 886.81 USDM) as the largest input — this batch progressively
re-consolidates the prior leftover. The `--exclude-utxo` flag had
no treasury-side effect (it filters wallet candidates only — tracked
as issue [#233](https://github.com/lambdasistemi/amaru-treasury-tx/issues/233));
we proceeded with progressive re-consolidation.

## Tx identity

| Field | Value |
|---|---|
| Submitted txId | `019586ee09f54155379d36ea2c6aa010296dcf5b8e28564a668bec1a44d8f503` |
| Fee | 1 569 058 lovelace (≈ 1.57 ADA) |
| Validity (invalidHereafter slot) | 188 078 572 |
| Redeemers | 11 (10 spending + 1 withdrawal), 0 failures |
| Network | mainnet (magic 764 824 073) |

## Treasury accounting

| | lovelace | USDM |
|---|---|---|
| input total (10 picked) | 48 952 188 | 162 071 811 564 |
| treasury leftover (output) | 48 952 188 | 162 071 811 564 |
| validator's `equal_plus_min_ada` | equality | equality |

Picked treasury inputs (by USDM desc):

- `cb8f1a1254d650afc1c5b2a1e677df24ac72c4540e96eff52072bcb04b7274ba#0`
  (batch-01 leftover) — 71 886 805 241
- 9 next-largest USDM-bearing UTxOs

Wallet input (auto-picked by post-#231 wizard):
`cb8f1a1254d650afc1c5b2a1e677df24ac72c4540e96eff52072bcb04b7274ba#1`
(87.83 ADA, batch-01 wallet-change).

## Required signers

| Hash | Role |
|---|---|
| `8bd03209d227956aaf9670751e0aa2057b51c1537a43f155b24fb1c1` | `network_compliance` scope owner |

## Verification gates passed

- ✓ `tx-validate --n2c-socket-path …` `structurally_clean`, exit 0,
  `witness_completeness_count: 0`
- ✓ `equal_plus_min_ada(input_sum, output_sum)` satisfied
- ✓ Pre-expiration time bound satisfied

## Treasury state after batch-02

| Field | Pre | Post | Delta |
|---|---|---|---|
| UTxO count | 45 | **36** | −9 |
| USDM total | 406 381 618 692 | **406 381 618 692** | **0** |
| Lovelace total | 130 406 832 | **130 406 832** | **0** |

## Next

Batch-03: new funding seed
`019586ee09f54155379d36ea2c6aa010296dcf5b8e28564a668bec1a44d8f503#1`;
wizard will again pick the new largest-USDM leftover at
`019586ee…#0` + 9 next-largest; expected leftover after batch-03
~252 000 USDM; treasury count 36 → 27.

## Stack provenance

- main (post-#229 + #231)
- → this PR ([#232](https://github.com/lambdasistemi/amaru-treasury-tx/pull/232))
