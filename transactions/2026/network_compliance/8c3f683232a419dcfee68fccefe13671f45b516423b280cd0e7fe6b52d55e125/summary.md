# 8c3f683232a419dcfee68fccefe13671f45b516423b280cd0e7fe6b52d55e125

Historical USDM-funding swap for the network_compliance treasury
(swap-in).

- Submitted: 2026-05-14T14:25:19Z
- Classification: SundaeSwap V3 scoop -> treasury (receives 10126.528898 USDM)
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
