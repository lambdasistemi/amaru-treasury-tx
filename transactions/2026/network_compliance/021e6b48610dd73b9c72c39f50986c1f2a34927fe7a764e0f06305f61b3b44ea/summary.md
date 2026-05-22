# May 2026 — Reorganize batch-05 (final consolidation)

**Status:** submitted on mainnet
(cardanoscan: <https://cardanoscan.io/transaction/021e6b48610dd73b9c72c39f50986c1f2a34927fe7a764e0f06305f61b3b44ea>).

Final of the five consolidation batches. Greedy largest-USDM picked
the batch-04 leftover
(`65bfd93936abf4fb26a135e89bd3ef133bb4b02152b37199586ed443979a95b1#0`,
295 706.64 USDM) + 9 next-largest. After this batch the treasury
holds 9 UTxOs total — within the per-tx ExUnits budget for a
single disburse to Antithesis of all 406 381.62 USDM.

## Tx identity

| Field | Value |
|---|---|
| Submitted txId | `021e6b48610dd73b9c72c39f50986c1f2a34927fe7a764e0f06305f61b3b44ea` |
| Fee | 1 570 352 lovelace (≈ 1.57 ADA) |
| Validity (invalidHereafter slot) | 188 080 221 |
| Redeemers | 11 (10 spending + 1 withdrawal), 0 failures |
| Network | mainnet (magic 764 824 073) |

## Treasury accounting

| | USDM |
|---|---|
| input total (10 picked) | 366 113 197 069 |
| treasury leftover (output) | 366 113 197 069 |

## Required signers

- `8bd03209d227956aaf9670751e0aa2057b51c1537a43f155b24fb1c1`

## Treasury state after batch-05

| Field | Pre | Post (expected, on confirm) | Delta |
|---|---|---|---|
| UTxO count | 18 | **9** | −9 |
| USDM total | 406 381 618 692 | **406 381 618 692** | **0** |
| Largest single UTxO | 295 706.64 USDM | **366 113.20 USDM (at `021e6b48…#0`)** | +70 406.56 |

## Cumulative consolidation summary (batches 01–05)

| Batch | txId | Inputs picked | Leftover USDM | Treasury count |
|---|---|---|---|---|
| 01 | `cb8f1a12…b04b7274ba` | 10 | 71 886.81 | 54 → 45 |
| 02 | `019586ee09…d8f503`   | 10 (incl. 01 leftover) | 162 071.81 | 45 → 36 |
| 03 | `71ff129b5e…a13dbe`   | 10 (incl. 02 leftover) | 237 307.84 | 36 → 27 |
| 04 | `65bfd93936…79a95b1`  | 10 (incl. 03 leftover) | 295 706.64 | 27 → 18 |
| 05 | `021e6b4861…b3b44ea`  | 10 (incl. 04 leftover) | **366 113.20** | 18 → **9** |
| (sum) | — | 50 unique consolidated | (~90% of 406 381 in one UTxO) | −45 net |

Total fees paid (operator wallet): 1.57 + 1.57 + 1.57 + 1.57 + 1.57 ≈ **7.85 ADA**.
USDM total at treasury: **unchanged** (406 381.62 USDM) — validator-enforced.

## Next: Antithesis disburse

The final 9 UTxOs (1 mega-leftover at `021e6b48…#0` with 366 113 USDM + ~8 untouched smalls totalling ~40 268 USDM) fit a single `disburse-wizard` invocation. The Antithesis disburse is blocked on:

* Constitution amendment for the NDA-blocked beneficiary contract (Principle VIII v2 → v3; 3-doc minimum carve-out).
* Redacted Antithesis invoice pin + new CID.
* Updated `may-references.json` for the Antithesis disbursement.

## Stack provenance

- main (post-#229 + #231)
- → this PR ([#232](https://github.com/lambdasistemi/amaru-treasury-tx/pull/232))
