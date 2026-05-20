# bde8ee921e26480a389ca338ac3fcdfb128bd7491ca4314c79fe07b115f87ffa

Historical USDM-funding swap for the network_compliance treasury
(swap-in).

- Submitted: 2026-05-14T10:36:11Z
- Classification: SundaeSwap V3 scoop -> treasury (receives 10055.289475 USDM)
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
