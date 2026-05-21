---
description: "Task list for #191 - bump cardano-tx-tools reward-state validation"
---

# Tasks: bump cardano-tx-tools reward-state validation

**Input**: Design documents from `specs/191-bump-tx-tools/`
**Prerequisites**: [spec.md](./spec.md), [plan.md](./plan.md),
[research.md](./research.md), [data-model.md](./data-model.md),
[quickstart.md](./quickstart.md), [contracts/](./contracts/)
**Tests**: Required. Every behavior-changing slice ships RED + GREEN in
one bisect-safe commit.

## Format: `[ID] [P?] [Story?] Description`

- **[P]**: Parallel-safe inside the same slice only. It must not edit the
  same file as another active task.
- **[Story]**: Maps to the user stories in [spec.md](./spec.md).
- Paths are relative to the worktree root unless explicitly absolute.

## Slice and Commit Mapping

| Slice | Worker | Primary story | Commit subject |
|---|---|---|---|
| 1 | `attx-191/slice-1-dep-pin` | US2 | `build(deps): bump cardano-tx-tools reward-state validator (#191)` |
| 2 | `attx-191/slice-2-final-phase1` | US1 | `fix(build): validate withdrawal-bearing final transactions (#191)` |
| 3 | `attx-191/slice-3-gov-init-disposition` | US3 | `fix(build): resolve governance withdrawal init phase1 skip (#191)` |
| 4 | orchestrator | metadata/final gate | `docs(pr): record tx-tools bump disposition for #191` |

## Phase 1: Setup

No setup tasks. Branch, draft PR, accepted spec, accepted plan, and
`gate.sh` already exist.

## Phase 2: Slice 1 - Dependency pin and fixed-output hash

**Goal**: Make Cabal and Nix fetch the same audited
`cardano-tx-tools` revision at or past upstream PR #62.

**Independent Test**: The old fixed-output hash fails for the new commit
before the hash is regenerated; the corrected hash fetches
`9e77e90728729bdd22e3bfbe0cf7515b33d5ea13`.

**Worker brief**: One bisect-safe commit. Do not push. You are not alone
in the codebase; do not revert edits made by others. Keep this slice to
the dependency pin and hash proof only. Use the `cardano-deps` skill's
source-repository-package hash workflow (`nix flake prefetch
github:owner/repo/commit-sha` / nix32 conversion as needed). Commit body
must include `Tasks: T001, T002, T003, T004`.

Owned files:

- `cabal.project`
- `WIP.md` (ephemeral run log; do not commit)

Forbidden scope:

- `lib/`
- `test/`
- `specs/`
- `gate.sh`
- PR metadata
- any dependency other than `cardano-tx-tools`

Tasks:

- [ ] T001 [P] [US2] Verify upstream provenance for `cardano-tx-tools` by recording in `WIP.md` that annotated tag object `d53943d842b740b313b6b67c7784f4308e5847f0` points to commit `9e77e90728729bdd22e3bfbe0cf7515b33d5ea13`, and that commit is a descendant of `6a7a7d424594e8d891dd2b7df5c4e9a7884e6779`.
- [ ] T002 [US2] RED: temporarily set only `cabal.project` `cardano-tx-tools` `tag:` to `9e77e90728729bdd22e3bfbe0cf7515b33d5ea13` while leaving the old `--sha256`, then record the expected Nix fixed-output hash failure in `WIP.md`.
- [ ] T003 [US2] GREEN: update `cabal.project` so `cardano-tx-tools` uses `tag: 9e77e90728729bdd22e3bfbe0cf7515b33d5ea13` and the regenerated nix32 `--sha256` for that exact commit.
- [ ] T004 [US2] Run the focused Nix fetch/prefetch proof and `./gate.sh`, record both results in `WIP.md`, and create the single slice commit touching `cabal.project`.

Checkpoint: `cabal.project` uses the commit SHA, the hash matches, no
other dependency changed, and `./gate.sh` passes at HEAD.

## Phase 3: Slice 2 - Withdrawal-bearing final Phase-1 validation

**Goal**: Remove the shared withdrawal short-circuit so
`validateFinalPhase1` validates every final transaction while preserving
witness-completeness filtering.

