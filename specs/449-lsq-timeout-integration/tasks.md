# Issue #449 Tasks

## Bootstrap

- [X] T000 Create the isolated issue worktree and baseline `just ci`.
- [X] T001 Create the PR-local gate and open draft PR #465.

## Slice 1: Provisional Downstream Integration

- [X] T449-S1 Pin PR #184 head and its verified nix32 hash in
  `cabal.project`.
- [X] T449-S1 Regenerate `docs/dependencies.md` in deterministic mode.
- [X] T449-S1 Run `./gate.sh` and record the result.
- [X] T449-S1 Commit the provisional integration as one bisect-safe
  commit with `Tasks: T449-S1`.

## Slice 1B: Corrected Provisional Head

- [X] T449-S1B Replace the superseded PR #184 head with its corrected,
  fully green head and independently verified nix32 hash.
- [X] T449-S1B Regenerate `docs/dependencies.md` in deterministic mode.
- [X] T449-S1B Run `./gate.sh` and record the result.
- [X] T449-S1B Commit the corrected provisional integration with
  `Tasks: T449-S1B`.

## Slice 2: Stable Merge Pin

- [X] T449-S2 Confirm upstream PR #184 merged with green CI.
- [X] T449-S2 Pin its stable main commit and independently verified
  nix32 hash.
- [X] T449-S2 Regenerate `docs/dependencies.md` and run `./gate.sh`.
- [X] T449-S2 Commit the stable integration with `Tasks: T449-S2`.
