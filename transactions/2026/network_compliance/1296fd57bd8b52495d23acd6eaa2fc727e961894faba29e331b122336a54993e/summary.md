# Cyber Castellum invoice #3546 — October 2026 acceptance cycle

Status: submitted and confirmed on Cardano mainnet at 2026-10-27T12:07:47+00:00. Both required owner signatures are present. Final live inspection and phase-1 validation with cardano-tx-tools 0.2.3.0 passed immediately before the user-authorized submission. The on-chain transaction CBOR is byte-identical to the reviewed signed artifact. Five parent transactions were fetched and their body hashes verified against their txids.

- Invoice #3546 dated October 7, 2026 bills September 2026 work, Milestone 6, $18,750; payment 18,750 USDM to the established Crypto Accounting Group payee.
- Accepted at the monthly review of October 19, 2026. Description and justification name the October review month, following the convention of every previous cycle (#3528 July work → August, #3536 August work → September).
- Treasury spending input: ec16d8ad8e573469f18a3626830e1fe5d7bdbbf6c8e8bbd72824c38dc15b36c8#0; 199,562.840704 ADA plus 21,250 USDM. Continuing output: 199,561.651144 ADA plus 2,500 USDM.
- Beneficiary receives 18,750 USDM plus 1.189560 ADA minimum output coin, funded by treasury.
- Wallet spending/collateral input: ec16d8ad8e573469f18a3626830e1fe5d7bdbbf6c8e8bbd72824c38dc15b36c8#2; 9.307255 ADA. Wallet change 8.859641 ADA, fee 0.447614 ADA.
- Total collateral: 0.671421 ADA. Collateral return: 8.635834 ADA, only on failure path.
- Required witnessed owners: network_compliance 8bd03209d227956aaf9670751e0aa2057b51c1537a43f155b24fb1c1 (also wallet payment key) and ops_and_use_cases f3ab64b0f97dcf0f91232754603283df5d75a1201337432c04d23e2e. Both witnesses verified against the unsigned body (witness-verification-*.json).
- Expiry, exclusive: slot 201618201; 2026-10-28 10:48:12 UTC.
- Builder: amaru-treasury-tx 0.2.21.2 with `--indexer-url` (UTxO reads from the treasury API indexer; the node's address query timed out). Spent inputs were rechecked against the node by tx-validate. Live socket /srv/prod-hot/cardano/mainnet/ipc/node.socket, mainnet magic 764824073.
- Changes from the September payment (previous-month-signed.diff.txt): inputs, collateral input, fee −871 lovelace, collateral −1,307 lovelace, treasury leftover, wallet change, expiry; metadata month wording, invoice reference (#3546) and cycle review reference. Payee output, amount, signers, reference inputs and the other three references are unchanged. tx-diff does not cover metadata (lambdasistemi/cardano-tx-tools#162); the metadata comparison was done on the intents.
- Invoice and review PDFs are archived under supporting-documents/ with SHA256 checksums; their IPFS CIDs (invoice bafybeie2okzkrbyrant3dzkjoxwlmuca6hy6ica7vjx5qzxc6mcrof2sqe, review bafybeibccytawcc72vvgihgvh77jdtiznha4b2zsxix4arsjqjuupkuz7e) were recomputed from the PDFs by the independent reviewer and match.
- After this payment the network_compliance treasury UTxO holds 2,500 USDM; the next 18,750 USDM payment needs a swap or top-up first.

## Independent pre-submit review

The verbatim brief from a fresh reviewer with no build context is `pre-submit-brief.md`: value conservation exact, signers match the on-chain scopes datum, witnesses complete, documents match their CIDs, recommendation GO.

## On-chain receipt

- Transaction: `1296fd57bd8b52495d23acd6eaa2fc727e961894faba29e331b122336a54993e`
- Block: `b6186090e15db20e916fd4a3b99b83f884e8cd1b0bb8286d99f898bf9e101bd5` (height 14122653)
- Slot: 201536576
- Block time (UTC): 2026-10-27T12:07:47+00:00
- Fee: 447614 lovelace (0.447614 ADA)
- Contract valid: true
- Explorer: https://cardanoscan.io/transaction/1296fd57bd8b52495d23acd6eaa2fc727e961894faba29e331b122336a54993e
- Submission receipt: `submit.log`, `submitted.json`
- On-chain evidence: `on-chain-transaction.json`, `on-chain-tx.hex`
- Exact signed file SHA256: `6e9d60a31a838c9ec855265e5c32337fd296fdee2ab88572031cfb1afa8173ae`
