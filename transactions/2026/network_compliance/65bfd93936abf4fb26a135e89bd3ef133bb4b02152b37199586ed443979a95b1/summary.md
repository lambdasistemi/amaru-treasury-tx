# May 2026 — Reorganize batch-04 (network_compliance USDM consolidation)

**Status:** submitted on mainnet
(cardanoscan: <https://cardanoscan.io/transaction/65bfd93936abf4fb26a135e89bd3ef133bb4b02152b37199586ed443979a95b1>).

Fourth of the consolidation batches. Greedy largest-USDM picked the
batch-03 leftover
(`71ff129b5e0b5983ac01da968c6e345a8b6bc36d650a27f18c02ea9787a13dbe#0`,
237 307.84 USDM) + 9 next-largest.

## Tx identity

| Field | Value |
|---|---|
| Submitted txId | `65bfd93936abf4fb26a135e89bd3ef133bb4b02152b37199586ed443979a95b1` |
| Fee | 1 570 352 lovelace (≈ 1.57 ADA) |
| Validity (invalidHereafter slot) | 188 080 052 |
| Redeemers | 11 (10 spending + 1 withdrawal), 0 failures |
| Network | mainnet (magic 764 824 073) |

## Treasury accounting

| | USDM |
|---|---|
| input total (10 picked) | 295 706 635 135 |
| treasury leftover (output) | 295 706 635 135 |

## Required signers

- `8bd03209d227956aaf9670751e0aa2057b51c1537a43f155b24fb1c1`

## Treasury state after batch-04

| Field | Pre | Post (expected, on confirm) | Delta |
|---|---|---|---|
| UTxO count | 27 | **18** | −9 |
| USDM total | 406 381 618 692 | **406 381 618 692** | **0** |

## Next

Batch-05 (final reorganize): new funding seed
`65bfd93936abf4fb26a135e89bd3ef133bb4b02152b37199586ed443979a95b1#1`;
wizard picks new leftover at `65bfd939…#0` (295 706.64 USDM) + 9
next-largest. Expected leftover after batch-05: very close to the
full 406 381.62 USDM total. Treasury count expected: 18 → 9 — within
the ExUnits budget for a single disburse of "spend all" to
Antithesis.

## Stack provenance

- main (post-#229 + #231)
- → this PR ([#232](https://github.com/lambdasistemi/amaru-treasury-tx/pull/232))
