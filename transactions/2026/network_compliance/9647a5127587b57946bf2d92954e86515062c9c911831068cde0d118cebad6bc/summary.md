# 9647a5127587b57946bf2d92954e86515062c9c911831068cde0d118cebad6bc

Historical USDM-funding swap for the network_compliance treasury
(swap-in).

- Submitted: 2026-05-14T15:30:08Z
- Classification: SundaeSwap V3 scoop -> treasury (receives 10043.459658 USDM)
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
