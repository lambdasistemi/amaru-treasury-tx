# b5716ae98bb41b53c5fa2ebc6e8d5558879dc86d14fb998333e643095c6b233e

Historical USDM-funding swap for the network_compliance treasury
(swap-out).

- Submitted: 2026-05-13T17:50:11Z
- Classification: treasury -> SundaeSwap V3 order (sends 38856.599 ADA to order escrow)
- Submitter: historical (pre-#172; identity not recorded)

## Files

- `tx.cbor` — the transaction CBOR. Filename (`<txid>/`) is the
  blake2b-256 hash of the canonical encoding of this body.
- `inputs/<parent-txid>.cbor` — each parent tx whose output(s) this
  tx consumes. Same naming/hash invariant. Together with
  `tx.cbor` these CBORs let an auditor reconstruct the consumed
  UTxOs from cryptographically anchored bytes alone.

## Missing

- `intent.json` — the original wizard intent for this swap is not
  recoverable (pre-#172). Only the on-chain CBOR survives.
