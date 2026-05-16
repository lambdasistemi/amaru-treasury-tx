# Tasks: DevNet Disburse Slice

**Input**: Design documents from `specs/140-devnet-disburse/`
**Issue**: [#86](https://github.com/lambdasistemi/amaru-treasury-tx/issues/86)
**Depends on**: [#83](https://github.com/lambdasistemi/amaru-treasury-tx/issues/83) merged and closed; #82 governance setup merged through #83.

## Phase 1: Scope And Process

- [x] T001 Create #86 Spec Kit `spec.md` and requirements checklist in `specs/140-devnet-disburse/`.
- [x] T002 Open draft PR #145 for branch `140-devnet-disburse`.
- [x] T003 Create local review state and gate candidate in `llm/reviews/local-140-devnet-disburse/`.
- [x] T004 Review `spec.md`, `plan.md`, and `tasks.md` for cross-artifact consistency before production implementation.
- [x] T005 Commit plan/task artifacts as `docs(devnet): plan disburse slice`.

## Phase 2: Disburse Contract RED

**Goal**: Prove the current code lacks the `disburse` phase before production changes.

**Independent Test**: Direct smoke script fails with the expected unknown-phase exit.

- [x] T006 [US1] RED: run `scripts/smoke/devnet-local --phase disburse --run-dir <tmp>` and record exit `64` plus `unknown phase: disburse` in this file.
- [ ] T007 [US1] Add a focused `disburse diagnostics` or `disburse smoke` Hspec contract in `test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs` that requires disburse summary/failure artifact shape.
- [ ] T008 [US1] Add `disburse` phase parsing to `scripts/smoke/devnet-local` and `just devnet-smoke`.

## Phase 3: Live Treasury Prerequisite

**Goal**: Start disburse from live treasury UTxO state, not frozen fixtures.

**Independent Test**: A disburse run records prerequisite governance/withdrawal evidence and selected live treasury state before writing success artifacts.

- [ ] T009 [US1] Reuse or factor the #83 withdrawal materialization helper in `test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs` so the disburse phase can create live treasury ADA.
- [ ] T010 [US1] Write `disburse/prerequisite.json` with withdrawal summary path, treasury address, materialized treasury input, and observed treasury ADA.
- [ ] T011 [US1] Cover missing or insufficient treasury state with typed diagnostics and stale success-artifact cleanup.

## Phase 4: Live Disburse Intent

**Goal**: Resolve a schema-v1 disburse intent from the live local-node provider.

**Independent Test**: `disburse/intent.json` decodes through the unified intent path and names live selected inputs.

- [ ] T012 [US2] Run the existing disburse resolver against live DevNet wallet, treasury, registry, permissions, beneficiary, signer, unit, and validity state.
- [ ] T013 [US2] Write `disburse/intent.json` and assert `action = "disburse"`, expected unit/amount, beneficiary, selected wallet input, and selected treasury inputs.
- [ ] T014 [US2] Cover beneficiary/network mismatch and missing wallet fuel/collateral diagnostics before success summaries are written.

## Phase 5: Intent To Unsigned Build

**Goal**: Build unsigned Conway CBOR and reports from the live disburse intent.

**Independent Test**: `tx-build` consumes the live intent and writes all build artifacts.

- [ ] T015 [US2] Run `tx-build` for the live disburse intent in `test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs`.
- [ ] T016 [US2] Write `disburse/tx-body.cbor.hex`, `disburse/report.json`, `disburse/report.md`, and `disburse/tx-build.log`.
- [ ] T017 [US2] Write `disburse/summary.json` fields for tx id, fee, validity, selected inputs, beneficiary, unit, amount, and artifact paths.
- [ ] T018 [US2] Cover `tx-build-failed` diagnostics that preserve fresh intent/logs but remove stale unsigned CBOR and stale success summaries.

## Phase 6: ADA And USDM Boundary

**Goal**: Make ADA success and USDM status explicit without overclaiming.

**Independent Test**: A run proves ADA disburse success and separately records USDM success or a stable missing-token/setup diagnostic.

- [ ] T019 [US3] GREEN: run `nix develop --quiet -c just devnet-smoke disburse` for the ADA subcase and record run directory, unit, amount, tx id, and summary path.
- [ ] T020 [US3] Write `disburse/usdm-boundary.json` as either successful USDM evidence or a typed `missing-usdm-setup` / `missing-usdm-treasury-value` diagnostic.
- [ ] T021 [US3] If synthetic USDM setup is feasible in this slice, add the setup and prove a USDM disburse; otherwise document the stable diagnostic as the accepted #86 USDM boundary.

## Phase 7: Documentation And Release Metadata

**Goal**: Document disburse evidence without claiming swap or reorganize evidence.

**Independent Test**: Docs and issue metadata identify #86 as disburse-only and keep #84/#85/#136/#87 separate.

- [ ] T022 [US4] Update `docs/local-devnet-smoke.md` with `disburse` usage, artifacts, diagnostics, and boundary text.
- [ ] T023 [US4] Update `README.md`, `docs/release.md`, and `CHANGELOG.md` with verified disburse evidence and the ADA/USDM boundary.
- [ ] T024 [US4] Update #86 issue metadata and downstream roadmap issue comments with verified evidence.
- [ ] T025 [US4] Run `./llm/reviews/local-140-devnet-disburse/gate.sh` and record the result.
- [ ] T026 [US4] Commit accepted implementation/docs slices with conventional titles.

## Dependencies

- Phase 1 must finish before production implementation.
- Phase 2 is the TDD RED gate and must fail for the expected reason
  before Phase 3 production code.
- Phase 3 must create or observe spendable treasury state before Phase
  4 can resolve a disburse intent.
- Phase 4 must finish before Phase 5 can run `tx-build`.
- Phase 6 depends on the happy-path artifact shape from Phase 5.
- Phase 7 starts after a verified disburse run or accepted typed USDM
  diagnostic exists.

## Evidence

- ISSUE STATE: #83 is now closed as completed after PR #100 merged with `Refs #83` instead of a closing keyword.
- BASELINE: branch `140-devnet-disburse` is based on `origin/main` `b390a3c`, which includes merged #83 withdrawal materialization and later DevNet readiness work.
- PR METADATA: draft PR #145 opened against `main` for #86 before implementation code.
- DIRECT HARNESS RED: `scripts/smoke/devnet-local --phase disburse --run-dir /tmp/tmp.bQinQYetgh` returned exit `64` and printed `devnet-smoke: unknown phase: disburse`, proving the current harness has no disburse phase.

## Parallel Notes

- Documentation drafting can begin after the artifact contract is
  stable.
- Diagnostics should remain in the same vertical slice as the artifact
  they protect, so stale success artifacts are not introduced
  temporarily.
