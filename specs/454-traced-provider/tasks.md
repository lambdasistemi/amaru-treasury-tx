# Tasks: Provider Boundary Tracing

## Slice 1 - reusable wrappers and unit proof

- [X] T454-S1 Add `Amaru.Treasury.Trace.Provider` with stderr rendering
  plus `tracedProvider`, `tracedQueryHandle`, and `tracedSubmitter`.
- [X] T454-S1 Add unit coverage that invokes every current provider,
  query-handle, and submitter method through the wrappers and asserts
  start plus terminal trace events.
- [X] T454-S1 Add the new module and spec to `amaru-treasury-tx.cabal`.
- [X] T454-S1 Run the focused Trace.Provider unit test command and
  record the result in `WIP.md`.
- [X] T454-S1 Commit with subject
  `feat(tracing): add provider boundary tracing wrappers` and trailer
  `Tasks: T454-S1`.

## Slice 2 - construction-site wiring and final proof

- [X] T454-S2 Apply `tracedProvider stderrTracer` in
  `withLocalNodeBackend` before the backend is handed to callers.
- [X] T454-S2 Apply `tracedProvider stderrTracer` and
  `tracedSubmitter stderrTracer` in `withLocalNodeClient`.
- [X] T454-S2 Ensure API indexer provider construction preserves or
  applies tracing for synthetic direct UTxO and acquired-handle methods.
- [X] T454-S2 Leave `ChainContext.hs`, `Registry/Verify.hs`, wizard
  event modules, and verbosity/config files untouched.
- [X] T454-S2 Run the focused Trace.Provider test command and
  `./gate.sh`, recording both results in `WIP.md`.
- [X] T454-S2 Commit with subject
  `feat(tracing): wire provider tracing at construction sites` and
  trailer `Tasks: T454-S2`.

## Finalization

- [X] T454-F1 Audit commits, task accounting, PR body, and gate output.
- [X] T454-F1 Drop `gate.sh` in the final ready-for-review commit.
- [X] T454-F1 Mark PR #459 ready for review.

## CI correction - lint failure

- [X] T454-LINT Restore `gate.sh` with the same cabal-fmt,
  fourmolu, and hlint coverage as the CI lint derivation.
- [X] T454-LINT Fix the CI hlint hints without adding an
  `Avoid lambda` ignore to `.hlint.yaml`.
- [X] T454-LINT Run local full-tree lint clean through `./gate.sh`.
- [X] T454-F2 Drop `gate.sh` again after proving the lint-aware
  local gate. Push, ready-for-review, and CI pass state are tracked in
  `/tmp/epic-451/amaru-treasury-tx-454/STATUS.md`.
