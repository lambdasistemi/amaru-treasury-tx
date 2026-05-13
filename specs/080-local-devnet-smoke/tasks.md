# Tasks: DevNet Governance Action Slice

**Input**: Design documents from
`specs/080-local-devnet-smoke/`
**Issue**: [#82](https://github.com/lambdasistemi/amaru-treasury-tx/issues/82)
**Follow-ups**: [#83 withdrawal](https://github.com/lambdasistemi/amaru-treasury-tx/issues/83),
[#86 disburse](https://github.com/lambdasistemi/amaru-treasury-tx/issues/86),
[#84 SundaeSwap V3 order build/funding](https://github.com/lambdasistemi/amaru-treasury-tx/issues/84),
[#85 SundaeSwap V3 order spend](https://github.com/lambdasistemi/amaru-treasury-tx/issues/85),
[#87 reorganize](https://github.com/lambdasistemi/amaru-treasury-tx/issues/87)

## Phase 1: Scope And Tracking

- [x] T001 Create the governance DevNet issue #82.
- [x] T002 Create the withdrawal DevNet follow-up issue #83.
- [x] T003 Create the disburse DevNet follow-up issue #86.
- [x] T004 Create the SundaeSwap V3 order build/funding DevNet follow-up issue #84.
- [x] T005 Create the SundaeSwap V3 order spend DevNet follow-up issue #85.
- [x] T006 Create the reorganize DevNet follow-up issue #87.
- [x] T007 Add #82, #83, #86, #84, #85, and #87 to the Work backlog.
- [x] T008 Narrow `specs/080-local-devnet-smoke/` to the governance action slice.
- [x] T009 Update PR metadata once a PR exists for branch `080-local-devnet-smoke`.

## Phase 2: Preserve The Node Boundary

- [x] T010 Keep local-only `devnet` network identity support.
- [x] T011 Keep `test/devnet` and `scripts/smoke/devnet-local` out of default `just ci`.
- [x] T012 Keep `just devnet-smoke node` as the node-readiness proof.
- [x] T013 Re-run `nix develop --quiet -c cabal test devnet-tests -O0 --test-show-details=direct --test-option=--match --test-option node`.
- [x] T014 Re-run `nix develop --quiet -c just devnet-smoke node`.

## Phase 3: Process Gate And Upstream Stack

- [x] T015 Write the local solo PR state file in `llm/reviews/local-080-local-devnet-smoke/state.md`.
- [x] T016 Write the local gate script in `llm/reviews/local-080-local-devnet-smoke/gate.sh`.
- [x] T017 Review `specs/080-local-devnet-smoke/spec.md`, `plan.md`, and `tasks.md` for cross-artifact consistency before implementation resumes.
- [x] T018 Verify current `cardano-node-clients` #137 head, base, draft state, and PR body through `gh pr view 137 --repo lambdasistemi/cardano-node-clients`.
- [x] T019 Record in #82/PR metadata that Amaru may prove direction against #135 + #137 draft heads, but release readiness depends on the upstream stack being accepted or explicitly pinned.

## Phase 4: Vertical Slice 1 - Upstream Pin And Provider API

- [x] T020 [US2] RED: pin only `cabal.project`/`flake.nix` to the current #137 head and run `nix develop --quiet -c cabal test unit-tests -O0 --test-show-details=direct --test-option=--match --test-option /Registry.Verify/`, expecting the expanded `Provider` record to expose missing local stubs.
- [x] T021 [US2] GREEN: update local `Provider` stubs in `test/unit/Amaru/Treasury/Registry/VerifySpec.hs` for #137 fields without changing resolver behavior.
- [x] T022 [US2] Verify slice 1 with `nix develop --quiet -c cabal test unit-tests -O0 --test-show-details=direct --test-option=--match --test-option "Amaru.Treasury.Registry.Verify"`.
- [x] T023 [US2] Commit slice 1 as `build(devnet): pin governance provider stack`.

## Phase 5: Vertical Slice 2 - Reward Query Boundary

- [x] T024 [US2] RED: add a focused unit regression proving reward-account lookup treats absent rows as zero through a `Provider` reward-account query path.
- [x] T025 [US2] GREEN: remove the direct `queryLSQ` reward helper from `lib/Amaru/Treasury/Backend/N2C.hs` and route withdraw reward resolution through #137 `Provider.queryRewardAccounts`.
- [x] T026 [US2] Verify slice 2 with `nix develop --quiet -c cabal test unit-tests -O0 --test-show-details=direct --test-option=--match --test-option "Amaru.Treasury.Tx.WithdrawWizard"`.
- [x] T027 [US2] Commit slice 2 as `feat(withdraw): use provider reward queries`.

## Phase 6: Vertical Slice 3 - Governance DevNet Smoke

- [x] T028 Add a failing `governance` phase contract test in `test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs`.
- [x] T029 Add `governance` to `scripts/smoke/devnet-local` and the `just devnet-smoke` phase contract.
- [x] T030 [US2] RED: run `nix develop --quiet -c just devnet-smoke governance` and capture the current blocker or missing success-artifact failure.
- [x] T031 [US2] Prepare deterministic short-epoch DevNet protocol treasury/reserve state for a treasury-withdrawal governance action in `test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs`.
- [x] T032 [US2] Register the Amaru treasury script stake credential with registration plus always-abstain vote delegation in the DevNet smoke harness.
- [x] T033 [US2] Build, sign inside the harness, and submit the treasury-withdrawal governance action through `cardano-node-clients` #135/#137 support.
- [x] T034 [US2] Observe the governance action boundary and funded reward-account state through supported `Provider` queries.
- [x] T035 [US2] Write `governance/action.json`, `governance/certificates.json`, and summary evidence in the run directory.
- [x] T036 [US2] GREEN: run `nix develop --quiet -c just devnet-smoke governance` and capture tx id, action id, reward account, amount, and epoch/tip context.
- [x] T037 [US2] Commit slice 3 as `test(devnet): prove governance reward funding`.

Evidence:

- RED: `nix develop --quiet -c just devnet-smoke governance` failed on the old typed blocker `MISSING_UPSTREAM_GOVERNANCE_SUPPORT`.
- GREEN: `./llm/reviews/local-080-local-devnet-smoke/gate.sh` passed with #137 head `c46b95a86c9155db414f519fcd6c75e5b310b23e`, run directory `runs/devnet/20260513T090626Z`, governance tx `d5bf03b2517ff8c2a7d3259e60b33c4d69b84a6ffb97e9dd6eee00beb685554e`, action index `0`, treasury script reward account `5fbb3e5295c211c7595ddd23db2e0a0833131e0681cc7ea800f85d34`, and reward balance `0 -> 2000000` lovelace across epochs `2 -> 4`.

## Phase 7: Vertical Slice 4 - Documentation And Release Notes

- [x] T038 [US3] Update `docs/local-devnet-smoke.md` after the governance proof lands.
- [x] T039 [US3] Update `README.md` after the governance proof lands.
- [x] T040 [US3] Update `docs/release.md` with release-note wording that distinguishes governance proof from withdrawal, disburse, swap-order, swap-spend, and reorganize evidence.
- [x] T041 [US3] Update PR/issue metadata for #82 with the verified command outputs and upstream stack SHAs.
- [x] T042 [US3] Verify slice 4 with `nix develop --quiet -c just ci`.
- [x] T043 [US3] Commit slice 4 as `docs(devnet): record governance proof`.

## Dependencies

- Phase 2 is already mostly complete and remains the baseline for all
  later work.
- Phase 3 is the process gate and must complete before more code
  changes are committed.
- Phase 4 must be committed before Phase 5 because Phase 5 depends on
  the #137 `Provider` API compiling locally.
- Phase 5 must be committed before Phase 6 because the governance smoke
  observes rewards through the same provider boundary used by withdraw.
- #83 starts after #82 produces funded reward-account evidence or an
  accepted mock/fixture substitute for local-only development.
- #86 starts after the DevNet harness and treasury funding assumptions
  are stable enough to exercise live disburse state.
- #84 starts after the DevNet harness and funding assumptions are
  stable enough to exercise live SundaeSwap V3 order-build state.
- #85 starts after #84 produces a funded V3-compatible order artifact.
- #87 starts after earlier slices or local setup can provide multiple
  treasury UTxOs, and after #46 provides the release-facing builder.
