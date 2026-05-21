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
| 1 | `attx-191/slice-1-dep-pin` | US2 | `build(deps): bump cardano-tx-tools to v0.2.0.0 + mirror github-release-check companion (#191)` |
| 2a | `attx-191/slice-2a-withdraw-fix` | US1 | `fix(build): repair withdraw Phase-1 construction (#191)` |
| 2b | `attx-191/slice-2b-governance-fix` | US3 | `fix(build): repair governance withdrawal Phase-1 construction (#191)` |
| 2c | `attx-191/slice-2c-report-fix` | US1 | `fix(report): account withdrawal rewards without Phase-1 regressions (#191)` |
| 2 | `attx-191/slice-2-final-phase1` | US1 | `fix(build): validate withdrawal-bearing final transactions (#191)` |
| 4 | orchestrator | metadata/final gate | `docs(pr): record tx-tools bump disposition for #191` |

## Phase 1: Setup

No setup tasks. Branch, draft PR, accepted spec, accepted plan, and
`gate.sh` already exist.

## Phase 2: Slice 1 - Dependency pin and fixed-output hash

**Goal**: Make Cabal and Nix fetch the same audited
`cardano-tx-tools` revision at or past upstream PR #62 and the
upstream-companion `github-release-check` mirror required by that
revision.

**Independent Test**: The old fixed-output hash fails for the new commit
before the hash is regenerated; the corrected hash fetches
`9e77e90728729bdd22e3bfbe0cf7515b33d5ea13`, and the companion
`github-release-check` pin matches upstream `cardano-tx-tools`'s own
`cabal.project`.

**Worker brief**: One bisect-safe commit. Do not push. You are not alone
in the codebase; do not revert edits made by others. Keep this slice to
the dependency pin and hash proof only, including only the approved
upstream-companion mirror required by the pinned `cardano-tx-tools`
commit. Use the `cardano-deps` skill's source-repository-package hash
workflow (`nix flake prefetch github:owner/repo/commit-sha` / nix32
conversion as needed). Commit body must include
`Tasks: T001, T002, T003, T004`.

Owned files:

- `cabal.project`
- `specs/191-bump-tx-tools/spec.md`
- `specs/191-bump-tx-tools/plan.md`
- `specs/191-bump-tx-tools/contracts/dependency-pin.md`
- `specs/191-bump-tx-tools/tasks.md`
- `WIP.md` (ephemeral run log; do not commit)

Forbidden scope:

- `lib/`
- `test/`
- `gate.sh`
- PR metadata
- any dependency other than `cardano-tx-tools` and the approved
  upstream-companion `github-release-check` mirror

Tasks:

- [X] T001 [P] [US2] Verify upstream provenance for `cardano-tx-tools` by recording in `WIP.md` that annotated tag object `d53943d842b740b313b6b67c7784f4308e5847f0` points to commit `9e77e90728729bdd22e3bfbe0cf7515b33d5ea13`, and that commit is a descendant of `6a7a7d424594e8d891dd2b7df5c4e9a7884e6779`.
- [X] T002 [US2] RED: temporarily set only `cabal.project` `cardano-tx-tools` `tag:` to `9e77e90728729bdd22e3bfbe0cf7515b33d5ea13` while leaving the old `--sha256`, then record the expected Nix fixed-output hash failure in `WIP.md`.
- [X] T003 [US2] GREEN: update `cabal.project` so `cardano-tx-tools` uses `tag: 9e77e90728729bdd22e3bfbe0cf7515b33d5ea13` and regenerated nix32 `--sha256: 0vkrnf05jsy3mkc6kvgi5msc8j1a356zvr6sxnxxfwmysqjq5qv4`, and `github-release-check` uses `tag: d90131112a4d6c048d1809adaffdefed92e8e841` plus nix32 `--sha256: 0ad6yi431w8h5i3x9x661b99frcgvd39gm4164y8cx1ihpsjixn3` as the companion mirror exactly matching upstream's `cabal.project`.
- [X] T004 [US2] Run the focused Nix fetch/prefetch proof and `./gate.sh`, record both results in `WIP.md`, and create the single slice commit touching `cabal.project` and the approved artifact amendments.

Checkpoint: `cabal.project` uses the commit SHA, the hash matches, no
unapproved dependency changed, and `./gate.sh` passes at HEAD.

## Phase 3: Slice 2a - Withdraw Phase-1 construction fix

**Goal**: Fix the withdraw builder or fixture gap that the active
withdrawal final Phase-1 path exposes before the shared
`validateFinalPhase1` shortcut is removed.

