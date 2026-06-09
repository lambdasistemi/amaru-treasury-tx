# Tasks — #345

## Slice S1 — input resolution via UTxO outref lookup
- [X] T345-S1a Assess ApiIndexer/UTxOIndexer outref→TxOut capability; record path or Q-file options.
- [X] T345-S1b Thread the UTxO read into tx-detail input resolution: source address → {scope,role} + value (reuse #340/#346 resolver).
- [X] T345-S1c Surface resolved inputs on /v1/tx/{txid}; tests (hermetic).
- [X] T345-S1d just unit + golden + nix build .#default green.

## Slice S2 — graph-effect on the build path
- [X] T345-S2a Emit resolved+projected graph-effect for the unsigned ConwayTx via Cardano.Tx.Graph.Emit (inputs+outputs+datums, cardano-ledger-rdf vocab).
- [X] T345-S2b Add the structured graph-effect to the build response.
- [X] T345-S2c Golden on a contingency disburse + a swap build; gate green.

## Slice S3 — Operate Graph tab
- [ ] T345-S3a Operate result panel Graph tab rendering the resolved spend→produce effect (reuse Format + resolution).
- [ ] T345-S3b nix build .#frontend + live dev smoke on /operate Graph tab.
