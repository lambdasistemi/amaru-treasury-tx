# Pre-submit brief — #3522 CAG disburse (Cyber Castellum, July 2026)

## 1. Plain-English summary
This tx pays **18,750 USDM** from the `network_compliance` treasury scope to the
**Crypto Accounting Group** (CAG) payee, on behalf of beneficiary **Cyber Castellum
Corporation**, for its Milestone-3 work accepted at the 8 Jul 2026 cycle review.
The treasury spends four USDM UTxOs, returns leftover USDM to itself, funds the
beneficiary's min-UTxO ADA from its own reserves, and the operator wallet pays only
the 0.709433-ADA fee. Predicted txId `0abab118…b017cb23d`. Everything reconciles;
recommendation is **GO**.

## 2. Inputs / outputs ledger (lovelace / USDM)
Inputs
- Wallet `488e5b41…#2`: 18,449,542 / 0 (also the sole collateral input)
- Treasury `9e3fb6…#1`: 2,408,002 / 5,084,054,444
- Treasury `f16ab7…#1`: 2,459,000 / 5,014,794,921
- Treasury `21654a…#1`: 2,408,000 / 5,012,126,310
- Treasury `68a127…#1`: 2,306,000 / 5,011,215,241
- **Totals: 28,030,544 L / 20,122,190,916 U**

Outputs
- Treasury leftover: 8,391,442 / 1,372,190,916
- Beneficiary (CAG): 1,189,560 / 18,750,000,000
- Wallet change: 17,740,109 / 0
- **Totals: 27,321,111 L / 20,122,190,916 U**; fee 709,433

Conservation: 27,321,111 + 709,433 = **28,030,544 = inputs ✓**. USDM in = out =
20,122,190,916 ✓. Beneficiary min-UTxO (1,189,560) is treasury-funded (post-#229),
leftover = 9,581,002 − 1,189,560 = 8,391,442 ✓. Collateral = 1.5×fee = 1,064,150 ✓.

## 3. Destination + amount cross-check (Principle VIII, non-negotiable)
- **Destination:** output[1] bytes `01c036c15399…b2afa50` decode to
  `addr1q8qrds2…qtyf4rl`, byte-identical to CAG `onchain_address` in vendors.yaml. **MATCH ✓**
- **Amount:** invoice `bafybeic6sh4…ccauu` downloaded & parsed. **Invoice #3522, dated
  7/8/2026, TO Amaru Maintainer Committee, billing period June 2026, Milestone 3
  Completed, Total Due $18,750.00.** Disburse `--amount` 18,750,000,000 µUSDM =
  **18,750 USDM = $18,750.00**. **EXACT MATCH ✓**

## 4. Evidence set (5 refs)
1. payee_contract — `Contract - CRYPTO ACCOUNTING GROUP` (CID = vendors.yaml ✓)
2. payee_address_proof — `Address-of-record proof - CRYPTO ACCOUNTING GROUP` (✓)
3. beneficiary_contract — `Contract - CYBER CASTELLUM CORPORATION` (CID = vendors.yaml ✓)
4. beneficiary_invoice — `Invoice #3522 - CYBER CASTELLUM CORPORATION`
5. beneficiary_cycle_review — `July2026 cycle review - CYBER CASTELLUM CORPORATION`

Exactly 5 refs; kinds correct for a periodic (bi-monthly), non-NDA beneficiary; both
canonical legal names verbatim ✓. Cycle-review doc (dated **08 Jul 2026**) reviews
Milestone 3 and states *"Send Invoice … 18750 $"* — corresponds to this
invoice/milestone ✓.

## 5. Signer roster vs policy + witness validity
Body required-signers = `8bd03209…` (network_compliance owner, selectedScopeOwner) +
`f3ab64b0…` (ops owner, extra-signer). Satisfies permissions.ak *owner + one other
scope owner* ✓. Both witnesses: vkey→blake2b-224 = the required hashes ✓, and both
Ed25519 signatures **verify over the body hash** ✓. tx-validate: **0 witness-
completeness failures**.

## 6. Risk checks
- **TTL:** invalidHereafter 192,547,095 vs current slot ≈192,380,366 → **~166,700 slots
  (~46 h) margin**, not expired ✓
- **tx-validate:** `structurally clean`, exit 0; no WithdrawalsNotInRewardsCERTS raised ✓
- **tx-inspect:** rules-clean; outputs map to treasury / beneficiary / wallet ✓
- **Notes (non-blocking):** (a) wallet UTxO doubles as collateral — valid in Conway,
  validated clean. (b) intent `treasuryLeftoverLovelace`=9,581,002 is the pre-compensation
  figure; actual output leftover is 8,391,442 (expected post-#229). (c) invoice billing
  period reads "June 2026" (work period) while the disburse labels the July acceptance
  cycle — coherent, and review-doc header says "Monthly" vs vendors "bi-monthly" (cosmetic).

## 7. Provenance
- Predicted txId **`0abab118fb103b983b177fb80c247803f3b5ff7f5d98202ddd2f071b017cb23d`** —
  independently recomputed (blake2b-256 of body) and **matches** report.json ✓
- Fee 709,433; body 2,449 B; redeemers 5 / 0 failures; aux-hash `6ac0a512…edc2a`
- Tools: tx-inspect 0.2.0.0, tx-validate 0.2.0.0; network mainnet (magic 764824073)

## 8. Recommendation: **GO**
Every non-negotiable passes: destination byte-matches the registered CAG address, the
$18,750.00 invoice equals the 18,750-USDM disburse, value/USDM conserve exactly, both
required signatures verify, and the live node validates the tx structurally clean with
~46 h TTL headroom. **Most important reason:** the constitution's two NON-NEGOTIABLE
gates — payee destination and invoice amount cross-check — both hold exactly.
