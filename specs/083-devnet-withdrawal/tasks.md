# Tasks: DevNet Withdrawal Slice

**Input**: Design documents from `specs/083-devnet-withdrawal/`
**Issue**: [#83](https://github.com/lambdasistemi/amaru-treasury-tx/issues/83)
**Depends on**: [#82](https://github.com/lambdasistemi/amaru-treasury-tx/issues/82)

## Phase 1: Scope And Process

- [x] T001 Create #83 Spec Kit artifacts.
- [x] T002 Create local PR review state and gate candidate for branch `083-devnet-withdrawal`.
- [x] T003 Review `spec.md`, `plan.md`, and `tasks.md` for cross-artifact consistency before implementation.

## Phase 2: Merged Upstream Dependency

- [ ] T004 Update `cabal.project` and `flake.nix` from the temporary `cardano-node-clients` stack SHA to upstream `main` commit `d6773e4cd8a2421617568c8dac0972b0f312a509`.
- [ ] T005 Update governance docs/state that currently describe upstream readiness as stack-only.
- [ ] T006 Verify dependency refresh with `./llm/reviews/local-080-local-devnet-smoke/gate.sh`.
- [ ] T007 Commit dependency refresh as `build(devnet): pin merged node clients main`.

## Phase 3: Withdrawal Phase Contract

- [ ] T008 [US1] RED: add `withdraw` to the DevNet smoke contract and prove the phase fails before artifacts exist.
- [ ] T009 [US1] Add `withdraw` phase parsing to `scripts/smoke/devnet-local` and `just devnet-smoke`.
- [ ] T010 [US1] Add `withdraw` selector in `test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs`.
- [ ] T011 [US1] Define typed failure records for missing/stale governance prerequisite evidence.

## Phase 4: Live Reward To Intent

- [ ] T012 [US1] Factor the #82 governance setup helper so the withdraw phase can create fresh prerequisite evidence without duplicating governance logic.
- [ ] T013 [US2] RED: assert that `withdraw/intent.json` is missing until the live reward resolver succeeds.
- [ ] T014 [US2] Run `withdraw-wizard` against the live DevNet provider and write `withdraw/intent.json`.
- [ ] T015 [US2] Assert the intent reward account matches governance prerequisite evidence.
- [ ] T016 [US2] Assert `rewardsLovelace > 0` and equals the observed provider reward.

## Phase 5: Intent To Unsigned Build

- [ ] T017 [US3] RED: assert unsigned CBOR/report artifacts are required after intent creation.
- [ ] T018 [US3] Run `tx-build` against the live withdraw intent.
- [ ] T019 [US3] Write `withdraw/tx-body.cbor.hex`, `withdraw/report.json`, and `withdraw/report.md`.
- [ ] T020 [US3] Record tx id/body hash, fee, validity bound, report paths, and upstream dependency SHA in `withdraw/summary.json`.
- [ ] T021 [US3] GREEN: `nix develop --quiet -c just devnet-smoke withdraw` passes and records withdrawal evidence.

## Phase 6: Failure Diagnostics

- [ ] T022 [US1] Cover reward timeout with last observed reward and epoch/tip context.
- [ ] T023 [US2] Cover zero rewards as no-intent/no-success-artifact behavior.
- [ ] T024 [US2] Cover network mismatch before intent writing.
- [ ] T025 [US3] Cover tx-build failure preserving the intent and chain context.

## Phase 7: Documentation And Release Notes

- [ ] T026 [US4] Update `docs/local-devnet-smoke.md` with withdrawal phase usage and artifacts.
- [ ] T027 [US4] Update `README.md` with withdrawal evidence wording.
- [ ] T028 [US4] Update `docs/release.md` and `CHANGELOG.md` with release-note text that distinguishes governance from withdrawal evidence.
- [ ] T029 [US4] Update #83 issue metadata and PR metadata with the verified run directory.
- [ ] T030 [US4] Run the local PR gate and commit docs as `docs(devnet): record withdrawal proof`.

## Dependencies

- Phase 2 must complete before implementation so Amaru consumes the
  merged upstream library state.
- Phase 3 must land before Phase 4 so artifact contracts fail first.
- Phase 4 must complete before Phase 5 because `tx-build` consumes the
  live intent.
- Phase 7 starts only after a successful withdrawal run exists.

## Evidence

- PLAN/TASK GATE: `./llm/reviews/local-083-devnet-withdrawal/gate.sh` passed on 2026-05-13.

## Parallel Notes

- Documentation drafting can run alongside implementation after the
  artifact contract is stable.
- Failure diagnostics should not be split across commits that would
  leave a passing happy path with misleading success artifacts.
