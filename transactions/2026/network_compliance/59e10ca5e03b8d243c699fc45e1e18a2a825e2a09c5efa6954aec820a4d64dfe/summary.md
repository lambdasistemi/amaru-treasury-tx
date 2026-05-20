# 59e10ca5e03b8d243c699fc45e1e18a2a825e2a09c5efa6954aec820a4d64dfe

Historical USDM-funding swap for the network_compliance treasury
(swap-out).

- Submitted: 2026-05-15T10:07:46Z
- Classification: treasury -> SundaeSwap V3 order (sends 52819.861 ADA to order escrow)
- Submitter: historical (pre-#172; identity not recorded)

## Files

- `tx.cbor` — the transaction CBOR. Filename (`<txid>/`) is the
  blake2b-256 hash of the canonical encoding of this body.
- `inputs/<parent-txid>.cbor` — each parent tx whose output(s) this
  tx consumes. Same naming/hash invariant. Together with
  `tx.cbor` these CBORs let an auditor reconstruct the consumed
  UTxOs from cryptographically anchored bytes alone.

## Recovery

- `intent.json` recovered from
  `/tmp/amaru-treasury-tx-issue-127-all-ada-nc-wallet-minrate-026-20260515-100706/intent.json`
  (lossless copy).
- Match rationale: the intent's `swap.chunkSizeLovelace`
  (52816580941) and `swap.amountLovelace` (52816580941, N=1) equal
  the tx's per-chunk and total ADA-in to the SundaeSwap V3 order
  escrow, and the intent's `swap.rateNumerator` (260000) matches
  the min USDM out encoded in the order datum
  (13732311045 / 52816580941 ≈ 0.260000). The intent's
  `wallet.txIn` and `scope.treasuryUtxos[0]` are both consumed by
  this tx.
