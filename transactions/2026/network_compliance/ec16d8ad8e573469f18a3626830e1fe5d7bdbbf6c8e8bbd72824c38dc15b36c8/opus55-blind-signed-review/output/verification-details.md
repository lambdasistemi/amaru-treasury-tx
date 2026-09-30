# Independent verification details — Cyber Castellum #3536 (September cycle)

Reviewer: Claude Opus 5.5 (claude-opus-5-5), blind, no prior context. All raw receipts are in `receipts/`; scripts in `scripts/`.

## Candidate binding

- `input/signed-tx.hex` file SHA-256: `d33ebac0982c045033a96551265149a27b9886d815bd4cb10865bf190387466a`
- Signed tx bytes (2,331 B) SHA-256: `0d1913c981960c6d8a83ff4bc11a4a34af664f887f86020226e3adde4e6f69da`
- txid = blake2b-256(exact body bytes, 824 B): `ec16d8ad8e573469f18a3626830e1fe5d7bdbbf6c8e8bbd72824c38dc15b36c8`
- Envelope `cborHex` equals hex file for signed, unsigned and superseded (`receipts/decode-verify.json`).
- `report.json` `tx-cbor` equals `tx.cbor`; its txId equals the derived txid.

## Tool runs (UTC)

- tx-inspect 0.2.0.0 `--rules amaru-treasury.yaml` offline: exit 0 (`receipts/tx-inspect.*`).
- tx-inspect live first attempt: exit 1, CLI argument order error (TX must be last), no evaluation; rerun live: exit 0, all inputs resolved (`receipts/tx-inspect-live.*`).
- tx-validate 0.2.0.0 live n2c, 16:39:46Z: exit 0, `structurally_clean`, `structural_failures: []`, `witness_completeness_count: 0`, 6/6 UTxOs from n2c, pparams/slot from n2c (`receipts/tx-validate.*`).
- treasury-inspect (read-only) 16:40Z: tip slot 199220120; network_compliance 13 UTxOs, 409,159.011629 ADA, 40,269.421791 USDM (`receipts/treasury-inspect.*`).
- tx-diff 0.2.3.0: signed vs unsigned exit 0 (no rendered difference); vs #3528 exit 1; vs superseded exit 1 (`receipts/tx-diff-*`).

## Witnesses and signers

- vkey `ab71c52f…cdd9` → blake2b-224 `8bd03209d227956aaf9670751e0aa2057b51c1537a43f155b24fb1c1`; Ed25519 over txid: verified (OpenSSL 3.4.1).
- vkey `f127c082…360a` → `f3ab64b0f97dcf0f91232754603283df5d75a1201337432c04d23e2e`; verified.
- Required signers (body key 14) = exactly these two. Wallet address payment credential = `8bd03209…` → wallet input covered.
- Live scopes datum (`11ace24a…#0`): core `7095faf3…`, ops `f3ab64b0…`, network_compliance `8bd03209…`, middleware `97e0f6d6…` — matches `metadata.json` and `wizard.log`. `permissions.md`: disburse needs scope owner + another owner → satisfied.
- Non-vkey witnesses: redeemers only (key 5); no witness scripts/datums (reference scripts used). Signed vs unsigned: body, aux data, redeemers, is_valid byte-identical; unsigned has no vkeys.

## Ledger

| Item | Lovelace | USDM (µ) |
| --- | --- | --- |
| In `9b1042aa…#1` treasury | 199,564,030,264 | 40,000,000,000 |
| In `282bebe2…#1` wallet (also collateral) | 9,755,740 | 0 |
| Out 0 treasury leftover | 199,562,840,704 | 21,250,000,000 |
| Out 1 beneficiary | 1,189,560 | 18,750,000,000 |
| Out 2 wallet change | 9,307,255 | 0 |
| Fee | 448,485 | — |

- ADA: 199,573,786,004 in = 199,573,786,004 out+fee. USDM: 40,000 = 21,250 + 18,750.
- Treasury net debit = redeemer amount (1,189,560 lovelace + 18,750 USDM); leftover equality holds.
- Beneficiary output 116 B → (160+116)×4310 = 1,189,560 (exact min-ADA at mainnet coinsPerUTxOByte 4310; ledger min-UTxO check also passed in tx-validate).
- Collateral 672,728 = ceil(1.5 × fee); return 9,083,012 = 9,755,740 − 672,728.
- Fee vs rough min-fee estimate ≈444,234 (assumed params); authoritative FeeTooSmall check passed in tx-validate.
- Reference inputs: scopes `11ace24a…#0`, permissions `25ba96f5…#2`, treasury `810bfcbd…#0`, registry `e7b395a9…#2` (identical to all four predecessors). Withdrawal 0 from `a64d1b9e…` (permissions reward account).
- Redeemers: spend index 1 (= `9b1042aa…#1` after canonical input sort) Disburse{1,189,560 lovelace + 18,750 USDM}, ExUnits 524,171 / 174,496,675; reward index 0, ExUnits 217,909 / 69,488,224.

