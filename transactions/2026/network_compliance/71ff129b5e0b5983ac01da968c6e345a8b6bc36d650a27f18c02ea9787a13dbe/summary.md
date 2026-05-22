# May 2026 — Reorganize batch-03 (network_compliance USDM consolidation)

**Status:** submitted on mainnet
(cardanoscan: <https://cardanoscan.io/transaction/71ff129b5e0b5983ac01da968c6e345a8b6bc36d650a27f18c02ea9787a13dbe>).

Third of the consolidation batches. Selection: greedy largest-USDM,
picked the batch-02 leftover
(`019586ee09f54155379d36ea2c6aa010296dcf5b8e28564a668bec1a44d8f503#0`,
162 071.81 USDM) as the largest input + 9 next-largest. Progressive
re-consolidation.

## Tx identity

| Field | Value |
|---|---|
| Submitted txId | `71ff129b5e0b5983ac01da968c6e345a8b6bc36d650a27f18c02ea9787a13dbe` |
| Fee | 1 572 508 lovelace (≈ 1.57 ADA) |
| Validity (invalidHereafter slot) | 188 079 598 |
| Redeemers | 11 (10 spending + 1 withdrawal), 0 failures |
| Network | mainnet (magic 764 824 073) |

## Treasury accounting

| | lovelace | USDM |
|---|---|---|
| input total (10 picked) | 70 756 801 | 237 307 835 344 |
| treasury leftover (output) | 70 756 801 | 237 307 835 344 |

## Required signers

- `8bd03209d227956aaf9670751e0aa2057b51c1537a43f155b24fb1c1` (`network_compliance` scope owner)

## Treasury state after batch-03

| Field | Pre | Post | Delta |
|---|---|---|---|
| UTxO count | 36 | **27** | −9 |
| USDM total | 406 381 618 692 | **406 381 618 692** | **0** |

## Next

Batch-04: new funding seed
`71ff129b5e0b5983ac01da968c6e345a8b6bc36d650a27f18c02ea9787a13dbe#1`;
wizard picks new leftover at `71ff129b…#0` (237 k USDM) + 9
next-largest. Expected leftover after batch-04: ~313 000 USDM.
Treasury count expected: 27 → 18.

## Stack provenance

- main (post-#229 + #231)
- → this PR ([#232](https://github.com/lambdasistemi/amaru-treasury-tx/pull/232))
