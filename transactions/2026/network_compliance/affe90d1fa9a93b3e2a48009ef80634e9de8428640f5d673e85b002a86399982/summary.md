# may-2026-antithesis (400,000 USDM)

| Field | Value |
| --- | --- |
| TxId | `affe90d1fa9a93b3e2a48009ef80634e9de8428640f5d673e85b002a86399982` |
| Network | mainnet (magic 764824073) |
| Scope | `network_compliance` |
| Action | `disburse` |
| Payee | Crypto Accounting Group (`addr1q8qrds2nnx7clx3kcpp2l0eu45twmdcahsfu9m0xcwy59j6xz3vs0hnfaz9nhje8z34kfnds4jyk7hs6dnrag6e2lfgqtyf4rl`) |
| Beneficiary | Antithesis Operations LLC (NDA-blocked, P-VIII v3 A) |
| Amount | 400,000 USDM (400,000,000,000 micro-USDM) |
| Min-UTxO ADA on beneficiary output | 1.189560 ADA |
| Submitted | 2026-05-23T15:39:00Z |
| Submitter | `local-node-n2c` via `/code/cardano-mainnet/ipc/node.socket` |

## On-chain references

| Kind | Label | CID |
| --- | --- | --- |
| payee_contract | Contract - CRYPTO ACCOUNTING GROUP | `bafybeibx32gm7wefhtvvhojoqjrkjbhntknqkgfu7ryrhptbnmjgz7jvga` |
| payee_address_proof | Address-of-record proof - CRYPTO ACCOUNTING GROUP | `bafkreihl2qvl4coduzqwg4hhh7l7go5ym7y5d7w3flzb5kpxvvquj3i3qm` |
| beneficiary_invoice | Invoice INV-635 - ANTITHESIS OPERATIONS LLC | `bafkreicnoadlgnc6cqxggxboho7yt532lkonxcusj3ndsxdnv5szyswyam` |

The `beneficiary_contract` reference is intentionally omitted under
**Principle VIII v3 carve-out A** (NDA-blocked engagement). The
on-chain `justification` text acknowledges the omission:

> Beneficiary contract omitted: Antithesis NDA (P-VIII v3 A).

The published invoice CID `bafkreicno…` is the redacted version that
removes the Wells Fargo wire/ACH routing and Antithesis bank account
number. The earlier (incorrectly-redacted) draft is preserved as
`witness-network_compliance.envelope.json.stale-leaky-invoice` for
post-mortem evidence (it never reached chain — Damien flagged the
leak before the tx was submitted; this draft was rebuilt from a fresh
wizard run against the corrected manifest).

## Inputs

5 treasury UTxOs from `network_compliance` + 1 wallet fuel UTxO:

| # | TxIn |
| --- | --- |
| treasury | `021e6b48610dd73b9c72c39f50986c1f2a34927fe7a764e0f06305f61b3b44ea#0` |
| treasury | `4a9a1acf4083f6d936ac5c1256b2cca6c3f78ad795d10b76bb2cb574f7ce69f7#1` |
| treasury | `76d6988cd15f1b302fc0832b3c4fa0f1e2c904baa9e8661bda82d938501d5511#1` |
| treasury | `8c3f683232a419dcfee68fccefe13671f45b516423b280cd0e7fe6b52d55e125#1` |
| treasury | `c5e6215afb677ecaf2d50ccdf5c5b5d405acc695c69549380e3a76eef7438b20#1` |
| wallet | `021e6b48610dd73b9c72c39f50986c1f2a34927fe7a764e0f06305f61b3b44ea#1` |

## Outputs

| # | Address | Coin | Other assets |
| --- | --- | --- | --- |
| 0 | `amaru-treasury.network_compliance.account` (leftover) | 120.299272 ADA | 1,349.523953 USDM |
| 1 | CAG beneficiary | 1.189560 ADA | 400,000 USDM |
| 2 | operator wallet (change) | 80.733583 ADA | — |

## Signers

| Scope | Key hash |
| --- | --- |
| network_compliance | `8bd03209d227956aaf9670751e0aa2057b51c1537a43f155b24fb1c1` |
| ops_and_use_cases | `f3ab64b0f97dcf0f91232754603283df5d75a1201337432c04d23e2e` |

Fee 0.820876 ADA, total collateral 1.231314 ADA, invalidHereafter slot
188092799.

## Reproducibility

```bash
scripts/build-may-antithesis-disburse.sh \
  --binary <path-to-amaru-treasury-tx ≥ v0.2.13.0> \
  --wallet-addr addr1qx9aqvsf6gne2640jec828s25gzhk5wp2day8u24kf8mrs2v0zyuvk80fay35dx008p45ts0u6cdrv9g2maetq8jm8psznjcrz \
  --extra-signer f3ab64b0f97dcf0f91232754603283df5d75a1201337432c04d23e2e \
  --out transactions/2026/network_compliance/<rundir> \
  --exec
```

Manifest: `transactions/2026/network_compliance/may-references.json`
(disbursement `may-2026-antithesis`).
