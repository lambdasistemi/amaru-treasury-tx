# f2791967f99ac04b33da17bd9c848b673c690a40d647b1e21e2651ff7a2f4657

Historical USDM-funding swap for the network_compliance treasury
(swap-out).

- Submitted: 2026-05-14T08:51:38Z
- Classification: treasury -> SundaeSwap V3 order (sends 79230.169 ADA to order escrow)
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