**Independent Test**: The existing failing example
`Amaru.Treasury.Build.runWithdraw balances the reward withdrawal as value
supplied by the transaction` is investigated from assertion to
production builder, then a focused RED isolates the actual ledger rule
(`PPViewHashesDontMatch`, `ExtraRedeemers (ConwayRewarding 0)`, or
`MissingScriptWitnessesUTXOW`) before GREEN.

**Worker brief**: New driver+navigator pair. One bisect-safe commit. Do
not push. Investigation first: read the failing test, trace the
production builder, write a three-paragraph diagnosis in `WIP.md`, log
`NOTE investigation-complete`, then RED -> GREEN. The navigator vetoes
the RED if it does not isolate the actual failing ledger rule. Commit
body must include `Tasks: T005, T006, T007, T008`.

Owned files:

- `lib/Amaru/Treasury/Build/Withdraw.hs`
- `test/unit/Amaru/Treasury/Build/WithdrawSpec.hs`
- `test/fixtures/withdraw/` files directly implicated by the
  investigation only if the production builder is proven correct
- `amaru-treasury-tx.cabal`
- `WIP.md` (ephemeral run log; do not commit)

Read-only context:

- `test/unit/Amaru/Treasury/BuildSpec.hs`

Forbidden scope:

- `cabal.project`
- `lib/Amaru/Treasury/Build/Common.hs`
- `lib/Amaru/Treasury/Build/GovernanceWithdrawalInit.hs`
- `lib/Amaru/Treasury/Report.hs`
- reorganize modules
- unrelated fixtures
- `specs/`
- `gate.sh`
- PR metadata

Tasks:

- [X] T005 [US1] Investigate the failing `runWithdraw` unit example from `test/unit/Amaru/Treasury/BuildSpec.hs` through `lib/Amaru/Treasury/Build/Withdraw.hs`, identify whether the ledger complaint is caused by script integrity hash computation, a missing reference-input UTxO, or a stray `Rewarding 0` redeemer, record the diagnosis in `WIP.md`, and log `NOTE investigation-complete`.
- [X] T006 [US1] RED: add or update a focused withdraw regression in `test/unit/Amaru/Treasury/Build/WithdrawSpec.hs` with any required `amaru-treasury-tx.cabal` wiring, proving the isolated ledger rule before changing production behavior.
- [X] T007 [US1] GREEN: fix the withdraw builder or, if investigation proves the builder is correct, the incomplete fixture so the withdraw transaction is ledger-valid under active final Phase-1 validation.
- [X] T008 [US1] Run the focused withdraw command plus `./gate.sh`, record RED/GREEN and gate evidence in `WIP.md`, and create the single slice commit.

Checkpoint: the withdraw fixture/build path no longer contributes
residual script-withdrawal final Phase-1 failures, and `./gate.sh`
passes at HEAD for this incremental commit.

## Phase 4: Slice 2b - GovernanceWithdrawalInit Phase-1 construction fix

**Goal**: Fix the governance-withdrawal-init construction or fixture gap
and absorb the original Slice 3 skip disposition into this commit.

**Independent Test**: The existing
`governance materialization conservation` failure is investigated from
assertion to builder. Proposal and materialization fixtures then run
through the bumped active final Phase-1 path. If the motivating residual
rule is resolved, `materializeResultSkipPhase1` is removed.

**Worker brief**: New driver+navigator pair. One bisect-safe commit. Do
not push. Investigation first, then RED -> GREEN. The navigator vetoes
the RED if it does not isolate the actual failing ledger rule. If a
third option appears that affects mainnet correctness and needs security
review, write a Q-file before fixing. Commit body must include
`Tasks: T009, T010, T011, T012`.

Owned files:

- `lib/Amaru/Treasury/Build/GovernanceWithdrawalInit.hs`
- `test/unit/Amaru/Treasury/Build/GovernanceWithdrawalInitSpec.hs`
- `test/golden/Amaru/Treasury/Tx/GovernanceWithdrawalInitWizardMaterializationSpec.hs`
- `test/golden/Amaru/Treasury/Tx/GovernanceWithdrawalInitWizardProposalSpec.hs`
- support fixture files directly implicated by the governance
  investigation only if the production builder is proven correct
- `amaru-treasury-tx.cabal`
- `WIP.md` (ephemeral run log; do not commit)

Forbidden scope:

- `cabal.project`
- `lib/Amaru/Treasury/Build/Common.hs`
- `lib/Amaru/Treasury/Build/Withdraw.hs`
- `lib/Amaru/Treasury/Devnet/GovernanceWithdrawalInit/Core.hs`
- `lib/Amaru/Treasury/Report.hs`
- reorganize modules
- unrelated fixtures
- `specs/`
- `gate.sh`
- PR metadata

