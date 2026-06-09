# Plan — #345 Operate graph-effect preview

Backend (resolution + graph-emit on the build path) + frontend (Graph tab).

## Slice S1 — input resolution via UTxO outref lookup (the deferred S2c)
- Assess the ApiIndexer/UTxOIndexer: can it resolve an outref (txid#ix) →
  produced TxOut (address+value)? If `GetUTxOByAddress` only, determine
  the available by-outref/by-txin path or the minimal addition. If no
  clean path exists, Q-file with options (don't invent an index).
- Thread the UTxO read into the tx-detail resolution: resolve input
  source address → {scope,role} (reuse #340/#346 resolver) + value.
  Surface on `/v1/tx/{txid}` inputs.
- Tests (hermetic where cq-rdf/indexer involved).

## Slice S2 — graph-effect on the unsigned-tx build path
- On build, emit the resolved+projected graph-effect payload for the
  unsigned ConwayTx via `Cardano.Tx.Graph.Emit` (#340 engine) with inputs
  (S1) + outputs + datums resolved over the cardano-ledger-rdf vocab.
  Add it to the build response (structured JSON the UI renders).
- Golden on a contingency disburse + a swap build.

## Slice S3 — Operate Graph tab (frontend)
- Operate result panel: a **Graph** tab rendering the resolved effect
  (spend→produce, resolved labels, showAda, projected datums). Reuse
  Format + the audit resolution rendering. Thin renderer.
- nix build .#frontend + live dev smoke.

## Proof
Backend: just unit + golden + hermetic checks + nix build .#default.
Frontend: nix build .#frontend + dev smoke on /operate Graph tab.
