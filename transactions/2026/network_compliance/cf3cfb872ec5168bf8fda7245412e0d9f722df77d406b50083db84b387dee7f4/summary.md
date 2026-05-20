# cf3cfb872ec5168bf8fda7245412e0d9f722df77d406b50083db84b387dee7f4

Historical USDM-funding swap for the network_compliance treasury
(swap-in).

- Submitted: 2026-05-14T14:38:39Z
- Classification: SundaeSwap V3 scoop -> treasury (receives 10015.854252 USDM)
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
