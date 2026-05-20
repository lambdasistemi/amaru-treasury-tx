# 10a5c1dafe7dd8d4ab680e35dc53b8b550da90bea55f2c758f36474064f2e598

Historical USDM-funding swap for the network_compliance treasury
(swap-out).

- Submitted: 2026-05-13T17:03:53Z
- Classification: treasury -> SundaeSwap V3 order (sends 85.784 ADA to order escrow)
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
