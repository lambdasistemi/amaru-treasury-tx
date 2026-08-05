# August 2026 — Swap 40k USDM (network_compliance with core_development)

**Status:** Awaiting 2 witnesses (`network_compliance` + `core_development`).

Network treasury swap of 40,000 USDM split across 8 SundaeSwap order chunks (5,000 USDM per chunk) at a minimum rate of 0.191 USDM per ADA (48-hour validity horizon, co-signed with `core_development`).

## Tx identity

| Field | Value |
|---|---|
| Status | Pre-submission (unsigned) |
| Validity (invalidHereafter slot) | 194528562 (~48h TTL) |
| Target USDM | 40,000 USDM |
| Order chunks | 8 (5,000 USDM / 26,178.010471 ADA per chunk) |
| Min rate | 0.191 USDM per ADA |
| Network | mainnet (magic 764824073) |

## Inputs

| Input | Role | Lovelace |
|---|---|---|
| `efff271aa02e9032aba0e5e9020c5840b2aa1b219c59f9f16e1d6e51071bea1e#2` | Treasury UTxO | 610 923 506 020 |
| `968fd01e074ca33de95087957f59803bb2ee8bacfe922eb81cdf18e8e23ad788#2` | Wallet fuel | 77 411 622 |

Reference inputs: scopes datum (`11ace24a…#0`), permissions script (`25ba96f5…#2`), treasury script (`810bfcbd…#0`), registry script (`e7b395a9…#2`).

## Outputs

| Address | Role | Lovelace | USDM |
|---|---|---|---|
| `addr1x8ax5k9…` (8 outputs) | 8x Sundae Swap orders | 209 424 083 768 | 40,000 USDM target |
| `addr1xyezq8w…thzgk` | Treasury change | 401 473 182 250 | — |
| `addr1qx9aqvs…sznjcrz` | Wallet change | 76 858 476 | — |

## Required signers

| Hash | Scope Owner |
|---|---|
| `8bd03209d227956aaf9670751e0aa2057b51c1537a43f155b24fb1c1` | `network_compliance` |
| `7095faf3d48d582fbae8b3f2e726670d7a35e2400c783d992bbdeffb` | `core_development` |

## Verification gates passed

- ✓ `tx-inspect --rules amaru-treasury.yaml` verified (8 order outputs, change split clean)
- ✓ `tx-validate --n2c-socket-path … --network-magic 764824073` `structurally_clean`, exit 0
