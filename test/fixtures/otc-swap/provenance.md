# Provenance — OTC swap golden fixtures (issue #499, slice B)

Reference transaction: mainnet
`9ed505b48df617716423f58687283ee5e130684d8b3b6c9f2ed03b473c0154f1`,
block **13868016**, epoch **652** (the protocol parameters in
`pparams.json` are from the same epoch, so the fee model matches).

## Files

- `pparams.json` — mainnet protocol parameters, captured in epoch 652
  (supplied by the ticket owner, `fixtures/otc-golden/pparams.json`).
- `utxos.json` — the frozen UTxO set, built from two sources:
  - **Spent inputs** (3), reconstructed from the parent transactions
    staged by the ticket owner (`fixtures/parent-*.cbor`), all three
    parent txids verified against their filenames:
    - `b98a…#0` ← parent `b98a1633…` output 0 — the treasury UTxO
      (25,644.305641 ADA at the `ops_and_use_cases` treasury address,
      script payment + script stake, both halves `46746c64…`, verified
      against `journal/2026/metadata.json`);
    - `cde5…#0` ← parent `cde5ce7b…` output 0 — the counterparty USDM
      UTxO (1.189560 ADA + 122,662.5 USDM);
    - `c17a…#1` ← parent `c17a1d53…` output 1 — the counterparty's
      pure-ADA UTxO (8,621.195702 ADA), used by the reference as both
      regular input and collateral (counterparty-funded arrangement).
  - **Reference inputs** (4), converted from the live node query
    `fixtures/otc-golden/live-utxos.json` (cardano-cli JSON, including
    the two `PlutusScriptV3` reference scripts that phase-1 needs):
    `11ac…#0` (scopes NFT, inline scope datum), `25ba…#1` (permissions
    script), `660c…#0` (treasury script), `e7b3…#1` (registry NFT,
    inline registry datum).
- `exunits.json` — the on-chain execution units, extracted from the
  reference transaction's own witness set: spending#0 (mem 493,131 /
  steps 166,093,012) and rewarding#0 (mem 237,472 / steps 75,661,060).
  Serving these from the frozen evaluator makes the script-integrity
  hash reproducible; the built body's `scriptIntegrityHash`
  (`77bb6107…`) equals the on-chain one byte-for-byte.
- `reference-body.cbor` — the body of the reference transaction,
  extracted by decoding the full signed transaction and serializing
  the decoded body with the ledger encoder. Round-trip identity was
  proven twice (decode→encode→decode→encode stable, and
  encode(decode(tx)) == tx), so these are the canonical on-chain body
  bytes. **Not** regenerated from builder output; there is no
  `UPDATE_GOLDENS` escape hatch for this file.

## Synthetic data (documented, deliberate)

The restated T-B07 test (operator-funded arrangement) needs an
operator-owned fuel UTxO that no offline fixture can supply (the
reference arrangement was counterparty-funded). `operatorFuelUtxo`
(all-`aa` txid, index 0) and its TxOut (5 ADA at a synthetic key
address, bytes `0122…33`) are **synthesized in the spec** and inserted
into the frozen UTxO map at test time. They test builder properties
(collateral input selection, fee placement), not chain truth.
