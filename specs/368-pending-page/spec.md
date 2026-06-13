# Feature Spec: Pending Co-Signing Page

Issue: #368
Parent: #370
PR: #377

## P1 User Story

As an operator, I open the Pending page, paste a co-signer witness onto
a stored unsigned transaction, watch signer progress fill in, and click
Submit once every required signer is present and the transaction has not
expired.

## Scope

This feature adds a `/pending` frontend route that ties together the
browser-local `Store.PendingTx` module from #367 and the stateless API
endpoints from #365 and #366. The page stays a thin client: it stores
opaque unsigned transaction hex, opaque witness hex, and metadata the
server already returned. It never decodes CBOR, hashes transactions,
verifies signatures, or derives signer sets in the browser.

## Non-Goals

- No server Haskell changes.
- No `Store.PendingTx` schema or FFI changes.
- No Operate page handoff; #369 writes new Pending entries from a
  successful Operate build.
- No `transactions/` archive workflow.
- No browser-side crypto, CBOR decoding, or ledger validation.

## Functional Requirements

- **FR-001 Route**: The app MUST expose `/pending`, route to a new
  `PendingPage` Halogen component, and show a topbar nav item labelled
  `Pending`.
- **FR-002 Listing**: The page MUST load `Store.PendingTx.list` and
  render every stored entry grouped into active, expired, and
  superseded/history lanes.
- **FR-003 Signer Progress**: Each entry MUST show signer chips for
  every `requiredSigners` value. The chips MUST reuse the existing
  `.signers-picker` / `.signer-chip` styling from `signersPicker` and
  distinguish collected vs missing witnesses.
- **FR-004 Witness Paste/Upload**: The page MUST accept pasted text and
  file upload witness hex for a selected entry, POST
  `{ unsignedTx, witness }` to `/v1/verify-witness`, store the witness
  with `Store.PendingTx.addWitness` only when the response is
  `{ ok: true, signerKeyHash }`, and show `reason` without storing
  anything when the response is not ok or the HTTP request fails.
- **FR-005 Expiry Gate**: Entries whose `invalidHereafter` slot is in
  the past MUST render in an expired lane with a rebuild hint and MUST
  NOT render an enabled submit button.
- **FR-006 Submit Gate**: An active entry's Submit button MUST be
  enabled only when every required signer has a stored witness and the
  entry is not expired.
- **FR-007 Submit Flow**: Clicking Submit MUST call `/v1/attach` with
  `{ unsignedTx, witnesses }`, then call `/v1/submit` with the returned
  signed `{ cborHex }`, and display the returned `{ txid }`. Attach or
  submit errors MUST be shown and MUST NOT mutate the stored witnesses.
- **FR-008 Detail View**: A detail view MUST show the entry's
  inputs/outputs projection when the stored build analysis includes a
  graph-effect shape matching `Api.GraphEffect`, and MUST always show a
  witness roster of required, collected, and missing signers.
- **FR-009 Rebuild**: A Rebuild action MUST use the opaque build recipe
  stored in `entry.intent` to POST the recipe body to its stored
  mode-specific build endpoint, write the resulting new entry with
  `Store.PendingTx.supersede`, and restart witness collection on the
  new transaction. If a seeded entry has no rebuild recipe, the page
  MUST show a rebuild-unavailable reason instead of making up a server
  call.
- **FR-010 History**: Superseded entries MUST remain visible as history
  with their `supersedes` relationship displayed.

## Wire Shapes

The page consumes the merged server shapes as data:

- `POST /v1/verify-witness`
  request: `{ unsignedTx :: String, witness :: String }`
  response: `{ ok :: Boolean, signerKeyHash :: Maybe String, reason :: Maybe String }`
- `POST /v1/attach`
  request: `{ unsignedTx :: String, witnesses :: Array String }`
  response: `{ cborHex :: String }`
- `POST /v1/submit`
  request: `{ cborHex :: String }`
  response: `{ txid :: String }`

For rebuild, #369 owns writing the real Operate handoff. This page only
requires that `entry.intent` contain an opaque rebuild recipe with:

```json
{
  "buildEndpoint": "/v1/build/swap",
  "buildRequest": { "...": "the existing Operate build request body" }
}
```

The Pending page may also read server-returned build metadata from
`entry.intent` when present, such as graph-effect, report, or cbor
fields. Missing optional metadata degrades the detail view; it must not
block witness collection or submit.

## Acceptance Criteria Mapping

- A new route lists store entries with signer chips:
  FR-001, FR-002, FR-003.
- Paste/upload witness verifies through `/v1/verify-witness` and stores
  only successful witnesses:
  FR-004.
- Expired entries render in an expired lane with rebuild hint:
  FR-005.
- Submit is complete-and-unexpired gated and calls attach then submit:
  FR-006, FR-007.
- Detail view shows projection and witness roster:
  FR-008.
- Rebuild from stored build recipe links a new entry via `supersedes`:
  FR-009, FR-010.

## Success Criteria

- `./gate.sh` passes at HEAD.
- Playwright CLI tests seed IndexedDB, mock HTTP at the browser boundary,
  and prove the page flows for list/detail, witness success/failure,
  submit gating, expiry, and rebuild/supersede.
- `spago build`, `spago test`, and explicit `esbuild` bundle are covered
  by `./gate.sh`.
