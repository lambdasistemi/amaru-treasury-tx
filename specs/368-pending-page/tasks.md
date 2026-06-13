# Tasks: Pending Co-Signing Page

Issue: #368
Parent: #370
PR: #377

## Slice 1 - Route, Listing, Lanes, Details

- [X] T368-S1 Add a RED Playwright CLI test that seeds PendingTx
  IndexedDB entries and expects `/pending` to render active, expired,
  and history lanes.
- [X] T368-S1 Add the `/pending` route through `Routing.purs`,
  `Main.purs`, and `Shell.purs`.
- [X] T368-S1 Add `frontend/src/PendingPage.purs` with store loading,
  lane grouping, signer chips using `.signers-picker` /
  `.signer-chip`, and a detail panel with witness roster plus optional
  inputs/outputs projection.
- [X] T368-S1 Add Pending page CSS in `frontend/dist/style-build.css`.
- [X] T368-S1 Extend the responsive Playwright route matrix to include
  `/pending`.
- [X] T368-S1 Run `./gate.sh`; commit as
  `feat(frontend): add pending page route and listing`
  with `Tasks: T368-S1`.

## Slice 2 - Witness Verification

- [X] T368-S2 Add a RED Playwright CLI test for witness paste/upload
  success and failure, with `/v1/verify-witness` mocked.
- [X] T368-S2 Add pending-page API helpers for `/v1/verify-witness`
  without adding browser-side decode/crypto.
- [X] T368-S2 Wire paste and file upload to verify, store successful
  witnesses with `Store.PendingTx.addWitness`, refresh the entry list,
  and render failure reasons without storing.
- [X] T368-S2 Run `./gate.sh`; commit as
  `feat(frontend): verify pending witnesses`
  with `Tasks: T368-S2`.

## Slice 3 - Attach and Submit

- [X] T368-S3 Add a RED Playwright CLI test for submit disabled states,
  attach request body, submit request body, and returned txid display.
- [X] T368-S3 Add pending-page API helpers for `/v1/attach` and
  `/v1/submit`.
- [X] T368-S3 Enable Submit only when every required signer has a
  stored witness and the entry is not expired.
- [X] T368-S3 Wire Submit to call attach first, submit second, show
  returned txid, and keep errors visible without mutating witnesses.
- [X] T368-S3 Run `./gate.sh`; commit as
  `feat(frontend): submit completed pending transactions`
  with `Tasks: T368-S3`.

## Slice 4 - Rebuild and Supersede

- [ ] T368-S4 Add a RED Playwright CLI test for rebuild success,
  `supersedes` linking, witness reset, and missing-recipe failure.
- [ ] T368-S4 Read an opaque `{ buildEndpoint, buildRequest }` recipe
  from `entry.intent`; do not invent client-side build logic.
- [ ] T368-S4 POST the stored recipe to the existing mode-specific
  build endpoint, build a fresh PendingTx entry from returned metadata,
  and write it via `Store.PendingTx.supersede`.
- [ ] T368-S4 Keep superseded entries visible as history and show a
  rebuild-unavailable reason for entries without a recipe.
- [ ] T368-S4 Run `./gate.sh`; commit as
  `feat(frontend): rebuild pending transactions`
  with `Tasks: T368-S4`.

## Finalization

- [ ] T368-F1 Run final `./gate.sh`.
- [ ] T368-F2 Update PR #377 body with delivered behavior and proof.
- [ ] T368-F3 Run finalization audit for commits and this task file.
- [ ] T368-F4 Drop `gate.sh` in the final
  `chore: drop gate.sh (ready for review)` commit.
- [ ] T368-F5 Mark PR #377 ready for review.
