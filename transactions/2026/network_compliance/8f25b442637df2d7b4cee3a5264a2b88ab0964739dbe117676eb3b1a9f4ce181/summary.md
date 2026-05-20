# 8f25b442637df2d7b4cee3a5264a2b88ab0964739dbe117676eb3b1a9f4ce181

Historical USDM-funding swap for the network_compliance treasury
(swap-in).

- Submitted: 2026-05-14T09:08:32Z
- Classification: SundaeSwap V3 scoop -> treasury (receives 10053.594390 USDM)
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
