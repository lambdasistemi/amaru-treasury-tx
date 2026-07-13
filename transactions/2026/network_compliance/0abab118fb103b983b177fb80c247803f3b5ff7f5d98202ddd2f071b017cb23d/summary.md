# July 2026 — Disburse 18 750 USDM to Crypto Accounting Group (Cyber Castellum M3)

**Status:** **submitted on mainnet 2026-07-13T13:18:02Z.** Node N2C
`submit` accepted txId
`0abab118fb103b983b177fb80c247803f3b5ff7f5d98202ddd2f071b017cb23d`;
included in block `facf6cf1e02705df4457087384a3d2b6007eb324d2178e2742e998ff8f5e281f`
(height 13 673 050, slot 192 382 426), `valid_contract: true`.

Tx-level view: <https://cardanoscan.io/transaction/0abab118fb103b983b177fb80c247803f3b5ff7f5d98202ddd2f071b017cb23d>

An independent fresh-subagent pre-submit brief (`pre-submit-brief.md`,
verdict GO) verified both NON-NEGOTIABLE Principle-VIII gates before
signing: destination byte-match to the registered CAG address, and the
invoice #3522 `$18,750.00` amount cross-check.

## Tx identity

| Field | Value |
|---|---|
| txId | `0abab118fb103b983b177fb80c247803f3b5ff7f5d98202ddd2f071b017cb23d` |
| Fee | 709 433 lovelace (≈ 0.709 ADA) |
| Validity (invalidHereafter slot) | 192 547 095 |
| Redeemers / failures | 5 redeemers, 0 failures, `valid_contract: true` |
| Network | mainnet (magic 764 824 073) |
| CLI | amaru-treasury-tx 0.2.19.0; tx-inspect / tx-validate 0.2.0.0 |

## Disburse

Beneficiary **Cyber Castellum Corporation**, invoice **#3522**
(Milestone 3, billing period June 2026), accepted at the **08 July 2026**
cycle review. Paid to the **Crypto Accounting Group** (CAG) payee
address per Principle VIII (all `network_compliance` disburses route to
CAG).

## Inputs

| TxIn | Lovelace | USDM |
|---|---|---|
| wallet `488e5b41…62e7#2` (fuel + collateral) | 18 449 542 | 0 |
| treasury `9e3fb638…b728#1` | 2 408 002 | 5 084 054 444 |
| treasury `f16ab763…56f9#1` | 2 459 000 | 5 014 794 921 |
| treasury `21654ab5…77e5#1` | 2 408 000 | 5 012 126 310 |
| treasury `68a1277a…2b6b#1` | 2 306 000 | 5 011 215 241 |
| **Σ** | **28 030 544** | **20 122 190 916** |

Reference inputs (read-only): scopes `11ace24a…#0`, permissions
`25ba96f5…#2`, treasury `810bfcbd…#0`, registry `e7b395a9…#2`.

## Outputs

| Address | Lovelace | USDM |
|---|---|---|
| treasury leftover → `network_compliance` | 8 391 442 | 1 372 190 916 |
| beneficiary (CAG payee, min-UTxO treasury-funded) | 1 189 560 | 18 750 000 000 |
| wallet change | 17 740 109 | 0 |

✓ Lovelace conserved (28 030 544 = outputs 27 321 111 + fee 709 433).
✓ USDM in = out = 20 122 190 916. Beneficiary min-UTxO funded from
treasury reserves via the redeemer's `amount.lovelace` (post-#229).

## Rationale references (Principle VIII, 5-doc evidence set)

| # | kind | label | CID |
|---|---|---|---|
| 1 | payee_contract | Contract - CRYPTO ACCOUNTING GROUP | `bafybeibx32gm7…` |
| 2 | payee_address_proof | Address-of-record proof - CRYPTO ACCOUNTING GROUP | `bafkreihl2qvl4…` |
| 3 | beneficiary_contract | Contract - CYBER CASTELLUM CORPORATION | `bafybeib3jef34…` |
| 4 | beneficiary_invoice | Invoice #3522 - CYBER CASTELLUM CORPORATION | `bafybeic6sh4cb…` |
| 5 | beneficiary_cycle_review | July2026 cycle review - CYBER CASTELLUM CORPORATION | `bafybeihm4umyc…` |

## Required signers

| Hash | Role |
|---|---|
| `8bd03209d227956aaf9670751e0aa2057b51c1537a43f155b24fb1c1` | `network_compliance` scope owner |
| `f3ab64b0f97dcf0f91232754603283df5d75a1201337432c04d23e2e` | `ops_and_use_cases` scope owner (`--extra-signer`) |

Satisfies `permissions.ak` (`approved_by_owner_and_someone_else`). Both
vkey witnesses independently verified (blake2b-224 → required hash;
Ed25519 over body hash).

## Companion entry

Built and submitted in the same session as the June 2026 disburse
(invoice #3516, Milestone 2) —
`968fd01e074ca33de95087957f59803bb2ee8bacfe922eb81cdf18e8e23ad788`.
Fuelled by a distinct wallet UTxO (`488e5b41…#2`) and four treasury
UTxOs disjoint from June's, so the two share no inputs (verified); both
landed in block 13 673 050.

## Verification gates

- ✓ `tx-inspect --rules amaru-treasury.yaml` clean (post-build, post-attach, pre-submit)
- ✓ `tx-validate` structurally clean, 0 witness-completeness failures
- ✓ destination byte-identical to CAG `vendors.yaml` `onchain_address`
- ✓ amount cross-check: invoice #3522 `$18,750.00` = 18 750 USDM
- ✓ independent fresh-subagent pre-submit brief: GO
- ✓ on-chain `valid_contract: true`
