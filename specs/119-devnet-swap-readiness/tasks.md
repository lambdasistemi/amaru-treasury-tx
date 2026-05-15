# Tasks: DevNet Swap Contract Readiness Slice

**Input**: Design documents from `specs/119-devnet-swap-readiness/`
**Issue**: [#132](https://github.com/lambdasistemi/amaru-treasury-tx/issues/132)
**Depends on**: [#83](https://github.com/lambdasistemi/amaru-treasury-tx/issues/83) merged into `origin/main`; [#84](https://github.com/lambdasistemi/amaru-treasury-tx/issues/84) consumes this readiness handoff.

## Phase 1: Scope And Process

- [x] T001 Create #132 for DevNet SundaeSwap V3 contract registration readiness and comment on #84 with the split.
- [x] T002 Create Spec Kit artifacts in `specs/119-devnet-swap-readiness/`.
- [x] T003 Record the RED/GREEN proof and gate candidate in `specs/119-devnet-swap-readiness/plan.md`.
- [x] T004 Create local review state and gate files in `llm/reviews/local-119-devnet-swap-readiness/`.
- [x] T005 Review `spec.md`, `plan.md`, and `tasks.md` for consistency before implementation.

## Phase 2: Readiness Contract RED

**Goal**: Prove the current code lacks the `swap-ready` readiness contract before production changes.

**Independent Test**: The focused devnet test fails on the current branch for the expected missing phase/evidence reason.

- [x] T006 [US1] RED: add a focused `swap-ready readiness` Hspec example to `test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs` that requires readiness summary/registry fields.
- [x] T007 [US1] RED: run `nix develop --quiet -c cabal test devnet-tests -O0 --test-show-details=direct --test-option=--match --test-option='swap-ready readiness'` and record the expected failure in this file.
- [x] T008 [US1] RED: verify `scripts/smoke/devnet-local --phase swap-ready --run-dir <tmp>` currently fails as an unknown phase or missing artifact contract.

## Phase 3: Public SundaeSwap V3 Artifact

**Goal**: Pin or load the real public V3 order validator identity accepted by the readiness phase.

**Independent Test**: Pure tests reject missing or mismatched order-validator artifacts before any DevNet setup succeeds.

- [x] T009 [US1] Add a pure test in `test/unit/Amaru/Treasury/ConstantsSpec.hs` or a new focused module that requires the public SundaeSwap V3 `order.spend` artifact and expected script hash.
- [x] T010 [US1] Add the public order-validator artifact under `assets/plutus/` or an equivalent reviewed source path, with provenance documented in `assets/plutus/README.md`.
- [x] T011 [US1] Add Haskell constants/helpers for the order-validator source, blob, and hash in the existing constants/registry modules without changing swap builder semantics.
- [x] T012 [US1] GREEN: run the focused artifact/hash test and record the passing command output.

## Phase 4: DevNet Readiness Publication

**Goal**: Publish or verify the local DevNet order-validator reference and write the handoff registry for #84.

**Independent Test**: `just devnet-smoke swap-ready` writes readiness artifacts without building or funding a swap order.

- [x] T013 [US1] Add `swap-ready` phase parsing to `scripts/smoke/devnet-local` and the `all` phase only if the review accepts including readiness in `all`.
- [x] T014 [US1] Add a `swap-ready` selector and smoke action in `test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs`.
- [x] T015 [US1] Reuse the DevNet reference-script publication helpers to publish the order validator reference script and wait for the reference UTxO.
- [x] T016 [US2] Write `swap-ready/registry.json`, `swap-ready/summary.json`, and `swap-ready/provenance.json` with the fields in `contracts/devnet-swap-readiness.md`.
- [x] T017 [US2] Assert the readiness registry contains enough order-build inputs for #84: order address, order script hash, order script ref, network magic, source commit, and artifact paths.
- [x] T018 [US2] GREEN: run `nix develop --quiet -c just devnet-smoke swap-ready` and record the run directory, script hash, reference UTxO, and registry path.

## Phase 5: Failure Diagnostics

**Goal**: Fail with typed diagnostics before misleading success artifacts are written.

**Independent Test**: Focused diagnostics tests pass and no stale success registry survives failure.

- [ ] T019 [US1] Cover `missing-sundae-order-validator` and `sundae-order-validator-hash-mismatch` in `test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs`.
- [ ] T020 [US1] Cover `reference-script-utxo-missing` and `reference-script-hash-mismatch` diagnostics.
- [ ] T021 [US1] Cover `fixture-only-not-compatibility-evidence` so toy validators cannot satisfy acceptance.
- [ ] T022 [US2] Cover stale registry cleanup before writing failure artifacts.
- [ ] T023 [US1] GREEN: run the focused diagnostics command and record passing examples/failures count.

## Phase 6: Documentation And Release Metadata

**Goal**: Document readiness evidence without claiming order build/funding or spend.

**Independent Test**: Docs and issue metadata identify #132 as the prerequisite for #84 and keep #85/#86/#87 boundaries intact.

- [x] T024 [US3] Update `docs/local-devnet-smoke.md` with `swap-ready` usage, artifacts, diagnostics, and boundary text.
- [x] T025 [US3] Update `README.md`, `docs/release.md`, and `CHANGELOG.md` if verified readiness evidence changes release-facing behavior or release notes.
- [x] T026 [US3] Update #132 issue metadata with verified run evidence and add a #84 handoff comment naming the readiness artifact.
- [x] T027 [US3] Run `./llm/reviews/local-119-devnet-swap-readiness/gate.sh` and record the result.
- [x] T028 [US3] Commit the accepted vertical slice as `test(devnet): register sundaeswap readiness` or another reviewed conventional title.

## Dependencies

- Phase 1 must finish before implementation.
- Phase 2 is the TDD RED gate and must fail for the expected reason before Phase 3 or Phase 4 production code.
- Phase 3 must finish before Phase 4 can publish a real reference script.
- Phase 4 must finish before #84 can consume readiness metadata.
- Phase 5 can be implemented after the happy-path artifact shape is stable.
- Phase 6 starts after a successful readiness run exists.

## Evidence

- ISSUE SPLIT: #132 created for readiness and #84 commented with the readiness/order-build split on 2026-05-15.
- BASELINE: branch `119-devnet-swap-readiness` was created from `origin/main` `675b573`, which includes merged #83 withdrawal materialization evidence.
- PLAN/TASK REVIEW: local solo review files were created under `llm/reviews/local-119-devnet-swap-readiness/` and approve starting T006/T007 RED work.
- DIRECT HARNESS RED: `scripts/smoke/devnet-local --phase swap-ready --run-dir /tmp/tmp.EB6S5L1V5L` printed `devnet-smoke: unknown phase: swap-ready` and returned exit `64`, proving the current harness has no readiness phase.
- FOCUSED HSPec RED: `nix develop --quiet -c cabal test devnet-tests -O0 --test-show-details=direct --test-option=--match --test-option='swap-ready readiness'` exited 1 because `swapReadinessRegistryValue` and `sampleSwapReadinessEvidence` were not in scope, proving the readiness artifact contract is absent before implementation.
- SPEC/PROCESS GATE: `./llm/reviews/local-119-devnet-swap-readiness/gate.sh` exited 0 after build, schema-check, 376 unit examples with 0 failures, 25 golden examples with 0 failures and 1 pending, format-check, hlint, smoke scripts, and release-check.
- PR METADATA: draft PR #133 opened against `main` with the spec/process summary, verification evidence, and next RED/GREEN tasks.
- ARTIFACT GREEN: `nix develop --quiet -c just unit 'Amaru.Treasury.Constants/pins the public SundaeSwap V3 order.spend artifact'` passed with 1 example, 0 failures after pinning `SundaeSwap-finance/sundae-contracts@be33466b7dbe0f8e6c0e0f46ff23737897f45835` `order.spend`; script hash `02eee6c4d128c9700c178922163645f1fdb381bbdce071acbbd49465`.
- READINESS CONTRACT GREEN: `nix develop --quiet -c cabal test devnet-tests -O0 --test-show-details=direct --test-option=--match --test-option='swap-ready readiness'` passed with 1 example, 0 failures after adding the readiness registry contract.
- LIVE DEVNET GREEN: `nix develop --quiet -c just devnet-smoke swap-ready` passed with 2 examples, 0 failures. Run directory: `runs/devnet/20260515T124545Z`; script hash: `02eee6c4d128c9700c178922163645f1fdb381bbdce071acbbd49465`; reference UTxO: `490b9bc8a80e8a55434b895bea6ca47fc612105c0cf71b781a61e99cd2be46af#0`; registry: `runs/devnet/20260515T124545Z/swap-ready/registry.json`.
- LOCAL PR GATE: `./llm/reviews/local-119-devnet-swap-readiness/gate.sh` exited 0 after `git diff --check`, `just build`, schema-check, 377 unit examples with 0 failures, 25 golden examples with 0 failures and 1 pending, format-check, hlint, smoke scripts, and release-check.
- ISSUE METADATA: #132 was updated with the verified readiness evidence in issue comment `4459891548`; #84 was updated with the registry handoff in issue comment `4459891659`.
- REBASE REFRESH: branch replayed onto `origin/main` `43f8c2d` on 2026-05-15; `./llm/reviews/local-119-devnet-swap-readiness/gate.sh` exited 0 after `git diff --check`, `just build`, schema-check, 410 unit examples with 0 failures, 25 golden examples with 0 failures and 1 pending, format-check, hlint, smoke scripts, and release-check.
- PR-138 BASE REFRESH: branch replayed onto PR #138 head `origin/pr/138` `42fc194` on 2026-05-15; `./llm/reviews/local-119-devnet-swap-readiness/gate.sh` exited 0 after `git diff --check`, `just build`, schema-check, 410 unit examples with 0 failures, 25 golden examples with 0 failures and 1 pending, format-check, hlint, smoke scripts, and release-check.
- MAIN BASE REFRESH: after #138 was squash-merged, branch replayed onto `origin/main` `4b3ede0` on 2026-05-15; `./llm/reviews/local-119-devnet-swap-readiness/gate.sh` exited 0 after `git diff --check`, `just build`, schema-check, 410 unit examples with 0 failures, 25 golden examples with 0 failures and 1 pending, format-check, hlint, smoke scripts, and release-check.

## Parallel Notes

- Documentation drafting can begin after the registry contract is stable.
- The public artifact/hash work and shell phase parser are separate files, but they should land in one bisect-safe slice with the failing proof and GREEN readiness run.
