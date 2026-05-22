# May 2026 — Reorganize batch-01 (network_compliance USDM consolidation)

**Status:** submitted on mainnet 2026-05-22T17:43:42Z (cardanoscan: https://cardanoscan.io/transaction/cb8f1a1254d650afc1c5b2a1e677df24ac72c4540e96eff52072bcb04b7274ba).

First of the consolidation batches preparing the May 2026 Antithesis disburse. Action: `reorganize` (Sundae `TreasurySpendRedeemer::Reorganize`, constructor 0). Validator's `equal_plus_min_ada(input_sum, output_sum)` rule (`treasury-contracts/lib/logic/treasury/reorganize.ak`) enforces value conservation; no USDM and no lovelace can leave the treasury script address.

## Tx identity

| Field | Value |
|---|---|
| Submitted txId | `cb8f1a1254d650afc1c5b2a1e677df24ac72c4540e96eff52072bcb04b7274ba` |
| Body size | 1 649 bytes |
| Fee | 1 569 920 lovelace (≈ 1.57 ADA) |
| Total collateral | 2 354 880 lovelace |
| Validity (invalidHereafter slot) | 188 077 296 |
| Redeemers / failures | 11 (10 spending + 1 withdrawal) / 0 |
| Network | mainnet (magic 764 824 073) |

## Inputs

10 treasury UTxOs + 1 wallet (funding seed `c150d5c5…#2`, the change from the #202 disburse).

| Treasury input | Lovelace | USDM |
|---|---|---|
| `26542f22…#1` | 2 544 001 | 10 056 971 059 |
| `375c82a8…#1` | 2 544 001 | 10 056 971 059 |
| `432eef5e…#1` | 2 544 003 | 10 007 552 |
| `432eef5e…#2` | 2 544 002 | 10 007 144 |
| `432eef5e…#3` | 2 544 002 | 10 007 144 |
| `4e264208…#1` | 2 306 002 | 10 057 846 145 |
| `c150d5c5…#0` (the #202 disburse leftover) | 3 422 443 | 1 664 173 527 |
| `cf87cc63…#1` | 2 544 001 | 10 057 846 145 |
| `d0dba5b8…#1` | 2 544 001 | 10 057 846 145 |
| `ee9d0211…#1` | 2 956 502 | 10 057 240 321 |
| **Sum** | **26 292 958** | **71 886 805 241** |

| Wallet input | Lovelace |
|---|---|
| `c150d5c5c67658c8f2a3bc24e16a4852257d46a03224257ac990fcca6f6fde78#2` | 89 406 649 |

Reference inputs: scopes datum (`11ace24a…#0`), permissions script (`25ba96f5…#2`), treasury script (`810bfcbd…#0`), registry script (`e7b395a9…#2`).

## Outputs

| Address | Role | Lovelace | USDM |
|---|---|---|---|
| `addr1xyezq8w…thzgk` | treasury leftover | 26 292 958 | 71 886 805 241 |
| `addr1qx9aqvs…sznjcrz` | wallet change | 87 836 729 | — |

Conservation check:
- treasury input lovelace (26 292 958) == treasury output lovelace (26 292 958) ✓
- treasury input USDM (71 886 805 241) == treasury output USDM (71 886 805 241) ✓
- (validator's `equal_plus_min_ada(input_sum, output_sum)` satisfied as equality on both)

## Required signers

| Hash | Role |
|---|---|
| `8bd03209d227956aaf9670751e0aa2057b51c1537a43f155b24fb1c1` | `network_compliance` scope owner (sole signer; `permissions.ak` `Reorganize → approved_by_owner`) |

vkey witness verified vkey `ab71c52f786d308c65cc4772eac66822e8cd169dc267a74f5ec9f7371895cdd9` → blake2b-224 = the expected hash.

## Verification gates passed

- ✓ `tx-inspect --rules amaru-treasury.yaml` clean
- ✓ `tx-validate --n2c-socket-path … --network-magic 764824073` `structurally_clean`, exit 0, `witness_completeness_count: 0`
- ✓ `equal_plus_min_ada(input_sum, output_sum)` satisfied by equality
- ✓ `is_entirely_before(validity_range, config.expiration)` satisfied (validity slot 188 077 296 ≪ treasury expiration)
- ✓ `satisfied(config.permissions.reorganize, …)` satisfied by the single owner vkey witness
- ✓ Double-satisfaction guard: no input at the vendor script credential

## Treasury state after batch-01 confirms

| Field | Pre-batch | Post-batch | Delta |
|---|---|---|---|
| UTxO count | 54 | **45** | −9 (10 consumed + 1 leftover) |
| USDM total | 406 381 618 692 | **406 381 618 692** | **0** |
| Lovelace total | 130 406 832 | **130 406 832** | **0** |

## Next batch

Batch-02 dry-run prepared. New wallet-change `cb8f1a12…#1` (87.83 ADA) auto-picked as funding-seed by the post-#231 wizard. Reorganize chain continues until ≤ 10 UTxOs remain.

## Stack provenance

- main (post-#229 + #231)
- → this PR (#232, https://github.com/lambdasistemi/amaru-treasury-tx/pull/232)
