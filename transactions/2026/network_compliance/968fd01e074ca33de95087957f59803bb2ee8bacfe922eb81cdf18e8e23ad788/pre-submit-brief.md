# Pre-submit brief — #3516 Disburse 18 750 USDM (June 2026, CAG payee / Cyber Castellum beneficiary)

## 1. Plain-English summary
Mainnet `network_compliance` treasury disburse of **18 750 USDM** to the Crypto Accounting Group (CAG) payee address, paying Cyber Castellum Corporation's June-2026 cycle (invoice #3516, Milestone 2). Two treasury UTxOs supply the USDM; the operator wallet supplies fuel and takes change. Predicted txid `968fd01e074ca33de95087957f59803bb2ee8bacfe922eb81cdf18e8e23ad788`. Independently re-derived and verified — no discrepancies found.

## 2. Inputs / outputs ledger + conservation
Inputs (values as resolved from chain, corroborated by node validation):
- wallet `3f4eec70…4e08#5` — 77 928 320 lovelace, 0 USDM
- treasury `ac8efa10…685e#1` — 2 306 000 lovelace, 10 009 777 798 USDM
- treasury `79fe5d22…2261#1` — 2 408 000 lovelace, 10 003 337 790 USDM
- **Σ inputs = 82 642 320 lovelace, 20 013 115 588 USDM**

Outputs + fee:
- [0] treasury leftover — 3 524 440 lovelace, 1 263 115 588 USDM
- [1] beneficiary (CAG) — 1 189 560 lovelace, 18 750 000 000 USDM
- [2] wallet change — 77 411 622 lovelace, 0 USDM
- fee — 516 698 lovelace
- **Σ outputs+fee = 82 642 320 lovelace, 20 013 115 588 USDM**

**Conserved exactly** — lovelace 82 642 320 = 82 642 320; **USDM in = USDM out = 20 013 115 588**. Collateral (input #5, total 775 047, return 77 153 273) is separate and self-consistent.

## 3. Destination + amount cross-check (constitution VIII — NON-NEGOTIABLE)
- **Destination:** beneficiary output bytes `01c036c153…b2afa50` are **byte-identical** to the CAG `onchain_address` in `vendors.yaml` (and to `intent.beneficiaryAddress`). PASS.
- **Amount:** downloaded `bafybeiarox2…ramm` (1-page PDF). Invoice **#3516**, Cyber Castellum Corporation (1924 Central Ave, Albany NY — matches vendors.yaml), dated **6/15/2026**, RE "Network compliance & Cardano level Testing: White-Hacking", **Milestone 2 Completed**, **Total Due $18,750.00**. Disburse 18 750 000 000 micro-USDM = **18 750 USDM = $18,750**. **Exact match.** PASS.
- Note (non-blocking): invoice "BILLING PERIOD" reads *May 2026* while the rationale labels the cycle *June 2026* — consistent with the 05-Jun-2026 review accepting prior-period work (same pattern as the May #3508 precedent).

## 4. Evidence set
Exactly **5** references, canonical legal names verbatim, CIDs all match `vendors.yaml`:
1. payee_contract — "Contract - CRYPTO ACCOUNTING GROUP" (`bafybeibx32…`)
2. payee_address_proof — "Address-of-record proof - CRYPTO ACCOUNTING GROUP" (`bafkreihl2q…`)
3. beneficiary_contract — "Contract - CYBER CASTELLUM CORPORATION" (`bafybeib3je…`)
4. beneficiary_invoice — "Invoice #3516 - CYBER CASTELLUM CORPORATION" (`bafybeiarox2…`)
5. beneficiary_cycle_review — "June2026 cycle review - CYBER CASTELLUM CORPORATION" (`bafybeihtwk…`)

Cycle-review PDF downloaded and parsed: "Amaru – Monthly Scope review, 05th June 2026, White hacking (Cyber Castellum)", "trigger the payment process as of 2026.06.05", "Send Invoice … 18750 $" — matches this milestone/amount/period. PASS.

## 5. Signer roster + witness validity
Body `requiredSigners` = `8bd03209…b1c1` (network_compliance owner) + `f3ab64b0…d23e2e` (ops scope owner). Two vkey witnesses attached; each vkey blake2b-224 hashes back to its required-signer hash, and **both Ed25519 signatures verify over the txid**. Satisfies permissions.ak "owner + ≥1 other scope owner". tx-validate: **0 witness-completeness failures**. PASS.

## 6. Risk checks
- **TTL:** invalidHereafter 192 546 286 vs live tip slot **192 380 475** → margin **≈165 811 slots ≈ 46 h**. Not expired, ample. PASS.
- **tx-validate:** "structurally clean: 0 witness-completeness failures filtered" (no WithdrawalsNotInRewardsCERTS raised). Withdrawal is zero on reward acct `f1a64d1b…fc094`. PASS.
- **Surprises:** none. 3 outputs only (no unexpected split); change/collateral return correctly to the operator wallet (whose payment cred equals `8bd03209`). Aux-data hash `6b7a9c60…` recomputed and matches body. Scope = network_compliance throughout.

## 7. Provenance
- Predicted txid `968fd01e074ca33de95087957f59803bb2ee8bacfe922eb81cdf18e8e23ad788` (independently recomputed from the exact 852-byte body).
- Tool versions: tx-inspect 0.2.0.0, tx-validate 0.2.0.0. Signed tx 2430 bytes (unsigned 2223).
- Validation status: node re-eval ok, 3 redeemers / 0 failures; tx-validate structurally clean.

## 8. Recommendation
**GO.** Both NON-NEGOTIABLE constitution-VIII gates hold — the beneficiary bytes equal the canonical CAG address, and invoice #3516's $18,750 equals the 18 750 USDM disburse — with value conserved to the lovelace, both required signatures valid, and ~46 h TTL headroom. Single most important reason: **destination and amount both match the canonical source-of-truth exactly.**
