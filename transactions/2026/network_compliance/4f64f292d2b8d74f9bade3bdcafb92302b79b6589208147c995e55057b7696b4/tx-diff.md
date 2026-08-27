# Final transaction comparison — Cyber Castellum invoice #3528

Generated at `2026-08-26T15:55:25Z`.

## Current transaction

- Signed envelope: `signed-tx.tx`
- Signed raw CBOR: `signed-tx.hex`
- Transaction ID: `4f64f292d2b8d74f9bade3bdcafb92302b79b6589208147c995e55057b7696b4`
- Unsigned and signed transaction IDs are identical.
- The assembled transaction contains two vkey witnesses.
- The witness vkey hashes are:
  - `8bd03209d227956aaf9670751e0aa2057b51c1537a43f155b24fb1c1`
    (`network_compliance`)
  - `f3ab64b0f97dcf0f91232754603283df5d75a1201337432c04d23e2e`
    (`ops_and_use_cases`)

The released `tx-diff` version used was `0.2.3.0`, with collapse rules
from `/code/cardano-tx-tools/rules/amaru-treasury.yaml`.

## Authoritative comparison set

The Cyber Castellum-labelled archive scan found exactly three prior
submitted invoices:

| Invoice | Archived transaction |
| --- | --- |
| #3508 | `c150d5c5c67658c8f2a3bc24e16a4852257d46a03224257ac990fcca6f6fde78` |
| #3516 | `968fd01e074ca33de95087957f59803bb2ee8bacfe922eb81cdf18e8e23ad788` |
| #3522 | `0abab118fb103b983b177fb80c247803f3b5ff7f5d98202ddd2f071b017cb23d` |

Address-only matching is insufficient because the Crypto Accounting Group
payee address is also used for another beneficiary. The final inventory
therefore requires both the established payee address and a
`CYBER CASTELLUM` reference label. See
`jon-archive-inventory.cyber-label-filtered.json`.

## Signed-to-signed `tx-diff` result

Each comparison exited `1`, which is the tool's documented indication that
differences were found; decoding and rendering succeeded. Each signed-to-
signed output is byte-identical to its corresponding unsigned body diff.

Across #3508, #3516, and #3522, the only changed body paths are within these
chain-state/accounting classes:

- collateral input;
- fee;
- consumed wallet and treasury inputs;
- treasury change USDM and ADA;
- wallet ADA change;
- total collateral;
- validity upper bound.

These differences are expected between sequential monthly transactions:
previous inputs have been consumed, the treasury balance has advanced, and
fees, collateral, wallet change, and validity bounds are rebuilt against the
then-current ledger state.

The body diffs contain no changes to the payment invariant fields:

- beneficiary output address;
- beneficiary amount: `18,750,000,000` micro-USDM (`18,750 USDM`);
- USDM policy and asset name;
- required signer roster;
- reference-script inputs;
- permissions withdrawal;
- beneficiary output datum/reference script;
- scripts and redeemers.

Complete outputs:

- `tx-diff.final-signed.invoice-3508-vs-3528.paths.txt`
- `tx-diff.final-signed.invoice-3516-vs-3528.paths.txt`
- `tx-diff.final-signed.invoice-3522-vs-3528.paths.txt`

## Expired #3528 versus refreshed #3528

The refresh comparison has exactly four changed paths:

1. `body.collateralInputs.0`
2. `body.inputs.1`
3. `body.outputs.2.coin`
4. `body.validityInterval.invalidHereafter`

That is the replacement wallet input/collateral, corresponding wallet ADA
change, and refreshed validity bound. The treasury inputs, beneficiary output,
fee, collateral amount, scripts/redeemers, reference inputs, signer roster,
and treasury change are unchanged.

See `tx-diff.expired-3528-vs-refreshed-3528.paths.txt`.

## Invoice and rationale evidence

`tx-diff` 0.2.3.0 compares the Conway ledger body and does not project
auxiliary metadata. `jon-invoice-intent-matrix.json` supplements that limit.
It proves across #3508, #3516, #3522, and #3528:

- same amount, beneficiary, USDM policy/token, signer roster, payee contract,
  address proof, and beneficiary contract;
- four distinct invoice labels and four distinct invoice CIDs;
- #3528 carries the August-specific description, justification, invoice CID,
  and cycle-review evidence rather than reusing an old invoice.

## Assembly and validation status

- `tx-diff` between the refreshed unsigned and signed envelopes is empty and
  exits `0`; attaching the witnesses preserved the body.
- `cardano-cli debug transaction view` decodes two vkey witnesses.
- Both witness public keys hash to the two required signer hashes above.
- After the socket ACL was repaired, a fresh live signed `tx-inspect` and
  `tx-validate` both exited `0`. Validation reported `structurally_clean`, no
  failures, all 11 UTxOs sourced from N2C, and witness completeness `0`.
- The transaction was submitted on `2026-08-27` and accepted as
  `4f64f292d2b8d74f9bade3bdcafb92302b79b6589208147c995e55057b7696b4`.
- Blockfrost confirmed it in block 13,863,215 with `valid_contract: true`;
  the indexed CBOR is byte-identical to archived `signed-tx.hex`.