**Independent Test**: A focused regression fails before removing the
short-circuit and passes after `validateFinalPhase1` runs
`validatePhase1` for withdrawal-bearing transactions.

**Worker brief**: One bisect-safe commit. Do not push. You are not alone
in the codebase; do not revert edits made by others. Write RED first and
observe it failing before changing production code. Commit body must
include `Tasks: T005, T006, T007, T008`.

Owned files:

- `lib/Amaru/Treasury/Build/Common.hs`
- `test/unit/Amaru/Treasury/Build/CommonSpec.hs`
- `amaru-treasury-tx.cabal`
- `WIP.md` (ephemeral run log; do not commit)

Forbidden scope:

- `cabal.project`
- `lib/Amaru/Treasury/Build/GovernanceWithdrawalInit.hs`
- reorganize modules
- fixtures except assertion-only changes directly required by the RED
  proof
- `specs/`
- `gate.sh`
- PR metadata

Tasks:

- [ ] T005 [US1] RED: add `test/unit/Amaru/Treasury/Build/CommonSpec.hs` and `amaru-treasury-tx.cabal` test-suite wiring for a withdrawal-bearing final transaction regression that fails while `validateFinalPhase1` returns success solely because withdrawals are present.
- [ ] T006 [US1] RED: in `test/unit/Amaru/Treasury/Build/CommonSpec.hs`, assert the unchanged contract that missing vkey witness failures remain accepted as signing-step noise and non-witness structural ledger failures are rejected.
- [ ] T007 [US1] GREEN: remove the `hasWithdrawals` guard, obsolete reward-state workaround docstring, and now-unused withdrawal imports/helper from `lib/Amaru/Treasury/Build/Common.hs`.
- [ ] T008 [US1] Run the focused `CommonSpec` command plus `./gate.sh`, record RED and GREEN evidence in `WIP.md`, and create the single slice commit.

Checkpoint: withdrawal-bearing transactions reach the final Phase-1
path, witness-completeness noise is still filtered, and `./gate.sh`
passes at HEAD.

## Phase 4: Slice 3 - Governance-withdrawal-init disposition

**Goal**: Explicitly resolve the governance-withdrawal-init Phase-1 skip:
remove it if bumped validation passes, or retain only a narrow residual
skip with a named ledger rule and upstream issue.

**Independent Test**: Existing governance-withdrawal-init proposal and
materialization fixtures run through the bumped final Phase-1 validation
path.

**Worker brief**: One bisect-safe commit unless the investigation
discovers a residual rule outside #191's owned boundary. Do not push.
You are not alone in the codebase; do not revert edits made by others.
If a residual non-reward-state ledger rule appears, stop before broad
edits, write a Q-file under
`/tmp/epic-189/attx-191/questions/`, record the blocker in `WIP.md`, and
wait for an orchestrator answer. Commit body must include
`Tasks: T009, T010, T011, T012`.

Owned files:

- `lib/Amaru/Treasury/Build/GovernanceWithdrawalInit.hs`
- `test/unit/Amaru/Treasury/Build/GovernanceWithdrawalInitSpec.hs`
- `test/golden/Amaru/Treasury/Tx/GovernanceWithdrawalInitWizardMaterializationSpec.hs`
- `test/golden/Amaru/Treasury/Tx/GovernanceWithdrawalInitWizardProposalSpec.hs`
- `WIP.md` (ephemeral run log; do not commit)
- `/tmp/epic-189/attx-191/questions/Q-00X-governance-residual-rule.md` only if a residual rule blocks the slice

Forbidden scope:

- `cabal.project`
- `lib/Amaru/Treasury/Build/Common.hs`
- reorganize modules
- `lib/Amaru/Treasury/Devnet/GovernanceWithdrawalInit/Core.hs`
- fixtures except assertion-only changes directly required by this
  disposition
- `specs/`
- `gate.sh`
- PR metadata

Tasks:

