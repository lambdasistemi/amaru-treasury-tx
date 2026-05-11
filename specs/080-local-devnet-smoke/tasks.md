# Tasks: DevNet Governance Action Slice

**Input**: Design documents from
`specs/080-local-devnet-smoke/`
**Issue**: [#82](https://github.com/lambdasistemi/amaru-treasury-tx/issues/82)
**Follow-ups**: [#83 withdrawal](https://github.com/lambdasistemi/amaru-treasury-tx/issues/83),
[#84 swap](https://github.com/lambdasistemi/amaru-treasury-tx/issues/84)

## Phase 1: Scope And Tracking

- [x] T001 Create the governance DevNet issue #82.
- [x] T002 Create the withdrawal DevNet follow-up issue #83.
- [x] T003 Create the swap DevNet follow-up issue #84.
- [x] T004 Add #82, #83, and #84 to the Work backlog.
- [x] T005 Narrow `specs/080-local-devnet-smoke/` to the governance action slice.
- [ ] T006 Update PR metadata once a PR exists for branch `080-local-devnet-smoke`.

## Phase 2: Preserve The Node Boundary

- [x] T007 Keep local-only `devnet` network identity support.
- [x] T008 Keep `test/devnet` and `scripts/smoke/devnet-local` out of default `just ci`.
- [x] T009 Keep `just devnet-smoke node` as the node-readiness proof.
- [ ] T010 Re-run `nix develop --quiet -c cabal test devnet-tests -O0 --test-show-details=direct --test-option=--match --test-option node`.
- [ ] T011 Re-run `nix develop --quiet -c just devnet-smoke node`.

## Phase 3: Upstream Support

- [ ] T012 In `cardano-node-clients` issue #130, add support for Conway stake certificates needed by the treasury script credential, including registration plus always-abstain vote delegation.
- [ ] T013 In `cardano-node-clients` issue #130, add support for Conway treasury-withdrawal proposal procedures/governance actions.
- [ ] T014 In `cardano-node-clients` issue #130, cover script certificate/proposal redeemers with RED/GREEN tests.
- [ ] T015 In `cardano-node-clients` issue #131, expose the node queries required to observe governance action state and reward-account state.
- [ ] T016 Link the merged upstream PRs or open blockers from #82.

## Phase 4: Governance DevNet Smoke

- [ ] T017 Add a failing `governance` phase contract test in `test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs`.
- [ ] T018 Add `governance` to `scripts/smoke/devnet-local` and the `just devnet-smoke` phase contract.
- [ ] T019 Prepare deterministic DevNet protocol treasury/reserve state for a treasury-withdrawal governance action.
- [ ] T020 Register the Amaru treasury script stake credential with registration plus always-abstain vote delegation.
- [ ] T021 Build and submit the treasury-withdrawal governance action through `cardano-node-clients` support.
- [ ] T022 Observe the governance action boundary and funded reward-account state through supported queries.
- [ ] T023 Write `governance/action.json`, `governance/certificates.json`, and summary evidence in the run directory.
- [ ] T024 Make missing upstream support fail with `MISSING_UPSTREAM_GOVERNANCE_SUPPORT`.
- [ ] T025 Run `nix develop --quiet -c just devnet-smoke governance` and capture the result.

## Phase 5: Documentation And Release Notes

- [ ] T026 Update `docs/local-devnet-smoke.md` after the governance phase lands.
- [ ] T027 Update `README.md` after the governance phase lands.
- [ ] T028 Update `docs/release.md` after the governance phase lands.
- [ ] T029 Document release-note wording that distinguishes node, governance, withdrawal, and swap evidence.

## Dependencies

- Phase 2 is already mostly complete and remains the baseline for all
  later work.
- Phase 3 blocks a clean Phase 4 unless a temporary CLI boundary is
  explicitly accepted and documented as temporary.
- #83 starts after #82 produces funded reward-account evidence or an
  accepted mock/fixture substitute for local-only development.
- #84 starts after the DevNet harness and funding assumptions are
  stable enough to exercise live swap state.
