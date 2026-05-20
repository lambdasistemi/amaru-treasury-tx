# 432eef5e39adcb65adbd9df5f8563701bdd4ef7a95a0d361fb2f9307b8dc601a

Historical USDM-funding swap for the network_compliance treasury
(swap-in).

- Submitted: 2026-05-14T17:02:36Z
- Classification: SundaeSwap V3 scoop -> treasury (receives 10044.146632 USDM)
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