Tasks:

- [X] T009 [US3] Investigate `governance materialization conservation` from `test/unit/Amaru/Treasury/Build/GovernanceWithdrawalInitSpec.hs` through `lib/Amaru/Treasury/Build/GovernanceWithdrawalInit.hs`, record the diagnosed ledger rule and root cause in `WIP.md`, and log `NOTE investigation-complete`.
- [X] T010 [US3] RED: add or update focused governance-withdrawal-init unit/golden coverage proving the diagnosed Phase-1 failure before changing production behavior.
- [X] T011 [US3] GREEN: fix the governance-withdrawal-init builder or fixture, and remove `materializeResultSkipPhase1` plus stale comments/call-site skip if its motivating residual rule is resolved.
- [X] T012 [US3] Run focused governance-withdrawal-init unit/golden commands plus `./gate.sh`, record RED/GREEN and disposition evidence in `WIP.md`, and create the single slice commit.

Checkpoint: governance-withdrawal-init no longer depends on the old
Phase-1 skip unless a named residual rule is approved through Q/A, and
`./gate.sh` passes at HEAD.

## Phase 5: Slice 2c - Report withdrawal accounting fix

**Goal**: Fix the report construction or accounting fixture gap exposed
by active validation for withdrawal rewards.

**Independent Test**: The existing
`accounts for withdraw rewards as transaction supply, not wallet spend`
example is investigated from assertion through report construction, then
a focused RED isolates the report bug or fixture gap before GREEN.

**Worker brief**: New driver+navigator pair. One bisect-safe commit. Do
not push. Investigation first, then RED -> GREEN. The navigator vetoes
the RED if it does not isolate the actual failing rule or accounting
contract. Commit body must include `Tasks: T013, T014, T015, T016`.

Owned files:

- `lib/Amaru/Treasury/Report.hs`
- `lib/Amaru/Treasury/Report/Accounting.hs`
- `test/unit/Amaru/Treasury/ReportSpec.hs`
- report or withdraw fixture files directly implicated by the
  investigation only if the production report code is proven correct
- `WIP.md` (ephemeral run log; do not commit)

Forbidden scope:

- `cabal.project`
- `lib/Amaru/Treasury/Build/Common.hs`
- `lib/Amaru/Treasury/Build/Withdraw.hs`
- `lib/Amaru/Treasury/Build/GovernanceWithdrawalInit.hs`
- reorganize modules
- unrelated fixtures
- `specs/`
- `gate.sh`
- PR metadata

Tasks:

- [ ] T013 [US1] Investigate the failing report example from `test/unit/Amaru/Treasury/ReportSpec.hs` through report construction/accounting code, record the diagnosed root cause in `WIP.md`, and log `NOTE investigation-complete`.
- [ ] T014 [US1] RED: add or update focused report coverage that isolates the withdrawal reward accounting regression before changing production behavior.
- [ ] T015 [US1] GREEN: fix the report construction/accounting code or, if investigation proves production code correct, the incomplete fixture so withdrawal rewards remain transaction supply and not wallet spend.
- [ ] T016 [US1] Run focused report tests plus `./gate.sh`, record RED/GREEN and gate evidence in `WIP.md`, and create the single slice commit.

Checkpoint: report accounting no longer contributes a residual
withdrawal final Phase-1 failure, and `./gate.sh` passes at HEAD.

## Phase 6: Slice 2 - Withdrawal-bearing final Phase-1 validation

**Goal**: Remove the shared withdrawal short-circuit last, after 2a, 2b,
and 2c have fixed the builders/fixtures that the active validation path
exposes.

**Independent Test**: A focused regression fails before removing the
short-circuit and passes after `validateFinalPhase1` runs bumped
tx-tools final Phase-1 validation for withdrawal-bearing transactions
with reward accounts seeded, while preserving witness-completeness
filtering.

**Worker brief**: New driver+navigator pair or resumed stashed GREEN
attempt after 2a-2c pass. One bisect-safe commit. Do not push. Write RED
first and observe it failing before changing production code. Commit
body must include `Tasks: T017, T018, T019, T020`.

Owned files:

- `lib/Amaru/Treasury/Build/Common.hs`
- `test/unit/Amaru/Treasury/Build/CommonSpec.hs`
- `amaru-treasury-tx.cabal`
- `WIP.md` (ephemeral run log; do not commit)

Forbidden scope:

