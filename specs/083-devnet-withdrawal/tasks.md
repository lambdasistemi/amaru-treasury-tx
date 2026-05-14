# Tasks: DevNet Withdrawal Slice

**Input**: Design documents from `specs/083-devnet-withdrawal/`
**Issue**: [#83](https://github.com/lambdasistemi/amaru-treasury-tx/issues/83)
**Depends on**: [#82](https://github.com/lambdasistemi/amaru-treasury-tx/issues/82)

## Phase 1: Scope And Process

- [x] T001 Create #83 Spec Kit artifacts.
- [x] T002 Create local PR review state and gate candidate for branch `083-devnet-withdrawal`.
- [x] T003 Review `spec.md`, `plan.md`, and `tasks.md` for cross-artifact consistency before implementation.

## Phase 2: Merged Upstream Dependency

- [x] T004 Update `cabal.project` and `flake.nix` from the temporary `cardano-node-clients` stack SHA to upstream `main` commit `d6773e4cd8a2421617568c8dac0972b0f312a509`.
- [x] T005 Update governance docs/state that currently describe upstream readiness as stack-only.
- [x] T006 Verify dependency refresh with `./llm/reviews/local-080-local-devnet-smoke/gate.sh`.
- [x] T007 Commit dependency refresh as `build(devnet): pin merged node clients main`.

## Phase 3: Withdrawal Phase Contract

- [x] T008 [US1] RED: add `withdraw` to the DevNet smoke contract and prove the phase fails before artifacts exist.
- [x] T009 [US1] Add `withdraw` phase parsing to `scripts/smoke/devnet-local` and `just devnet-smoke`.
- [x] T010 [US1] Add `withdraw` selector in `test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs`.
- [x] T011 [US1] Define typed failure records for missing/stale governance prerequisite evidence.

## Phase 4: Live Reward To Intent

- [x] T012 [US1] Factor the #82 governance setup helper so the withdraw phase can create fresh prerequisite evidence without duplicating governance logic.
- [x] T013 [US2] RED: assert that `withdraw/intent.json` is missing until the live reward resolver succeeds.
- [x] T014 [US2] Run `withdraw-wizard` against the live DevNet provider and write `withdraw/intent.json`.
- [x] T015 [US2] Assert the intent reward account matches governance prerequisite evidence.
- [x] T016 [US2] Assert `rewardsLovelace > 0` and equals the observed provider reward.

## Phase 5: Intent To Unsigned Build

- [x] T017 [US3] RED: assert unsigned CBOR/report artifacts are required after intent creation.
- [x] T018 [US3] Run `tx-build` against the live withdraw intent.
- [x] T019 [US3] Write `withdraw/tx-body.cbor.hex`, `withdraw/report.json`, and `withdraw/report.md`.
- [x] T020 [US3] Record tx id/body hash, fee, validity bound, report paths, and upstream dependency SHA in `withdraw/summary.json`.
- [x] T021 [US3] GREEN: `nix develop --quiet -c just devnet-smoke withdraw` passes and records withdrawal evidence.

## Phase 6: Failure Diagnostics

- [x] T022 [US1] Cover reward timeout with last observed reward and epoch/tip context.
- [x] T023 [US2] Cover zero rewards as no-intent/no-success-artifact behavior.
- [x] T024 [US2] Cover network mismatch before intent writing.
- [x] T025 [US3] Cover tx-build failure preserving the intent and chain context.

## Phase 7: Documentation And Release Notes

- [x] T026 [US4] Update `docs/local-devnet-smoke.md` with withdrawal phase usage and artifacts.
- [x] T027 [US4] Update `README.md` with withdrawal evidence wording.
- [x] T028 [US4] Update `docs/release.md` and `CHANGELOG.md` with release-note text that distinguishes governance from withdrawal evidence.
- [x] T029 [US4] Update #83 issue metadata and PR metadata with the verified run directory.
- [x] T030 [US4] Run the local PR gate and commit docs as `docs(devnet): record withdrawal proof`.

## Dependencies

- Phase 2 must complete before implementation so Amaru consumes the
  merged upstream library state.
- Phase 3 must land before Phase 4 so artifact contracts fail first.
- Phase 4 is complete: the smoke creates live governance prerequisite
  evidence, observes positive rewards, and writes the withdraw intent.
- Phase 5 is complete: `tx-build` consumes the live intent and writes
  unsigned CBOR plus JSON/Markdown reports.
- Phase 6 is complete: typed diagnostics cover reward timeout, zero
  rewards, network mismatch, and tx-build failure artifact handling.
- Phase 7 starts only after a successful withdrawal run exists.

## Evidence

- PLAN/TASK GATE: `./llm/reviews/local-083-devnet-withdrawal/gate.sh` passed on 2026-05-13.
- PIN RED/GREEN: current docs/pin referenced the temporary stack SHA; Cabal/Nix now pin `cardano-node-clients` main `d6773e4cd8a2421617568c8dac0972b0f312a509`.
- PIN GREEN: `./llm/reviews/local-080-local-devnet-smoke/gate.sh` passed after the pin with run directory `runs/devnet/20260513T143827Z`, governance tx `d5bf03b2517ff8c2a7d3259e60b33c4d69b84a6ffb97e9dd6eee00beb685554e`, action index `0`, and reward balance `0 -> 2000000` lovelace.
- PR GATE: `./llm/reviews/local-083-devnet-withdrawal/gate.sh` passed after the pin.
- WITHDRAW CONTRACT RED: before the slice, `nix develop --quiet -c just devnet-smoke withdraw` failed with `devnet-smoke: unknown phase: withdraw`.
- WITHDRAW CONTRACT GREEN: after the slice, `scripts/smoke/devnet-local --phase withdraw --run-dir <tmp>` fails with typed code `missing-governance-prerequisite`, writes `<tmp>/withdraw/failure.json` and `<tmp>/withdraw/summary.json`, and writes no `withdraw/intent.json` or `withdraw/tx-body.cbor.hex`.
- WITHDRAW INTENT RED: before the live reward-to-intent slice, `scripts/smoke/devnet-local --phase withdraw --run-dir <tmp>` stopped at `missing-governance-prerequisite` and wrote no `withdraw/intent.json`.
- WITHDRAW INTENT GREEN / BUILD RED: `scripts/smoke/devnet-local --phase withdraw --run-dir /tmp/tmp.ceKml45iYu/withdraw` exits 1 at the expected `missing-withdrawal-build-artifacts` boundary after writing `withdraw/intent.json`; the intent records reward account `ffbb1bb8f19e6ee2357b899043b7337525c072f968a68c8aaf01b2af`, `rewardsLovelace = 2000000`, and live local registry anchors for scopes, permissions, treasury, and registry reference UTxOs.
- WITHDRAW BUILD BOUNDARY: the same run writes `withdraw/failure.json` with `intentPath`, `governanceSummaryPath`, `txBodyPath`, report paths, and `lastObservedRewardLovelace = 2000000`; no unsigned tx body exists yet.
- GOVERNANCE REGRESSION: `scripts/smoke/devnet-local --phase governance --run-dir /tmp/tmp.KwjKGXJyC7/governance` exits 0; it funds the pinned governance reward account `5fbb3e5295c211c7595ddd23db2e0a0833131e0681cc7ea800f85d34` from `0` to `2000000` lovelace across epochs `2 -> 4`.
- PR GATE AFTER INTENT SLICE: `./llm/reviews/local-083-devnet-withdrawal/gate.sh` passed on 2026-05-14 after the live reward-to-intent code, docs, and review-state updates.
- STACK REBASE: PR #93 and #100 were rebased onto `origin/main` `cd6a7612cb2abfc566da366ace0199578e3aaa90` on 2026-05-14; `./llm/reviews/local-083-devnet-withdrawal/gate.sh` passed after the rebase.
- WITHDRAW BUILD RED: `scripts/smoke/devnet-local --phase withdraw --run-dir /tmp/tmp.5VDwOK8evT/withdraw-build` reached `phase withdraw intent-ready` and then failed during `tx-build` with a short-epoch `TimeTranslationPastHorizon`, proving the live build path was executing and that the DevNet validity bound had to stay inside the forecast horizon.
- WITHDRAW BUILD GREEN: `scripts/smoke/devnet-local --phase withdraw --run-dir /tmp/tmp.gE9yQunNvS/withdraw-build` exits 0; it writes `withdraw/tx-body.cbor.hex`, `withdraw/report.json`, `withdraw/report.md`, and `withdraw/tx-build.log`. Summary records reward account `5da22eab0370edee0d4591f54bba0d79a89d973598f15eb609d968c4`, tx id `5fd2aa15f7269474fa5709e9b804b26f3df60ff4b3c38b3f225797cfef165d43`, fee `469749`, reward `2000000`, and validity upper bound slot `222`.
- PR GATE AFTER BUILD SLICE: `./llm/reviews/local-083-devnet-withdrawal/gate.sh` passed on 2026-05-14 after the intent-to-unsigned-build code, docs, and review-state updates.
- DIAGNOSTICS RED: the first focused `devnet-tests --match 'withdraw diagnostics'` run failed to compile because `WithdrawalRewardTimeout`, `WithdrawalZeroRewards`, `WithdrawalTxBuildFailed`, `withdrawalFailureValue`, `writeWithdrawalFailure`, and the diagnostic fixtures did not exist yet.
- DIAGNOSTICS GREEN: `nix develop --quiet -c cabal test devnet-tests -O0 --test-show-details=direct --test-option=--match --test-option='withdraw diagnostics'` passes 4 examples, 0 failures. It covers reward timeout fields, network mismatch classification before intent writing, zero-rewards stale-artifact removal, and tx-build failure intent preservation with tx-body cleanup.
- WITHDRAW REGRESSION AFTER DIAGNOSTICS: `scripts/smoke/devnet-local --phase withdraw --run-dir /tmp/tmp.4b2zbAg5Z7/withdraw-diagnostics` exits 0; it writes live build artifacts with reward account `ffbb1bb8f19e6ee2357b899043b7337525c072f968a68c8aaf01b2af`, tx id `b7f1decd1453ee955e7dfe75aac7d9e10b0a6ed3c6c59bb4704c08d8c5132600`, fee `469749`, reward `2000000`, and validity upper bound slot `222`.
- PR GATE AFTER DIAGNOSTICS SLICE: `./llm/reviews/local-083-devnet-withdrawal/gate.sh` passed on 2026-05-14 after the typed diagnostics code, Spec Kit, and review-state updates.
- DOCS READY: README, local DevNet docs, release notes, and CHANGELOG distinguish governance funding from unsigned withdrawal build evidence and record `/tmp/tmp.4b2zbAg5Z7/withdraw-diagnostics` as the latest #83 run.
- PR GATE AFTER DOCS SLICE: `./llm/reviews/local-083-devnet-withdrawal/gate.sh` passed on 2026-05-14 after the README, release notes, CHANGELOG, and Spec Kit updates.

## Parallel Notes

- Documentation drafting can run alongside implementation after the
  artifact contract is stable.
- Failure diagnostics should not be split across commits that would
  leave a passing happy path with misleading success artifacts.
