# Tasks: Indexer-Backed Serve API

## Slice 1 — Transaction Detail

- [X] T248-S1 Add `GET /v1/tx/{txid}` to the Servant API and handler record.
- [X] T248-S1 Reuse the CLI tx-detail query/render path to build JSON detail.
- [X] T248-S1 Cover route success, malformed txid, and missing txid behavior.
- [X] T248-S1 Run the focused unit gate and commit the slice.

## Slice 2 — State Reads

- [ ] T248-S2 Add scope state, scope UTxO, pending, registry, and scripts carriers.
- [ ] T248-S2 Wire handlers from metadata and the indexer-backed provider.
- [ ] T248-S2 Cover route shapes and indexer-backed behavior in unit tests.
- [ ] T248-S2 Run the relevant gate and commit the slice.

## Slice 3 — Tip, Params, Submit, Health

- [ ] T248-S3 Add tip, params, submit, and health carriers/routes.
- [ ] T248-S3 Wire tip/params/submit to the node boundary and health to readiness.
- [ ] T248-S3 Cover route shapes and submit outcome rendering in unit tests.
- [ ] T248-S3 Run the relevant gate and commit the slice.

## Slice 4 — Serve Config Decision

- [ ] T248-S4 Resolve whether this PR must add `amaru-treasury-tx serve --config`.
- [ ] T248-S4 If required, add the delegating CLI surface and tests.
- [ ] T248-S4 Run the final build/unit/Nix gate.