- `cabal.project`
- `lib/Amaru/Treasury/Build/Withdraw.hs`
- `lib/Amaru/Treasury/Build/GovernanceWithdrawalInit.hs`
- `lib/Amaru/Treasury/Report.hs`
- reorganize modules
- fixtures except assertion-only changes directly required by the RED
  proof
- `specs/`
- `gate.sh`
- PR metadata

Tasks:

- [ ] T017 [US1] RED: add `test/unit/Amaru/Treasury/Build/CommonSpec.hs` and `amaru-treasury-tx.cabal` test-suite wiring for a withdrawal-bearing final transaction regression that fails while `validateFinalPhase1` returns success solely because withdrawals are present.
- [ ] T018 [US1] RED: in `test/unit/Amaru/Treasury/Build/CommonSpec.hs`, assert the unchanged contract that missing vkey witness failures remain accepted as signing-step noise and non-witness structural ledger failures are rejected.
- [ ] T019 [US1] GREEN: remove the `hasWithdrawals` guard, replace the obsolete reward-state workaround with reward-account seeding through bumped tx-tools as needed, and remove now-unused withdrawal imports/helper from `lib/Amaru/Treasury/Build/Common.hs`.
- [ ] T020 [US1] Run the focused `CommonSpec` command plus `./gate.sh`, record RED and GREEN evidence in `WIP.md`, and create the single slice commit.

Checkpoint: withdrawal-bearing transactions reach the final Phase-1
path, witness-completeness noise is still filtered, non-witness
structural failures are rejected, and `./gate.sh` passes at HEAD.

## Phase 7: Slice 4 - PR metadata and full gate

**Goal**: Make reviewer-facing metadata match the delivered dependency
bump and workaround disposition, then prove the full branch.

**Independent Test**: PR #192 names the selected upstream commit,
version delta, regenerated hash proof, and final disposition of both
downstream workarounds. `nix flake check` and `./gate.sh` pass.

**Orchestrator-owned**. This is not an implementation-worker slice
unless the previous slices reveal a docs/code mismatch requiring a new
behavior commit. Commit body must include `Tasks: T021, T022, T023`.

Owned artifacts:

- PR #192 body at `https://github.com/lambdasistemi/amaru-treasury-tx/pull/192`
- `WIP.md` or `/tmp/epic-189/attx-191/STATUS.md` for verification notes
- no repository file unless a metadata correction requires it

Tasks:

- [ ] T021 Update PR #192 body with old commit `25d7ce349f826e9888fb8565eeb816babb06d922`, selected commit `9e77e90728729bdd22e3bfbe0cf7515b33d5ea13`, target release `v0.2.0.0`, regenerated hash proof, and workaround disposition for 2a/2b/2c plus the final shared validation helper.
- [ ] T022 Run `nix flake check` and record the result in `/tmp/epic-189/attx-191/STATUS.md` or PR #192.
- [ ] T023 Run final `./gate.sh`, record the result in `/tmp/epic-189/attx-191/STATUS.md` or PR #192, and keep PR #192 draft until the parent owner approves finalization.

Checkpoint: PR metadata and verification evidence agree with delivered
behavior. #185 can be unparked only after #191 merges.

## Dependencies and Execution Order

Behavior-changing slices are serial:

```text
Slice 1 -> Slice 2a -> Slice 2b -> Slice 2c -> Slice 2 -> Slice 4
```

Reasons:

- Slices 2a, 2b, and 2c depend on the bumped `cardano-tx-tools`
  validation behavior from Slice 1.
- Slice 2b absorbs the original governance-withdrawal-init skip
  disposition because the same residual Phase-1 rules are exposed by the
  active validation path.
- Final Slice 2 must run last so its shared `validateFinalPhase1`
  change is bisect-safe and `./gate.sh` stays green at HEAD.
- Slice 4 must report the final workaround disposition from 2a/2b/2c and
  the final shared validator behavior.

Within a slice, `[P]` tasks may be explored in parallel only when they
do not edit the same file. The final slice commit must still contain
both RED and GREEN evidence and be bisect-safe.

## Implementation Strategy

1. Complete Slice 1 and accept the dependency pin/hash commit.
2. Complete Slice 2a and accept the withdraw construction/fixture fix.
3. Complete Slice 2b and accept the governance-withdrawal-init
   construction/fixture fix plus skip disposition.
4. Complete Slice 2c and accept the report accounting fix.
5. Complete final Slice 2 and accept the shared final Phase-1 validation
   commit.
6. Complete Slice 4 metadata and full verification.
7. After tasks are complete and reviewed, run finalization audit, drop
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