- [ ] T009 [US3] RED: run existing governance-withdrawal-init proposal and materialization fixtures after Slice 2 and record in `WIP.md` whether `lib/Amaru/Treasury/Build/GovernanceWithdrawalInit.hs` still needs a Phase-1 skip.
- [ ] T010 [US3] If fixtures pass normal final Phase-1 validation, remove `materializeResultSkipPhase1`, its stale comments, and the proposal call-site skip from `lib/Amaru/Treasury/Build/GovernanceWithdrawalInit.hs`.
- [ ] T011 [US3] If fixtures expose a residual ledger rule, write `/tmp/epic-189/attx-191/questions/Q-00X-governance-residual-rule.md` naming the exact failure and upstream issue before retaining any skip in `lib/Amaru/Treasury/Build/GovernanceWithdrawalInit.hs`.
- [ ] T012 [US3] Run focused governance-withdrawal-init unit/golden commands plus `./gate.sh`, record the selected disposition and GREEN evidence in `WIP.md`, and create the single slice commit.

Checkpoint: the skip is gone, or it is retained only for a named
residual ledger rule approved through Q/A; `./gate.sh` passes at HEAD.

## Phase 5: Slice 4 - PR metadata and full gate

**Goal**: Make reviewer-facing metadata match the delivered dependency
bump and workaround disposition, then prove the full branch.

**Independent Test**: PR #192 names the selected upstream commit,
version delta, regenerated hash proof, and final disposition of both
downstream workarounds. `nix flake check` and `./gate.sh` pass.

**Orchestrator-owned**. This is not an implementation-worker slice
unless the previous slices reveal a docs/code mismatch requiring a new
behavior commit. Commit body must include `Tasks: T013, T014, T015`.

Owned artifacts:

- PR #192 body at `https://github.com/lambdasistemi/amaru-treasury-tx/pull/192`
- `WIP.md` or `/tmp/epic-189/attx-191/STATUS.md` for verification notes
- no repository file unless a metadata correction requires it

Tasks:

- [ ] T013 Update PR #192 body with old commit `25d7ce349f826e9888fb8565eeb816babb06d922`, selected commit `9e77e90728729bdd22e3bfbe0cf7515b33d5ea13`, target release `v0.2.0.0`, regenerated hash proof, and workaround disposition.
- [ ] T014 Run `nix flake check` and record the result in `/tmp/epic-189/attx-191/STATUS.md` or PR #192.
- [ ] T015 Run final `./gate.sh`, record the result in `/tmp/epic-189/attx-191/STATUS.md` or PR #192, and keep PR #192 draft until the parent owner approves finalization.

Checkpoint: PR metadata and verification evidence agree with delivered
behavior. #185 can be unparked only after #191 merges.

## Dependencies and Execution Order

Behavior-changing slices are serial:

```text
Slice 1 -> Slice 2 -> Slice 3 -> Slice 4
```

Reasons:

- Slice 2 depends on the bumped `cardano-tx-tools` validation behavior
  from Slice 1.
- Slice 3 depends on the shared `validateFinalPhase1` behavior from
  Slice 2.
- Slice 4 must report the final workaround disposition from Slice 3.

Within a slice, `[P]` tasks may be explored in parallel only when they
do not edit the same file. The final slice commit must still contain
both RED and GREEN evidence and be bisect-safe.

## Implementation Strategy

1. Complete Slice 1 and accept the dependency pin/hash commit.
2. Complete Slice 2 and accept the shared final Phase-1 validation
   commit.
3. Complete Slice 3 and accept either the skip-removal commit or the
   approved residual-rule commit.
4. Complete Slice 4 metadata and full verification.
5. After tasks are complete and reviewed, run finalization audit, drop
   `gate.sh` in a dedicated final commit, and mark PR #192 ready only
   when authorized.

## Notes

- `gate.sh` remains committed until finalization.
- Implementation workers do not push. The orchestrator reviews the
  returned diff, reruns `./gate.sh`, amends task checkboxes into the
  returned commit, then pushes.
- Workers must not ask the user directly. Questions go through Q-files
  under `/tmp/epic-189/attx-191/questions/`.
- No task may edit reorganize modules or run mainnet/preprod operator
  workflows.
- Existing `ccEvaluateTx` execution-unit checks remain in place and are
  not substitutes for final Phase-1 validation.
