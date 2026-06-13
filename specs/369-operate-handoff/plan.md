# Implementation Plan: Operate to Pending Handoff

## Scope

This is a minimal frontend-only handoff. Operate already has the
current build request, endpoint choice, built CBOR hex helpers, and
the existing `Api.introspectTx` client. Pending already reads
`Store.PendingTx` and knows how to rebuild from
`{ buildEndpoint, buildRequest }` inside the entry `intent`.

## Data Shape

The Operate save action writes:

```json
{
  "txid": "<introspected txid>",
  "intent": {
    "kind": "<mode>",
    "buildEndpoint": "/v1/build/...",
    "buildRequest": { "...": "current Operate request JSON" }
  },
  "unsignedTxHex": "<built cbor hex>",
  "scope": "<introspected scope or current Operate scope>",
  "requiredSigners": ["<key hash>"],
  "invalidHereafter": "<ttl or null>",
  "witnesses": {},
  "savedAt": "<timestamp>",
  "supersedes": null
}
```

The browser treats CBOR and witness data as opaque strings.

## Slice Plan

### Slice 1 - Save Built Operate Tx To Pending

Owned files:

- `frontend/src/OperatePage.purs`
- `frontend/test/playwright/pending-page.spec.ts`

Work:

- Add an Operate action/state field for pending-save status.
- Add a localized button/status panel near the built CBOR/post-build
  preview.
- Derive the build endpoint from the current `TxMode` and scope using
  the same dispatch rules as `RunBuild`.
- Build the pending `intent` as a small wrapper around the current
  `requestJson` and endpoint.
- Call `Api.introspectTx` for the built CBOR hex, then
  `Store.PendingTx.put` with empty witnesses.
- Add a Playwright proof that mocks build and introspect responses,
  saves from Operate, navigates to Pending, and verifies zero
  collected witnesses.

## Verification

The slice must follow RED then GREEN:

- RED: focused Playwright test fails before Operate has the
  "Save to pending" action.
- GREEN: focused Playwright test passes.
- Gate: `./gate.sh` passes, including PureScript test, local esbuild
  bundle, Nix frontend bundle check, and Playwright CLI suite.

## Constraints

- Do not edit server Haskell code.
- Do not edit `Store.PendingTx` internals.
- Do not refactor unrelated Operate code.
- Do not widen the frontend dependency surface.
