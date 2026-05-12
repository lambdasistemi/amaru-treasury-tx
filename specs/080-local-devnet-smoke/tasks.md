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
- [ ] T009 Update PR metadata once a PR exists for branch `080-local-devnet-smoke`.

## Phase 2: Preserve The Node Boundary

- [x] T010 Keep local-only `devnet` network identity support.
- [x] T011 Keep `test/devnet` and `scripts/smoke/devnet-local` out of default `just ci`.
- [x] T012 Keep `just devnet-smoke node` as the node-readiness proof.
- [ ] T013 Re-run `nix develop --quiet -c cabal test devnet-tests -O0 --test-show-details=direct --test-option=--match --test-option node`.
- [ ] T014 Re-run `nix develop --quiet -c just devnet-smoke node`.

## Phase 3: Upstream Support

- [ ] T015 In `cardano-node-clients` issue #130, add support for Conway stake certificates needed by the treasury script credential, including registration plus always-abstain vote delegation.
- [ ] T016 In `cardano-node-clients` issue #130, add support for Conway treasury-withdrawal proposal procedures/governance actions.
- [ ] T017 In `cardano-node-clients` issue #130, cover script certificate/proposal redeemers with RED/GREEN tests.
- [ ] T018 In `cardano-node-clients` issue #131, expose the node queries required to observe governance action state and reward-account state.
- [ ] T019 Link the merged upstream PRs or open blockers from #82.

## Phase 4: Governance DevNet Smoke

- [x] T020 Add a failing `governance` phase contract test in `test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs`.
- [x] T021 Add `governance` to `scripts/smoke/devnet-local` and the `just devnet-smoke` phase contract.
- [ ] T022 Prepare deterministic DevNet protocol treasury/reserve state for a treasury-withdrawal governance action.
- [ ] T023 Register the Amaru treasury script stake credential with registration plus always-abstain vote delegation.
- [ ] T024 Build and submit the treasury-withdrawal governance action through `cardano-node-clients` support.
- [ ] T025 Observe the governance action boundary and funded reward-account state through supported queries.
- [ ] T026 Write `governance/action.json`, `governance/certificates.json`, and summary evidence in the run directory.
- [x] T027 Make missing upstream support fail with `MISSING_UPSTREAM_GOVERNANCE_SUPPORT`.
- [x] T028 Run `nix develop --quiet -c just devnet-smoke governance` and capture the result.

## Phase 5: Documentation And Release Notes

- [x] T029 Update `docs/local-devnet-smoke.md` after the governance phase lands.
- [x] T030 Update `README.md` after the governance phase lands.
- [x] T031 Update `docs/release.md` after the governance phase lands.
- [x] T032 Document release-note wording that distinguishes node, governance, withdrawal, disburse, swap-order, swap-spend, and reorganize evidence.

## Dependencies

- Phase 2 is already mostly complete and remains the baseline for all
  later work.
- Phase 3 blocks a clean Phase 4 unless a temporary CLI boundary is
  explicitly accepted and documented as temporary.
- #83 starts after #82 produces funded reward-account evidence or an
  accepted mock/fixture substitute for local-only development.
- #86 starts after the DevNet harness and treasury funding assumptions
  are stable enough to exercise live disburse state.
- #84 starts after the DevNet harness and funding assumptions are
  stable enough to exercise live SundaeSwap V3 order-build state.
- #85 starts after #84 produces a funded V3-compatible order artifact.
- #87 starts after earlier slices or local setup can provide multiple
  treasury UTxOs, and after #46 provides the release-facing builder.
