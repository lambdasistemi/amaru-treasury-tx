# Tasks: shared tracing severity vocabulary

## Bootstrap

- [X] T000 Create worktree, add PR-local `gate.sh`, push draft PR.

## Slice 1 - trace vocabulary and combinator

- [ ] T452-S1 Add `Amaru.Treasury.Trace` with `Severity`, `traced`, and a
  min-severity filtering surface.
- [ ] T452-S1 Add `Amaru.Treasury.TraceSpec` covering ordering, duration,
  exception logging plus propagation, and severity filtering.
- [ ] T452-S1 Register the new module and test module in
  `amaru-treasury-tx.cabal`.
- [ ] T452-S1 Run `just unit "Trace"` and `./gate.sh`; record any
  environmental dependency failure exactly.
- [ ] T452-S1 Commit one bisect-safe implementation commit with
  `Tasks: T452-S1`.

## Finalization

- [ ] T452-F1 Verify PR body, final gate evidence, task accounting, and commit
  messages.
- [ ] T452-F1 Drop `gate.sh` in the ready-for-review commit.
- [ ] T452-F1 Mark PR ready without merging it.
