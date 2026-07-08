# Issue #456 Tasks

## Bootstrap

- [X] T000 Create PR-local gate and open draft PR.

## Slice 1: Remove Stopgap Tracing

- [X] T456-S1 Remove stopgap helpers and call sites from
  `ChainContext` and `Registry.Verify`.
- [X] T456-S1 Remove now-unused imports from the same modules.
- [X] T456-S1 Run `./gate.sh` and record the result.
- [X] T456-S1 Commit the removal as one bisect-safe commit with
  `Tasks: T456-S1`.
- [ ] T456-S1 Run post-removal live verification and record evidence.
- [ ] T456-S1 Wait for PR #464 GitHub Actions to pass before reporting
  completion.
