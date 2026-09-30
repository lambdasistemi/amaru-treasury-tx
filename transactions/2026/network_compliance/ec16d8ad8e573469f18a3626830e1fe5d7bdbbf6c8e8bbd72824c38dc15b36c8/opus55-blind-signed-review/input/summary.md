# Cyber Castellum invoice #3536 — September 2026 acceptance cycle

Status: rebuilt with September cycle wording, both required owner signatures verified and assembled, not submitted. Fresh signed live phase-1 validation passed with no structural failures and missing witnesses count 0. Awaiting independent blind pre-submit review and explicit operator go.

- Invoice #3536 dated September 8, 2026 bills August 2026 work, Milestone 5, $18,750; payment 18,750 USDM to the established Crypto Accounting Group payee.
- Description uses September acceptance/review month, matching all four previous submitted cycle labels. Justification references September acceptance. Invoice and review references are unchanged from the superseded candidate.
- New txid: ec16d8ad8e573469f18a3626830e1fe5d7bdbbf6c8e8bbd72824c38dc15b36c8.
- Treasury spending input: 9b1042aa25c7e69b1965e668e6265b3f3e65e0a8c780016d6c56b175986acfb3#1; 199,564.030264 ADA plus 40,000 USDM. Continuing output: 199,562.840704 ADA plus 21,250 USDM.
- Beneficiary receives 18,750 USDM plus 1.189560 ADA minimum output coin, funded by treasury.
- Wallet spending/collateral input: 282bebe2ec58fbf28dc9f410e954f577ba2c055b9878d6a46eeac3352b369abf#1; 9.755740 ADA. Wallet change 9.307255 ADA, fee 0.448485 ADA.
- Total collateral: 0.672728 ADA. Collateral return: 9.083012 ADA, only on failure path.
- Required witnessed owners: network_compliance 8bd03209d227956aaf9670751e0aa2057b51c1537a43f155b24fb1c1 (also wallet payment key) and ops_and_use_cases f3ab64b0f97dcf0f91232754603283df5d75a1201337432c04d23e2e.
- Expiry, exclusive: slot 199388149; 2026-10-02 15:20:40 UTC.
- Builder: released amaru-treasury-tx 0.2.21.2; two redeemers re-evaluated during fresh build. Live socket /srv/prod-hot/cardano/mainnet/ipc/node.socket, mainnet magic 764824073.
- Only metadata change from superseded unsigned candidate: description August -> September. Additional rebuild changes: expiry; fee +132 lovelace; wallet change -132; collateral +198 and return -198; corresponding auxiliary-data hash. Inputs, payee, amount, signers, references, redeemers and execution budgets remain unchanged.
- Fresh invoice download from the archived IPFS CID on September 30 is byte-identical to the original invoice PDF, sha256 86e49a5717b4d0132899af4e4ef356b0e5182e94fe8022db13be965f719e1602.
- Previous submitted invoice #3528 bills July 2026, accepted in August. Its primary PDF has been supplied; its archived hash matches the local source PDF. The four submitted predecessor records were fetched from main on September 30 and their exact signed txids and metadata independently checked. No invoice #3536 submission record was present in that archive snapshot; this is not a complete independent off-chain payment-history check.
- The old signed August-worded candidate remains preserved under /code/amaru-treasury-tx/transactions/2026/network_compliance/2026-09-29-disburse-cyber-castellum-august-rebuild. It is superseded. Old witnesses demonstrably fail against this new body hash and are retained under superseded-witnesses/ with .stale-month-wording suffixes.

Receipts: report.json, build.log, signed-witness-verification.json, signed-validate.json, signed-vs-unsigned.diff.txt, cross-check.json, previous-month.diff.txt. These are author evidence; the independent reviewer must verify primary bytes and run its own tools.
