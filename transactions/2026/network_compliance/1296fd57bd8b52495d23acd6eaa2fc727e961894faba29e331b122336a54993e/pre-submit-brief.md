# Pre-submit brief: Cyber Castellum October 2026 disburse

## 1. Summary

The transaction pays 18,750 USDM from the network_compliance treasury to Crypto Accounting Group, the established payee for Cyber Castellum. It settles invoice #3546 (dated 7 October 2026, billing period September 2026, Milestone 6, $18,750), accepted at the monthly review of 19 October 2026. Both required signatures are present and the transaction validates against the live node.

## 2. Inputs and outputs

| | UTxO | ADA | USDM |
|---|---|---|---|
| in | ec16…36c8#0 treasury | 199,562.840704 | 21,250 |
| in | ec16…36c8#2 wallet (also collateral) | 9.307255 | – |
| out #0 | treasury leftover | 199,561.651144 | 2,500 |
| out #1 | beneficiary addr1q8qrds…tyf4rl | 1.189560 | 18,750 |
| out #2 | wallet change | 8.859641 | – |
| fee | | 0.447614 | |

Lovelace: 199,572,147,959 in = 199,571,700,345 out + 447,614 fee. USDM: 21,250 = 2,500 + 18,750. Both balance exactly. Four reference inputs (scopes, permissions, treasury script, registry); zero-ADA withdrawal from the permissions reward account. Collateral 0.671421 ADA, returning 8.635834 ADA, is spent only if a script fails. Both spent inputs, read from the node, match.

## 3. What moves

- Scope: network_compliance, treasury addr1xyezq8…8thzgk (script 32201dc1…).
- Payee: the same address as last month's payment.
- The treasury pays the 18,750 USDM plus the 1.189560 ADA minimum for the payee output; the wallet pays the fee.
- After this transaction, the treasury UTxO holds 199,561.65 ADA and 2,500 USDM. It cannot fund another 18,750 USDM payment alone.

## 4. Metadata and references

- Invoice CID bafybeie2okz… and review CID bafybeibccyt… were recomputed from the source PDFs with kubo and match exactly. Neither appears in any earlier archived transaction.
- The three unchanged references (both contracts, address-of-record proof) are byte-identical to last month's.
- Amount, invoice number and payee name match the invoice. The review records agreement to pay $18,750 as of 2026-10-19.
- Wording note, not an error: "October 2026" in the description is the acceptance month, while the invoice bills September work. This follows the convention used last month (invoice #3536 billed August and was labelled September).
- "October2026 cycle review" has no space after the month. Last month's label has the same gap. Cosmetic only.
- Recomputed auxiliary-data hash matches the body.

## 5. Risk checks

- **Expiry:** slot 201,618,201, which is 2026-10-28 10:48:12 UTC. Tip at check time was slot 201,455,527 (2026-10-26 13:36:58 UTC), leaving about 45 hours.
- **Signers:** the on-chain scopes datum (11ace…#0, carrying the "amaru 2026 scopes" token) lists network_compliance = 8bd03209… and ops_and_use_cases = f3ab64b0…. The policy requires the scope owner plus one other owner for a disburse, and both keys are required signers.
- **Witnesses:** two key witnesses are present. Their public keys hash (blake2b-224) to exactly the two required signers. Both verification files report ok, and live validation reports 0 missing witnesses.
- **Changes from last month:** inputs (chained from last month's outputs), fee −871 lovelace, collateral −1,307 lovelace, expiry, and the month wording plus the invoice and review references. Payee, amount, signers and the remaining references are unchanged. No surprises.

## 6. Provenance

- Builder: amaru-treasury-tx 0.2.21.2. Inspection tools: cardano-tx-tools 0.2.3.0.
- txid 1296fd57bd8b52495d23acd6eaa2fc727e961894faba29e331b122336a54993e, recomputed from the signed body.
- The signed body and auxiliary data are byte-identical to the unsigned build. Only key witnesses were added.
- Validation: the build re-evaluated 2 redeemers with 0 failures. A fresh tx-validate run returned structurally_clean, with all 6 UTxOs resolved from the node. A fresh tx-inspect run is identical to the archived one.
- The wizard selected UTxOs through an indexer; spent inputs were rechecked against the node. Script execution was not rerun independently.

## 7. Recommendation

**GO.** Value balances exactly; payee and amount match the invoice and review; documents match their hashes; signers meet the on-chain policy; witnesses are complete; about 45 hours remain. Submit before 2026-10-28 10:48 UTC.
