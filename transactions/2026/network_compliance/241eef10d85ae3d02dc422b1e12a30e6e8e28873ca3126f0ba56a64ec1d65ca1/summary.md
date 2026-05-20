# 241eef10d85ae3d02dc422b1e12a30e6e8e28873ca3126f0ba56a64ec1d65ca1

Historical USDM-funding swap for the network_compliance treasury
(swap-in).

- Submitted: 2026-05-14T15:26:32Z
- Classification: SundaeSwap V3 scoop -> treasury (receives 10033.428863 USDM)
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
