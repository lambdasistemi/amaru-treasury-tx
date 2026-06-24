# Tasks: Operate UI Re-rate Mode

## Bootstrap

- [X] T402-B0 Create branch/worktree and draft PR.
- [X] T402-B1 Add initial PR-local `gate.sh`.

## Slice 0: Extend Gate

- [X] T402-S0 Extend `gate.sh` to build `.#frontend`.
- [X] T402-S0 Add the ticket-specific Re-rate Playwright command to
  `gate.sh` once the spec path exists.
- [X] T402-S0 Commit as `chore: extend gate.sh for rerate UI`.

## Slice 1: API and Pure Tests

- [X] T402-S1 Add `/v1/build/swap-rerate` to `Api.buildCborField`.
- [X] T402-S1 Add PureScript types and client call for
  `/v1/pending?scope=<scope>`.
- [X] T402-S1 Add/adjust exported pure helpers for Re-rate outrefs,
  request JSON, split summary, and empty state.
- [X] T402-S1 Cover orders-present, over-budget split, and no-orders
  classification in `frontend/test/Test/Main.purs`.
- [X] T402-S1 Commit as `feat(frontend): add rerate API model`.

## Slice 2: Re-rate Operate Mode

- [ ] T402-S2 Add `ModeRerate` and the `Re-rate` mode selector segment.
- [ ] T402-S2 Add Re-rate state, actions, validation, draft
  serialization, request JSON, endpoint, and response prefix handling.
- [ ] T402-S2 Fetch pending orders for the selected scope and render
  per-order retract selection plus empty state.
- [ ] T402-S2 Render single-tx vs split decision/reason in the existing
  preview/status surface.
- [ ] T402-S2 Commit as `feat(frontend): add rerate operate mode`.

## Slice 3: Browser Proof and Screenshot

- [ ] T402-S3 Add Playwright Re-rate mode spec with mocked pending,
  build single/split, and empty-state responses.
- [ ] T402-S3 Capture and commit a working Re-rate screenshot under
  `frontend/test/ui-review/402/`.
- [ ] T402-S3 Run `./gate.sh` and record the proof.
- [ ] T402-S3 Commit as `test(frontend): cover rerate operate mode`.

## Finalization

- [ ] T402-F1 Update PR body with delivered behavior and verification.
- [ ] T402-F2 Run final `./gate.sh`.
- [ ] T402-F3 Drop `gate.sh` before marking the PR ready.
