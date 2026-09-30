Goal: produce a blind, independent pre-submit operator brief for the signed Amaru treasury transaction. You are a fresh Claude Opus 5.5 reviewer, with no conversation history. Read only the provided on-disk inputs under /tmp/attx-3536-september-opus55-blind-20260930-bih5w886/input. Treat all summaries and build claims as claims to check independently. No earlier review reports or author validation receipts are supplied. Do not seek them out.

Read input/pre-submit-brief-skill.md in full. Produce its required 400-600 word operator brief with the disbursement economics variant, and write it to output/pre-submit-brief.md. Print the brief verbatim in your final response. Include an independent GO/NO-GO recommendation conditional on explicit operator authorization. You must NEVER submit, sign, rebuild, change any candidate bytes, send messages, contact others, or read credentials/keys/vaults. You may write your report, independent receipts, and verification scripts ONLY under /tmp/attx-3536-september-opus55-blind-20260930-bih5w886/output. No worktree, commits, pushes, external publication or further agents.

Inputs: signed-tx.hex and signed-tx.envelope.json are the candidate. tx.cbor and tx.envelope.json are the unsigned counterpart. intent.json, report.json, wizard.log, build.log, summary.md, version.txt, supporting-documents/*, payment-history/* and superseded/*, transactions-README.md, permissions.md, metadata.json and build-september-cc-disburse.sh are the rest of the allowed evidence. The four payment-history entries are archived submitted predecessors. Compare to the most recent invoice #3528, and to superseded/tx.envelope.json. Primary PDFs for #3528 and #3508 are supplied alongside #3536; verify their billing periods against the archived descriptions yourself. The supplied build-september-cc-disburse.sh establishes default September cycle wording. Verify input-manifest.sha256 at entry and exit, binding the verdict to the signed candidate SHA256 and txid you derive yourself. Record the actual model, tool versions, UTC timestamps and a final status in output/receipt.json.

Independent checks:
- Run your own tx-inspect with Amaru rules FIRST, then your own fresh live tx-validate on signed-tx.hex. Save command outputs, stderr, exit codes and UTC timestamps. Check no structural failures and no missing witnesses. A phase-1 pass is distinct from phase-2 evaluation at build and chain submission.
- Derive the txid from exact body bytes. Verify both vkey witness signatures and all required signers, and the wallet spending input's payment key is covered. Check signed/unsigned body bytes, metadata and non-vkey witnesses are identical. Decoding existing CBOR for independent verification is allowed; never hand-roll, rewrite or assemble CBOR.
- Run your own tx-diff signed vs unsigned and signed vs payment-history/4f64f292d2b8d74f9bade3bdcafb92302b79b6589208147c995e55057b7696b4/signed-tx.hex. Explain meaningful previous-month changes and limits of the renderer.
- Check every spending and reference UTxO, complete ADA/USDM ledger and conservation (including collateral), exact beneficiary address, amount versus the source invoice and acceptance PDF, metadata hashes and references, fee/change/minADA, required signer roster versus policy/registry evidence, TTL/current live slot and UTC expiration, redeemers/build phase-2 claims versus receipts. Explain any unexplained mismatch or unavailable evidence, without rationalizing author summaries. Do not claim duplicate payments excluded solely from these snapshots.
- For independent signature verification, use OpenSSL if needed; no secrets are required. cbor2 is available in the Python path below. You may inspect public toolkit source for decoder/CLI details, but do not inspect other transaction reviews, conversation sessions, memories or global assistant context.

Available tools (use absolute paths; no install/update needed):
  tx-inspect: /home/paolino/bin/tx-inspect (AppImage; use APPIMAGE_EXTRACT_AND_RUN=1)
  tx-validate: /home/paolino/bin/tx-validate (AppImage; use APPIMAGE_EXTRACT_AND_RUN=1)
  tx-diff: /nix/store/xgl5byf225zcl29ngd23jh7nxijqvj4n-tx-diff/bin/tx-diff
  Amaru rules: /code/cardano-tx-tools/rules/amaru-treasury.yaml
  Treasury CLI: /nix/store/jhxamwzqjf3gdwf71ka9b2m25m1fimbw-amaru-treasury-tx-0.2.21.2-with-ca/bin/amaru-treasury-tx
  Python + cbor2: /nix/store/c5a1czm3w8fqp02rbxzc5q70d3c6n46l-python3-3.13.11-env/bin/python3
  OpenSSL: /nix/store/74k8qwbfa6lm8psm2vjh2vj04fpr6c5g-openssl-3.4.1-bin/bin/openssl
  Node socket: /srv/prod-hot/cardano/mainnet/ipc/node.socket
  Mainnet magic: 764824073
  tx-validate flags: --input input/signed-tx.hex --n2c-socket-path SOCKET --network-magic 764824073 --output json
  tx-inspect flags: --rules RULES input/signed-tx.envelope.json [optionally --n2c-socket-path SOCKET --network-magic 764824073]
  tx-diff flags: --collapse-rules RULES A B (exit 1 means differences)

Record START in output/STATUS.md before substantive work, and COMPLETE after the brief and all receipts are saved. If blocked, state precise missing evidence or error and a NO-GO reason; do not silently substitute a model or rely on the parent's validation.

Use standard Markdown with a blank line after every heading and before each list. The final brief must be 400-600 words; place detailed verification receipts in separate output files. Preserve clear separation between technical validation, document/payment provenance, phase-2 build evaluation, and authorization to submit. No blanket GO claim about unknown off-chain payments. You must run your own independent live validation; do not read author validation receipts or previous review files.
