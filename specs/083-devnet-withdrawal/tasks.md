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

## Phase 5b: Sign, Submit, And Materialize

- [x] T021a [US3] RED: require submitted-withdrawal materialization fields in the focused devnet diagnostics contract.
- [x] T021b [US3] Decode the built withdrawal CBOR, sign it with the local DevNet wallet key, and write `withdraw/signed-tx.cbor.hex`.
- [x] T021c [US3] Submit the signed withdrawal through the local `cardano-node-clients` submitter and write `withdraw/submit.log`.
- [x] T021d [US3] Wait for the treasury output UTxO, assert output `#0` contains the withdrawn ADA at the treasury script address, assert reward-after-submit is zero, and assert the treasury ADA delta equals the withdrawn amount.
- [x] T021e [US3] Write `withdraw/materialized.json` and final summary fields for signed tx, submitted tx id, materialized UTxO, reward drain, and treasury ADA before/after totals.

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
- Phase 5b is complete: the DevNet harness signs/submits the built
  withdrawal and records materialized treasury ADA evidence.
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
- DIAGNOSTICS GREEN: `nix develop --quiet -c cabal test devnet-tests -O0 --test-show-details=direct --test-option=--match --test-option='withdraw diagnostics'` passes 5 examples, 0 failures. It covers materialization proof fields, reward timeout fields, network mismatch classification before intent writing, zero-rewards stale-artifact removal, and tx-build failure intent preservation with tx-body cleanup.
- WITHDRAW REGRESSION AFTER DIAGNOSTICS: `scripts/smoke/devnet-local --phase withdraw --run-dir /tmp/tmp.KP53a1HDRL/withdraw-render` exits 0 after the DevNet report-render fix; it writes live build artifacts with reward account `ffbb1bb8f19e6ee2357b899043b7337525c072f968a68c8aaf01b2af`, tx id `fdedbf33e61132a9fdbb883eb6bff4b6d4517ded08e5ca64ee373c1e1db064d3`, fee `469749`, reward `2000000`, validity upper bound slot `222`, and `withdraw/report.md` line `Explorer: no public explorer for devnet`.
- PR GATE AFTER DIAGNOSTICS SLICE: `./llm/reviews/local-083-devnet-withdrawal/gate.sh` passed on 2026-05-14 after the typed diagnostics code, Spec Kit, and review-state updates.
- DEVNET REPORT RENDER RED/GREEN: `nix develop --quiet -c just unit 'Amaru.Treasury.Report.Render/does not render a public explorer link for devnet'` first failed because DevNet reports rendered a mainnet Cardanoscan URL, then passed after the renderer switched DevNet/custom networks to `Explorer: no public explorer for devnet`.
- MATERIALIZATION CONTRACT RED: `nix develop --quiet -c cabal test devnet-tests -O0 --test-show-details=direct --test-option=--match --test-option='records submitted withdrawal materialization proof'` first failed to compile because `WithdrawalSubmissionEvidence` did not exist.
- MATERIALIZATION CONTRACT GREEN: the same focused command passes and requires signed tx path, submit log path, materialization path, submitted tx id, treasury materialized output, reward-before/after-submit values, and treasury ADA before/after totals.
- WITHDRAW VALUE-CONSERVATION RED: `nix develop --quiet -c just unit 'Amaru.Treasury.Build/runWithdraw/balances the reward withdrawal as value supplied by the transaction'` first failed with `expected: 50007239276 but got: 62507239276`, proving the builder had balanced the treasury output from wallet input instead of treating the withdrawal as transaction supply.
- WITHDRAW VALUE-CONSERVATION GREEN: the same focused unit passes after `runWithdrawAction` adds the withdrawal amount to wallet change before fee alignment.
- WITHDRAW SUBMIT RED: `nix develop --quiet -c just devnet-smoke withdraw` reached node submission and was rejected by the node with `ValueNotConservedUTxO` by exactly `2000000` lovelace before the value-conservation fix.
- WITHDRAW REPORT ACCOUNTING RED/GREEN: `nix develop --quiet -c just unit 'Amaru.Treasury.Report/accounts for withdraw rewards'` passes after proving reports count reward withdrawals as transaction supply, not wallet spend.
- WITHDRAW GOLDEN REFRESH: `nix develop --quiet -c just golden withdraw` passes after refreshing withdraw CBOR and report goldens; the Markdown conservation line now reads `inputs + withdrawals = outputs + fee` with residual `0`.
- WITHDRAW SUBMIT/MATERIALIZATION GREEN: `nix develop --quiet -c just devnet-smoke withdraw` exits 0 with run directory `runs/devnet/20260515T091231Z`; it writes `withdraw/signed-tx.cbor.hex`, `withdraw/submit.log`, and `withdraw/materialized.json`, submits tx `ff78a866216fbe1b3cb2bf356f3a01cc088ab13260d50fd0b7b4b019b4a3b52d`, observes materialized output `ff78a866216fbe1b3cb2bf356f3a01cc088ab13260d50fd0b7b4b019b4a3b52d#0` with `2000000` lovelace at the treasury script address, records reward `2000000 -> 0` after submit, and records treasury ADA `200000000 -> 202000000`.
- DOCS READY: README, local DevNet docs, release notes, and CHANGELOG distinguish governance funding from withdrawal materialization evidence and record `runs/devnet/20260515T091231Z` as the latest #83 run.
- PR GATE AFTER DOCS SLICE: `./llm/reviews/local-083-devnet-withdrawal/gate.sh` passed on 2026-05-14 after the README, release notes, CHANGELOG, and Spec Kit updates.
- FINAL STACK REBASE: PR #93 and #100 were rebased onto `origin/main` `c36139c` / Cabal `0.2.7.0` on 2026-05-14 after the `v0.2.7.0` release landed. The post-rebase #83 gate `./llm/reviews/local-083-devnet-withdrawal/gate.sh` exited 0 with build, schema-check, 332 unit examples, 25 golden examples with 1 pending, format-check, hlint, smoke scripts, and release-check passing.
- REBASE REFRESH: PR #93 and #100 were rebased onto `origin/main` `c1fb9f3` / Cabal `0.2.8.0` on 2026-05-15 after the `v0.2.8.0` release landed. The post-rebase #83 gate `./llm/reviews/local-083-devnet-withdrawal/gate.sh` exited 0 with build, schema-check, 364 unit examples, 25 golden examples with 1 pending, format-check, hlint, smoke scripts, and release-check passing.
- MAIN RETARGET: after PR #93 merged into `origin/main` at `308f0c9` on 2026-05-15, PR #100 was rebased directly onto `main` by replaying only the withdrawal commits after the old `080-local-devnet-smoke` base. The retarget gate `./llm/reviews/local-083-devnet-withdrawal/gate.sh` exited 0 with build, schema-check, 364 unit examples, 25 golden examples with 1 pending, format-check, hlint, smoke scripts, and release-check passing.
- FINAL GATE AFTER MATERIALIZATION SLICE: `./llm/reviews/local-083-devnet-withdrawal/gate.sh` exits 0 after the signed/submitted/materialized withdrawal slice, report-accounting schema refresh, docs, and fixture updates. It passes build, schema-check, 366 unit examples, 25 golden examples with 1 pending, format-check, hlint, smoke scripts, and release-check.

## Parallel Notes

- Documentation drafting can run alongside implementation after the
  artifact contract is stable.
- Failure diagnostics should not be split across commits that would
  leave a passing happy path with misleading success artifacts.
