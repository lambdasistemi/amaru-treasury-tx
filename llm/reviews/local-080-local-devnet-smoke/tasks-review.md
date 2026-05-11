# Tasks Review: Local Devnet Smoke

## Verdict

Approved for implementation in solo PR mode.

## Evidence

- Tasks map to the approved plan and the three prioritized user
  stories.
- Every behavior-changing phase names RED/regression proof and GREEN
  implementation tasks.
- The task file now states how red tasks fold into reviewed,
  bisect-safe commits instead of landing as broken standalone commits.
- Live boundary checks are represented by `devnet-tests` and
  `just devnet-smoke node`.
- Documentation/release tasks are separate, with command-contract docs
  required to travel with behavior changes when applicable.

## Conditions

- The first code commit must include both tests and implementation for
  the chosen slice.
- If reward or treasury-state setup expands beyond the current plan,
  split it only into reviewer-approved vertical slices with typed
  failure modes.
