# 22e914892e83c22e19514937914ca32a0c059f9d1c5b555429edde0ea3406ae4

Historical USDM-funding swap for the network_compliance treasury
(swap-out).

- Submitted: 2026-05-14T15:41:26Z
- Classification: treasury -> SundaeSwap V3 order (sends 190601.496 ADA to order escrow)
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
