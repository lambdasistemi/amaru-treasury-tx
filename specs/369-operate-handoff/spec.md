# Feature Specification: Operate to Pending Handoff

## Issue

GitHub issue: lambdasistemi/amaru-treasury-tx#369

Parent epic: lambdasistemi/amaru-treasury-tx#370

## P1 User Story

As an operator, after building a transaction on Operate, I click
"Save to pending" and see the unsigned transaction appear on the
Pending page ready to collect witnesses.

## Acceptance Criteria

- Operate's post-build state offers a "Save to pending" action.
- The action introspects the built transaction, or reuses equivalent
  in-band build analysis, and writes a `Store.PendingTx` entry keyed by
  txid.
- The pending entry stores required signers, invalid-hereafter TTL,
  opaque unsigned tx hex, scope, and the build intent as the rebuild
  recipe.
- After saving and navigating to Pending, the entry is shown with zero
  witnesses collected.

## Functional Requirements

- FR-001: Show the save action only when the current Operate result
  contains built CBOR hex.
- FR-002: On click, call `/v1/tx/introspect` through the existing
  `Api.introspectTx` helper for the built CBOR hex.
- FR-003: Persist through `Store.PendingTx.put`; do not decode,
  hash, sign, or verify transaction bytes in the browser.
- FR-004: The persisted `intent` JSON must include
  `buildEndpoint` and `buildRequest` so Pending can use its existing
  rebuild path.
- FR-005: New entries must start with an empty witnesses object.
- FR-006: Surface save progress, success txid, and failure text in the
  Operate post-build panel.
- FR-007: Keep the change localized to Operate handoff wiring and the
  focused frontend proof.

## Non-Goals

- No server endpoint changes.
- No `Store.PendingTx` schema or internals changes.
- No Pending page behavior changes except as exercised by the proof.
- No refactor of unrelated Operate form, preview, books, or routing
  code.

## Success Criteria

- A Playwright proof builds a mocked transaction from Operate, clicks
  "Save to pending", then opens Pending and observes the saved txid
  with zero collected witnesses.
- `./gate.sh` passes at the slice commit.
