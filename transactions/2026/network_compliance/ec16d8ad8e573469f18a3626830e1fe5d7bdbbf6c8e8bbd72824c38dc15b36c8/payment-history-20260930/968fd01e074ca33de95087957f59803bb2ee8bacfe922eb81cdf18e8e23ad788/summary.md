# June 2026 — Disburse 18 750 USDM to Crypto Accounting Group (Cyber Castellum M2)

**Status:** **submitted on mainnet 2026-07-13T13:18:02Z.** Node N2C
`submit` accepted txId
`968fd01e074ca33de95087957f59803bb2ee8bacfe922eb81cdf18e8e23ad788`;
included in block `facf6cf1e02705df4457087384a3d2b6007eb324d2178e2742e998ff8f5e281f`
(height 13 673 050, slot 192 382 426), `valid_contract: true`.

Tx-level view: <https://cardanoscan.io/transaction/968fd01e074ca33de95087957f59803bb2ee8bacfe922eb81cdf18e8e23ad788>

An independent fresh-subagent pre-submit brief (`pre-submit-brief.md`,
verdict GO) verified both NON-NEGOTIABLE Principle-VIII gates before
signing: destination byte-match to the registered CAG address, and the
invoice #3516 `$18,750.00` amount cross-check.

## Tx identity

| Field | Value |
|---|---|
| txId | `968fd01e074ca33de95087957f59803bb2ee8bacfe922eb81cdf18e8e23ad788` |
| Fee | 516 698 lovelace (≈ 0.517 ADA) |
| Validity (invalidHereafter slot) | 192 546 286 |
| Redeemers / failures | 3 redeemers, 0 failures, `valid_contract: true` |
| Network | mainnet (magic 764 824 073) |
| CLI | amaru-treasury-tx 0.2.19.0; tx-inspect / tx-validate 0.2.0.0 |

## Disburse

Beneficiary **Cyber Castellum Corporation**, invoice **#3516**
(Milestone 2, billing period May 2026), accepted at the **05 June 2026**
cycle review. Paid to the **Crypto Accounting Group** (CAG) payee
address per Principle VIII (all `network_compliance` disburses route to
CAG).

## Inputs

| TxIn | Lovelace | USDM |
|---|---|---|
| wallet `3f4eec70…4e08#5` (fuel + collateral) | 77 928 320 | 0 |
| treasury `ac8efa10…685e#1` | 2 306 000 | 10 009 777 798 |
| treasury `79fe5d22…2261#1` | 2 408 000 | 10 003 337 790 |
| **Σ** | **82 642 320** | **20 013 115 588** |

Reference inputs (read-only): scopes `11ace24a…#0`, permissions
`25ba96f5…#2`, treasury `810bfcbd…#0`, registry `e7b395a9…#2`.

## Outputs

| Address | Lovelace | USDM |
|---|---|---|
| treasury leftover → `network_compliance` | 3 524 440 | 1 263 115 588 |
| beneficiary (CAG payee, min-UTxO treasury-funded) | 1 189 560 | 18 750 000 000 |
| wallet change | 77 411 622 | 0 |

✓ Lovelace conserved (82 642 320 = outputs 82 125 622 + fee 516 698).
✓ USDM in = out = 20 013 115 588. Beneficiary min-UTxO funded from
treasury reserves via the redeemer's `amount.lovelace` (post-#229).

## Rationale references (Principle VIII, 5-doc evidence set)

| # | kind | label | CID |
|---|---|---|---|
| 1 | payee_contract | Contract - CRYPTO ACCOUNTING GROUP | `bafybeibx32gm7…` |
| 2 | payee_address_proof | Address-of-record proof - CRYPTO ACCOUNTING GROUP | `bafkreihl2qvl4…` |
| 3 | beneficiary_contract | Contract - CYBER CASTELLUM CORPORATION | `bafybeib3jef34…` |
| 4 | beneficiary_invoice | Invoice #3516 - CYBER CASTELLUM CORPORATION | `bafybeiarox2hh…` |
| 5 | beneficiary_cycle_review | June2026 cycle review - CYBER CASTELLUM CORPORATION | `bafybeihtwkgx4…` |

## Required signers

| Hash | Role |
|---|---|
| `8bd03209d227956aaf9670751e0aa2057b51c1537a43f155b24fb1c1` | `network_compliance` scope owner |
| `f3ab64b0f97dcf0f91232754603283df5d75a1201337432c04d23e2e` | `ops_and_use_cases` scope owner (`--extra-signer`) |

Satisfies `permissions.ak` (`approved_by_owner_and_someone_else`). Both
vkey witnesses independently verified (blake2b-224 → required hash;
Ed25519 over body hash).

## Companion entry

Built and submitted in the same session as the July 2026 disburse
(invoice #3522, Milestone 3) —
`0abab118fb103b983b177fb80c247803f3b5ff7f5d98202ddd2f071b017cb23d`.
The two txs share no inputs (verified) and both landed in block
13 673 050.

## Verification gates

- ✓ `tx-inspect --rules amaru-treasury.yaml` clean (post-build, post-attach, pre-submit)
- ✓ `tx-validate` structurally clean, 0 witness-completeness failures
- ✓ destination byte-identical to CAG `vendors.yaml` `onchain_address`
- ✓ amount cross-check: invoice #3516 `$18,750.00` = 18 750 USDM
- ✓ independent fresh-subagent pre-submit brief: GO
- ✓ on-chain `valid_contract: true`
