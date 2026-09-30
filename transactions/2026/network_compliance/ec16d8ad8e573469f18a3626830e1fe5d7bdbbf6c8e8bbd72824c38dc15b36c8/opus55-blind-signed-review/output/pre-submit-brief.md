# Pre-submit brief: Cyber Castellum invoice #3536, September 2026 cycle

Blind independent review by Claude Opus 5.5, 2026-09-30 UTC. Candidate `signed-tx.hex` SHA-256 `d33ebac0…466a`. Txid derived from body bytes: `ec16d8ad8e573469f18a3626830e1fe5d7bdbbf6c8e8bbd72824c38dc15b36c8`. Nothing was signed, rebuilt or submitted.

## Summary

The network_compliance treasury pays 18,750 USDM to the established Crypto Accounting Group (CAG) payee for Cyber Castellum invoice #3536. That invoice bills August 2026 (Milestone 5) and was accepted at the 9 September review. The metadata labels it "September 2026". That follows the review-month convention of all four archived predecessors and the build-script default.

## What moves, from and to where

- In: treasury `9b1042aa…#1` has 199,564.030264 ADA + 40,000 USDM. Wallet `282bebe2…#1` has 9.755740 ADA and is also the collateral.
- Out: treasury gets back 199,562.840704 ADA + 21,250 USDM. Beneficiary `addr1q8qrds2…tyf4rl` gets 18,750 USDM + 1.189560 ADA, the exact min-ADA, funded by the treasury. Wallet change is 9.307255 ADA.
- Fee: 0.448485 ADA. Collateral: 0.672728 ADA (150% of fee), with 9.083012 ADA returned.
- ADA and USDM balance exactly. The four reference inputs and the zero permissions withdrawal are the same as in #3528.

## Technical validation (phase 1)

- My own tx-inspect with Amaru rules exited 0. My live tx-validate exited 0 with `structurally_clean`, no structural failures, 0 missing witnesses, and all six UTxOs resolved from the node.
- Both Ed25519 witnesses verify over the txid. Their key hashes equal the required signers: `8bd03209…` (network_compliance owner, also the wallet payment key) and `f3ab64b0…` (ops_and_use_cases). That matches the live scopes datum and the owner-plus-another-owner permission rule.
- Signed and unsigned body, metadata and redeemers are byte-identical, and the aux-data hash matches.
- Compared with the superseded build, only these changed: description August→September, expiry, fee +132, change −132, collateral +198/return −198, and the aux hash.
- Compared with #3528, the inputs, amounts, fee, expiry, redeemers, invoice/review references and description wording changed. The beneficiary, amount, signers and scripts did not.
- tx-diff does not show metadata, collateral return or redeemers, so I checked those by decoding the bytes.

## Documents and payment provenance

- IPFS addresses recomputed from the supplied PDFs match the on-chain references for invoice #3536 (dated 9/8/2026, August 2026, $18,750) and the 2026-09-09 acceptance (Milestone 5, $18,750, payment triggered). They also match #3528 (July) and #3508 (April).
- The acceptance deck dates the checkpoint memo "17th Sep", after acceptance. This is informational.
- The contracts and address-of-record proof were not supplied. I verified the payee only as byte-identical to four archived payments.
- The #3528 change is still unspent in the live treasury, and the archive has no #3536 record. Payments made through other channels or off-chain are **not excluded**.
- The author's history.md/json are stale: they describe the August-worded build.

## Phase-2 script evaluation

I did not re-run it independently, because tx-validate only covers phase 1. I rely on the build.log claim: 2 redeemers, 0 failures. The script budgets are unchanged from the superseded build. If a script fails, expect the node to reject the transaction, with at most 0.672728 ADA collateral at risk.

## Expiry

Live tip at 16:40 UTC is slot 199220120. The transaction expires at slot 199388149, 2026-10-02T15:20:40Z, about 46.7 hours after that check.

## Provenance

amaru-treasury-tx 0.2.21.2, tx-inspect/tx-validate 0.2.0.0, tx-diff 0.2.3.0, OpenSSL 3.4.1. The input manifest was verified at entry and exit.

## Recommendation: GO, conditional

GO on technical and document grounds, but only if all three hold:

- the operator explicitly authorizes submission
- the operator confirms invoice #3536 has not been paid through any other channel
- submission happens before 2026-10-02T15:20:40Z

This review does not authorize submission.
