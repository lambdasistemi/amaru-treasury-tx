# Feature specification: long rationale reference URIs

## Problem

The disburse CLI accepts arbitrary reference URIs, but auxiliary-data encoding emits
non-`ipfs://` URIs as one metadatum string. HTTPS gateway links longer than the ledger's
64-byte string cap therefore raise a lazy exception during N2C evaluation and surface as
connection loss.

## Requirements

- Split long non-IPFS URIs into UTF-8-safe chunks of at most 64 bytes.
- Concatenating chunks must reconstruct the exact input URI.
- Preserve one chunk for short URIs.
- Preserve the canonical `["ipfs://", CID]` representation when its CID fits one chunk;
  chunk only an overlong remainder.
- Cover the exact Antithesis Pinata URI with a regression.
- Prove the exact unsigned colleague build five times through a release-shaped AppImage.
- Never sign or submit during verification.

## Acceptance

The repository gate passes and five fresh exact builds each produce non-empty CBOR and a
report against the local mainnet node.
