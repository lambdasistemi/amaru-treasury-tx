# May 2026 — Disburse 18 750 USDM to Crypto Accounting Group

**Status:** unsigned draft (S2). Awaiting owner witnesses (S3).
Once submitted, this directory is renamed to
`transactions/2026/network_compliance/<txid>/`.

## Tx identity

| Field | Value |
|---|---|
| Unsigned-tx txId | `db6e0b3a6a49941d36465babe1355e1178c2bfc3646b6fcda7f8b06432485604` |
| Body size | 2 204 bytes |
| Fee | 501 398 lovelace (≈ 0.501 ADA) |
| Total collateral | 752 097 lovelace (≈ 0.752 ADA) |
| Validity (invalidHereafter slot) | 188 065 340 |
| Auxiliary-data hash (label-1694) | `18d40a5ff26d9aaa02bee904ec165d5bc077450f6e48756603acf0b8d14c58b8` |
| Redeemers / failures | 3 redeemers, 0 failures, status `ok` |
| Network | mainnet (magic 764 824 073) |

## Inputs

### Wallet (fuel + beneficiary min-UTxO contribution)

| TxIn | Lovelace |
|---|---|
| `44454ed0def64621ef645958830f599b488b699b28e3797cc37c4f4dd1463a79#2` | 89 922 784 (≈ 89.92 ADA) |

### Treasury (greedy largest-first USDM pick)

| TxIn | Lovelace | USDM |
|---|---|---|
| `77b1b046d1bfb1a09011d4606817ea45d13d8d9e0d02258984d0c6126e4cc9e9#1` | 2 306 002 | 10 239 362 886 |
| `3c3d5332cb159a5f0b42cf48a6f897f1603f94fb4405c6f0c1146d5feb627963#1` | 2 306 001 | 10 174 810 641 |
| **Sum** | **4 612 003** | **20 414 173 527** |

### Reference inputs (read-only)

| TxIn | Purpose |
|---|---|
| `11ace24a7b0caad4a68a38ef2fff18185dc9ea604e84425dab487cae94e4cf54#0` | scopes datum |
| `25ba96f5deb14bb5c56e7542d6a9ba8450f52cc698ebd74574e1a0525d861095#2` | permissions script (`a64d1b9e…fc094`) |
| `810bfcbde85ae72f27d7e8cd154c03c802de15d3fa0dd83a32a4b0fdba330b3c#0` | treasury script (`32201dc1…aa0d`) |
| `e7b395a93d49a17994d66df0e4778a01dee05e7711e6612f28d97b63e4e6311c#2` | registry script (`38c627d4…ea6d`) |

## Outputs

### Treasury leftover (back to `network_compliance`)

| Address | Lovelace | USDM |
|---|---|---|
| `addr1xyezq8wpaqnssdjvd3p220uf7e6nzjae44w6yu625y965rfjyqwur6p8pqmycmzz55lcnan4x99mnt2a5fe54ggt4gxs8thzgk` | 4 612 003 | 1 664 173 527 |

✓ Lovelace == treasury input lovelace (4 612 003 == 4 612 003). Validator's `equal_plus_min_ada` rule satisfied (post-#216 fix; was 2 612 003 in the pre-fix build).

### Beneficiary (CAG payee, min-UTxO from wallet)

| Address | Lovelace | USDM |
|---|---|---|
| `addr1q8qrds2nnx7clx3kcpp2l0eu45twmdcahsfu9m0xcwy59j6xz3vs0hnfaz9nhje8z34kfnds4jyk7hs6dnrag6e2lfgqtyf4rl` | 2 000 000 | 18 750 000 000 |

### Wallet change

| Address | Lovelace |
|---|---|
| `addr1qx9aqvsf6gne2640jec828s25gzhk5wp2day8u24kf8mrs2v0zyuvk80fay35dx008p45ts0u6cdrv9g2maetq8jm8psznjcrz` | 87 421 386 (89.92 − 2.0 beneficiary − 0.501 fee) |

## Rationale (label-1694, CIP-1694 + SundaeSwap TOM spec)