## Metadata (label 1694)

- Aux hash computed = body key 7 = `e43f898a…251a`.
- description "Pay 18750 USDM to CAG for Cyber Castellum September 2026."; justification "Acceptance of the Cyber Castellum September 2026 cycle review."; destination "Crypto Accounting Group"; instance = registry policy `38c627d4…`.
- 5 references equal `supporting-documents/references.json` and the build-script 5-kind set.

## Documents

- IPFS CIDs recomputed from local bytes (`receipts/ipfs-cid-recompute.txt`): invoice #3536 → `bafybeih2x7…62se` MATCH; acceptance 2026-09-09 → `bafybeiedjrhy…ls34` MATCH; #3528 → `QmNQbjmE…eP9f` MATCH (on-chain ref in 4f64f292); #3508 → `bafybeigy37…ipxu` MATCH (on-chain ref in c150d5c5).
- SHA-256 matches: #3536 `86e49a57…1602` (= checksums.txt; fresh-ipfs copy byte-identical); acceptance `fa05e88c…3efd`; #3528 `1cb38149…08a4` (= archived summary); #3508 `61e09b4b…4816` (= history.json).
- Primary PDF reads: #3536 dated 9/8/2026, billing period August 2026, Milestone 5, $18,750. #3528 dated 8/7/2026, July 2026, Milestone 4, $18,750. #3508 dated 5/7/2026, April 2026, Milestone 1, $18,750. Acceptance: Milestone 5 (August) $18,750; "Everyone agreed to trigger the payment process as of 2026.09.09"; deliverable 1 (checkpoint memo) annotated "17th Sep." (after the review); one sub-item struck out.
- Not supplied / not verified: CAG and Cyber Castellum contracts, address-of-record proof, vendors.yaml, September manifest in-tree.

## Month convention

| Invoice | Billing (PDF/archive) | On-chain description month |
| --- | --- | --- |
| #3508 | April (PDF) | May |
| #3516 | May (archive summary) | June |
| #3522 | June (archive summary) | July |
| #3528 | July (PDF) | August |
| #3536 | August (PDF) | September (candidate) |

The wording changed from "Disburse 18750 USDM (CAG payee) for …" to "Pay 18750 USDM to CAG for …", which matches the build-script default.

## Diffs

- vs superseded unsigned (`9f61306e…`): description August→September; TTL 199318513→199388149; fee 448,353→448,485; change 9,307,387→9,307,255; total collateral 672,530→672,728; return 9,083,210→9,083,012; aux hash. Inputs, payee, amount, signers, refs, redeemers/ExUnits and script-data hash unchanged.
- vs #3528 signed: inputs (7→2), collateral input, treasury leftover, wallet change, fee, total collateral/return, TTL, script-data hash and redeemers (6 spend→1 spend), invoice/review references, description wording and month. Beneficiary, amount, asset, signers, reference inputs and withdrawal unchanged.
- Renderer limits: tx-diff/tx-inspect do not render auxiliary data/metadata, collateral return, redeemers, script-data hash or witnesses. tx-diff reports signed≡unsigned despite different witness sets. Live tx-inspect drops address-book names. Covered by byte decode.

## Expiry

Tip 199220120 = 2026-09-30T16:40:11Z. invalidHereafter 199388149 = 2026-10-02T15:20:40Z (last valid slot 199388148), about 46.7 h remaining.

## Duplicate-payment evidence (limited)

- Live treasury still holds #3528 change `4f64f292…#0` (248.542293 USDM) unspent, and the 40,000 USDM UTxO. Treasury USDM = 40,000 + 248.542293 + 20.879498.
- Archive has no #3536 record. The indexer `history` was not queried (no DB path in scope).
- This does NOT exclude payments from other sources, other scopes, or off-chain.

## Author-evidence inconsistencies

- `payment-history/history.md`/`history.json` still describe an "August description" candidate (stale, pre-rebuild).
- The summary claims that old witnesses fail against the new body. Those witnesses were not supplied, so this was not verified.
- The summary's "matching all four previous submitted cycle labels" is true for the month but not for the wording.
- The intent's `treasuryLeftoverLovelace` (199,564,030,264) is before the min-ADA debit. The built leftover is 199,562,840,704, consistent with the redeemer amount.
