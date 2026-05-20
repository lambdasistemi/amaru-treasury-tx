# 856e3d0eeacfd9b4ec5f36445f7bd9122789aead0a2de5fd8a8086413d52f80f

Historical USDM-funding swap for the network_compliance treasury
(swap-in).

- Submitted: 2026-05-14T10:38:06Z
- Classification: SundaeSwap V3 scoop -> treasury (receives 10044.827142 USDM)
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
