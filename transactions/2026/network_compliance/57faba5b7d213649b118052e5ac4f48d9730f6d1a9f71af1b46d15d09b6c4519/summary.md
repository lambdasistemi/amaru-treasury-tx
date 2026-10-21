# August 2026 — Swap 40k USDM (network_compliance + ops_and_use_cases co-signer)

**Status:** **submitted on mainnet 2026-08-05T10:21:11Z.** Node N2C
`submit` accepted txId
`57faba5b7d213649b118052e5ac4f48d9730f6d1a9f71af1b46d15d09b6c4519`;
included in block `baf00e432dbc8eb8d65654ed2af58e4d2963d09ddb5ef382fe801c25ecc0ccda`
(height 13 769 424, slot 194 358 892), `valid_contract: true`.

Tx-level view: <https://cardanoscan.io/transaction/57faba5b7d213649b118052e5ac4f48d9730f6d1a9f71af1b46d15d09b6c4519>

Network treasury swap of 40,000 USDM split across 8 SundaeSwap order
chunks (5,000 USDM per chunk) at a minimum rate of 0.191 USDM per ADA.
An independent fresh-subagent pre-submit brief (`pre-submit-brief.md`,
verdict GO) verified value conservation, rate economics, and the
signer roster against the actual signed tx body before submission.

## Tx identity

| Field | Value |
|---|---|
| txId | `57faba5b7d213649b118052e5ac4f48d9730f6d1a9f71af1b46d15d09b6c4519` |
| Fee | 553 139 lovelace (≈ 0.553 ADA) |
| Validity (invalidHereafter slot) | 194 526 553 |
| Redeemers / failures | 2 redeemers, 0 failures, `valid_contract: true` |
| Target USDM | 40,000 USDM |
| Order chunks | 8 (5,000 USDM / 26,178.010471 ADA per chunk) |
| Min rate | 0.191 USDM per ADA |
| Network | mainnet (magic 764 824 073) |
| CLI | amaru-treasury-tx 0.2.20.1; tx-inspect / tx-validate 0.2.0.0 |

## Inputs

| TxIn | Role | Lovelace |
|---|---|---|
| `efff271aa02e9032aba0e5e9020c5840b2aa1b219c59f9f16e1d6e51071bea1e#2` | Treasury UTxO | 610 923 506 020 |
| `968fd01e074ca33de95087957f59803bb2ee8bacfe922eb81cdf18e8e23ad788#2` | Wallet fuel + collateral | 77 411 622 |
| **Σ** | | **611 000 917 642** |

Reference inputs (read-only): scopes `11ace24a…#0`, permissions
`25ba96f5…#2`, treasury `810bfcbd…#0`, registry `e7b395a9…#2`.

## Outputs

| Address | Role | Lovelace |
|---|---|---|
| `addr1x8ax5k9…` (8 outputs) | 8x SundaeSwap orders | 209 450 323 770 |
| `addr1xyezq8w…thzgk` | Treasury change | 401 473 182 250 |
| `addr1qx9aqvs…sznjcrz` | Wallet change | 76 858 483 |

✓ Lovelace conserved (611 000 917 642 = outputs 611 000 364 503 + fee 553 139).
Each order datum's floor-receive amount matches `chunkSizeLovelace ×
0.191 = 5,000 USDM` to the microUSDM.

## Required signers

| Hash | Scope Owner |
|---|---|
| `8bd03209d227956aaf9670751e0aa2057b51c1537a43f155b24fb1c1` | `network_compliance` |
| `f3ab64b0f97dcf0f91232754603283df5d75a1201337432c04d23e2e` | `ops_and_use_cases` |

Satisfies `permissions.ak` (`approved_by_owner_and_someone_else`). Both
vkey witnesses independently verified (blake2b-224 → required hash;
Ed25519 over body hash).

**Note on same-day signer churn:** this entry's co-signer was briefly
edited in place to `core_development` (superseded commit, since
reverted) between build and witness collection. The tx as actually
witnessed and submitted always used `ops_and_use_cases` — verified
directly against `requiredSigners` on the signed tx body and against
the collected witness files before submit. See `pre-submit-brief.md`
§6 for the independent confirmation.

## Verification gates

- ✓ `tx-inspect --rules amaru-treasury.yaml` clean (post-build,
  post-attach, pre-submit — `tx-inspect.log`)
- ✓ `tx-validate` structurally clean, 0 witness-completeness failures
  (`tx-validate.log`)
- ✓ rate math: `209,424.083770 ADA × 0.191 = 40,000.000000 USDM` exact,
  chunk-by-chunk and in aggregate
- ✓ independent fresh-subagent pre-submit brief: GO
- ✓ on-chain `valid_contract: true`
