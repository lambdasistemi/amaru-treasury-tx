# Analyzer Notes: DevNet Governance And Withdrawal Setup

## Scope Corrections Applied Before Handoff

- The P1 story is the shipped `devnet governance-withdrawal-init`
  command. `just devnet-smoke ...` is proof only.
- #149 consumes both #147 `registry-init/registry.json` and #148
  `stake-reward-init/accounts.json`; it must not recreate registry or
  reward-account setup.
- #149 must not re-register the treasury reward account. #148 already
  registers treasury and records permissions as the later
  withdraw-zero account.
- The existing inline `SmokeSpec.hs` governance and withdrawal flows are
  implementation source material, not the final boundary. Production
  code must own proposal, vote, reward wait, withdrawal build, signing,
  submission, materialization verification, and artifact rendering.
- Documentation and repository metadata are not finalization extras:
  README, `docs/local-devnet-smoke.md`, `docs/release.md`, contracts,
  quickstart, tasks, and PR metadata must align before the PR is marked
  ready.

## Cross-Artifact Review

| ID | Category | Severity | Location(s) | Summary | Resolution |
|----|----------|----------|-------------|---------|------------|
| A1 | Coverage | High | spec.md FR-001, contract | The issue could be read as smoke-only because existing docs use `governance` and `withdraw` phases. | Spec, contract, quickstart, and tasks now lead with the shipped command. |
| A2 | Boundary | High | spec.md FR-003/FR-004, plan risks | Existing smoke re-registers the treasury reward account during governance setup. | Spec and plan require consuming #148 artifacts and forbid re-registration. |
| A3 | Handoff | Medium | spec.md US3, data-model | #150 needs a stable treasury UTxO handoff. | `materialized.json` is a required artifact with registry/stake source paths. |
| A4 | Documentation | Medium | plan finalization, tasks | PR readiness could happen before docs match behavior. | Finalization tasks require README, docs, release notes, quickstart, contracts, and PR body alignment before `gate.sh` removal. |

## Coverage Summary

| Requirement Key | Has Task? | Task IDs | Notes |
|-----------------|-----------|----------|-------|
| FR-001 command | Yes | T014-T022 | Parser, command module, runner wiring. |
| FR-002 registry input | Yes | T016-T017 | #147 registry reader/validation. |
| FR-003 stake/reward input | Yes | T016-T017 | #148 accounts reader/validation. |
| FR-004 no re-registration | Yes | T017,T023 | Unit and smoke review requirements. |
| FR-005 governance proposal/vote | Yes | T017-T018 | Production command slice. |
| FR-006 reward wait | Yes | T018,T025 | Production and live smoke proof. |
| FR-007 withdraw intent | Yes | T019 | Must use production withdraw resolver. |
| FR-008 tx-build/sign/submit/materialize | Yes | T019-T020 | DevNet exception only. |
| FR-009 non-DevNet guard | Yes | T014,T021 | Guard before effects. |
| FR-010 artifacts | Yes | T015-T020,T028 | Contract and docs. |
| FR-011 failure diagnostics | Yes | T020 | Stable failure artifact. |
| FR-012 thin smoke | Yes | T023-T027 | Smoke calls production runner. |
| FR-013 docs/metadata | Yes | T028-T031 | Before ready. |
| FR-014 exclusions | Yes | T017,T023,T028 | No #150/swap/reorganize behavior. |

## Analyzer Verdict

No critical unresolved artifact gaps remain before the first
implementation handoff. The implementation brief must preserve the
three load-bearing boundaries: command first, consume #147/#148, and
move #149 construction out of smoke.