```json
{
  "label": "Pay USDM",
  "event": "disburse",
  "description": "Disburse 18750 USDM (CAG payee) for Cyber Castellum May 2026.",
  "justification": "Acceptance of the Cyber Castellum May 2026 cycle review.",
  "destinationLabel": "Crypto Accounting Group"
}
```

Each text field ≤ 64 bytes (Cardano per-text metadatum cap).

### Five `references[]` (Principle VIII v2 evidence set)

| # | kind | label | URI |
|---|---|---|---|
| 1 | `payee_contract` | `Contract - CRYPTO ACCOUNTING GROUP` | `ipfs://bafybeibx32gm7wefhtvvhojoqjrkjbhntknqkgfu7ryrhptbnmjgz7jvga` |
| 2 | `payee_address_proof` | `Address-of-record proof - CRYPTO ACCOUNTING GROUP` | `ipfs://bafkreihl2qvl4coduzqwg4hhh7l7go5ym7y5d7w3flzb5kpxvvquj3i3qm` |
| 3 | `beneficiary_contract` | `Contract - CYBER CASTELLUM CORPORATION` | `ipfs://bafybeib3jef34ndw6oe24mkmifdvxe5jrv7ulh63rdllovyth27mqfj2da` |
| 4 | `beneficiary_invoice` | `Invoice #3508 - CYBER CASTELLUM CORPORATION` | `ipfs://bafybeigy37ui2ikn7bim2vw6cojcbxkcndpjwh7cj5fv3vzs4cszezipxu` |
| 5 | `beneficiary_cycle_review` | `May2026 cycle review - CYBER CASTELLUM CORPORATION` | `ipfs://bafybeihdmnitrbu2oir3r2fefnpqy3bk7zdz42olzmltmxyt5xag4i2t5a` |

URIs are emitted as 2-element CBOR arrays `["ipfs://", "<cid>"]` to fit the 64-byte per-text cap (matches d6c14625 precedent).

## Required signers

| Hash | Role |
|---|---|
| `8bd03209d227956aaf9670751e0aa2057b51c1537a43f155b24fb1c1` | `network_compliance` scope owner |
| `f3ab64b0f97dcf0f91232754603283df5d75a1201337432c04d23e2e` | `ops_and_use_cases` scope owner (`--extra-signer`) |

Satisfies `permissions.ak` (`approved_by_owner_and_someone_else`).

## T200 evidence (pre-build treasury inspect)

| Field | Value |
|---|---|
| `treasury-inspect --scope network_compliance` USDM total | 414 892.255806 USDM (414 892 255 806 micro-USDM) |
| Disburse amount | 18 750 USDM (18 750 000 000 micro-USDM) |
| Headroom | 22× |
| Treasury UTxO count (at re-build) | 55 (total lovelace 131 596 392) |
| Greedy selection | 2 UTxOs (`77b1b046…#1` + `3c3d5332…#1`), sum 20 414.17 USDM |

## Verification gates passed

- ✓ `tx-inspect --rules amaru-treasury.yaml` clean (T220)
- ✓ `tx-validate --n2c-socket-path /code/cardano-mainnet/ipc/node.socket --network-magic 764824073` `structurally_clean`, exit 0 (T230)
- ✓ `body.references[] | length == 5` with canonical legal names (T240)
- ✓ Pre-#216 phase-2 script eval bug NOT triggered (fixed wizard; merged at `fe19c764`)
- ✓ Phase-1 ledger validation passes (description / justification / destinationLabel each ≤ 64 bytes)
- ✓ TextEnvelope produced by canonical `amaru-treasury-tx envelope-tx` (description = `"Ledger Cddl Format"`, matches every past archived rundir)

## Pending

- Owner witnesses for `8bd03209…b1c1` and `f3ab64b0…d23e2e` (S3).
- Re-run `tx-inspect` + `tx-validate` post-attach (S3 T320).
- Claude-authored pre-submit brief (S4).
- Submit on explicit operator go (S5).
- Populate `inputs/<parent-txid>.cbor` for the 3 parent txs after submit (T530).

## Stack provenance

- main (post-#216 merge at `fe19c764`)
- → this PR (#221, https://github.com/lambdasistemi/amaru-treasury-tx/pull/221)
