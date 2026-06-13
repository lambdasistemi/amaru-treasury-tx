# Implementation Plan: Pending Co-Signing Page

Issue: #368
Parent: #370
PR: #377

## Current Code Context

- `frontend/src/Store/PendingTx.purs` stores pending unsigned tx entries
  in IndexedDB and exposes `get`, `list`, `put`, `addWitness`,
  `removeWitness`, `supersede`, and `clearAll`.
- `frontend/src/Routing.purs` currently routes `/`, `/audit`,
  `/operate`, and `/books`.
- `frontend/src/Main.purs` dispatches one Halogen root component per
  route.
- `frontend/src/Shell.purs` renders the shared topbar.
- `frontend/src/Api.purs` already defines `GraphEffect`,
  `TxDetailInput`, `TxDetailOutput`, and shared GET wrappers.
- `frontend/dist/style-build.css` owns the `/operate` form, topbar, and
  signer chip styling. The Pending page will extend it with
  `pending-*` classes and reuse `.signers-picker` / `.signer-chip`.
- `frontend/test/playwright/` contains the existing CLI Playwright
  harness. The MCP browser is not used for this ticket.

## Thin-Client Invariant

The browser never parses CBOR, verifies signatures, hashes transaction
bodies, derives txids, or interprets witness bytes. It sends opaque hex
to server endpoints and uses server-returned metadata. Tests must guard
against accidental browser-side decode/crypto by keeping API calls at
the HTTP boundary.

## Rebuild Contract

The merged server route table has mode-specific build endpoints:
`/v1/build/swap`, `/v1/build/disburse`,
`/v1/build/contingency-disburse`, and `/v1/build/reorganize`. There is
no generic `POST /v1/build` endpoint in the current base.

#369 owns writing the real Operate-to-Pending entry. This ticket will
consume an opaque rebuild recipe stored in `entry.intent`:

- `buildEndpoint`: one of the existing mode-specific build endpoints.
- `buildRequest`: the request body to POST to that endpoint.
- optional build metadata: graph-effect, report, or cbor fields the
  page may render in details.

If `entry.intent` does not contain a usable rebuild recipe, the page
shows "rebuild unavailable for this entry" and keeps the old entry
unchanged.

## Slice Breakdown

### Slice 1: Route, Listing, Lanes, Details

Add `PendingPage.purs`, route `/pending`, and topbar navigation. The
page loads `Store.PendingTx.list`, groups active/expired/history
entries, renders signer chips with collected/missing state, and exposes
a detail panel with a witness roster plus optional graph-effect
inputs/outputs.

Proof: a Playwright spec seeds IndexedDB and fails until `/pending`
renders lanes, chips, and details.

### Slice 2: Witness Verification

Add pending-page HTTP helpers and interactions for paste/upload. The
page POSTs to `/v1/verify-witness`, writes successful witnesses through
`Store.PendingTx.addWitness`, refreshes the list, and shows failure
reasons without storing anything.

Proof: Playwright mocks verify-witness success and failure, then reads
IndexedDB to confirm only the successful signer was stored.

### Slice 3: Submit Flow

Gate Submit on complete required witnesses and unexpired status. Submit
calls `/v1/attach`, then `/v1/submit`, displays the returned txid, and
keeps errors visible.

Proof: Playwright proves disabled states for incomplete and expired
entries, then verifies attach-before-submit request bodies and final
txid rendering for a complete active entry.

### Slice 4: Rebuild and Supersede

Implement the Rebuild action using the stored build recipe. On success,
derive the new entry from returned build metadata, link it with
`Store.PendingTx.supersede`, and display the old entry in history. On a
missing recipe or build error, show a reason and leave the store
unchanged.

Proof: Playwright mocks a build endpoint, confirms the new entry exists
with `supersedes = oldTxid`, confirms witness collection is reset, and
confirms legacy entries without a recipe render a rebuild-unavailable
message.

## Owned Files

Implementation slices may edit only:

- `frontend/src/PendingPage.purs`
- `frontend/src/Routing.purs`
- `frontend/src/Main.purs`
- `frontend/src/Shell.purs`
- `frontend/src/Api.purs`
- `frontend/src/Api.js` if an FFI export is required
- `frontend/dist/style-build.css`
- `frontend/test/Test/Main.purs`
- `frontend/test/playwright/playwright.config.ts`
- `frontend/test/playwright/pending-page.spec.ts`
- `frontend/test/playwright/responsive.spec.ts`
- `specs/368-pending-page/tasks.md` only when the orchestrator amends
  accepted task checkboxes into a slice commit

Any wider file set requires a Q-file and updated plan before work
continues.

## Gate

`./gate.sh` is the ticket gate. It runs:

- `git diff --check`
- frontend `spago build`
- frontend `spago test`
- explicit `esbuild src/bootstrap.js` plus `spago bundle --module Main`
- Playwright CLI tests from `frontend/test/playwright`

No Haskell CI gate is required for this frontend-only ticket unless a
slice unexpectedly changes Haskell, which is forbidden by scope.

## Risks

- The page must not assume live server state in Playwright. Mock HTTP at
  the browser boundary and seed IndexedDB directly.
- Slot expiry compares `invalidHereafter` against a current slot. For
  this ticket use server metadata when available; in tests seed a
  deterministic current-slot value or mock `/v1/tip`.
- The stored rebuild recipe is produced by #369 later. This page must
  tolerate entries that lack it.
