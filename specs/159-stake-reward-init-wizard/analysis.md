# Cross-Artifact Analysis: stake-reward-init-wizard

**Branch**: `159-stake-reward-init-wizard` | **Date**: 2026-05-18
**Inputs**: [spec.md](./spec.md), [plan.md](./plan.md), [research.md](./research.md), [tasks.md](./tasks.md), [.specify/memory/constitution.md](../../.specify/memory/constitution.md)
**Verdict**: **READY FOR IMPLEMENTATION** with low-severity gaps documented below.

This report is the output of the Analyzer Subagent (read-only `speckit-analyze` pass) dispatched per `resolve-ticket`. Gaps are kept for the implementation phase's orchestrator review; no loop back to `speckit-plan` or `speckit-tasks` is required.

## 1. Cross-artifact consistency

| Issue | Severity | Detail |
|---|---|---|
| C1 | LOW (prose) | spec FR-009 says the new golden suite is "modelled on `test/golden/StakeRewardInitIntentSpec.hs`"; that's the right model for the **CBOR-parity** golden, but the grep enforcement (T021) is modelled on `RegistryInitWizardNoSimulationSpec.hs`, not `StakeRewardInitIntentSpec.hs`. The mis-cite is in FR-009's parenthetical; the actual templates the tasks reference are correct. Cosmetic. |
| C2 | none | `--force` flag treatment is consistent across spec FR-002, plan Slice 1, tasks T002, T006. |
| C3 | LOW (trace gap) | `--validity-hours → upper-bound-slot` linkage is not explicitly enumerated in FR-006 (which says "upper-bound-slot sampling") or any task. The implementation will derive this from the existing `RegistryInitWizard` pattern; the orchestrator review will confirm. |
| C4 | LOW (process) | Plan Slice 2 brief frames the `registry.json` fixture co-derivation as "if practical"; tasks T009 carries the same fallback. Acceptable softening, but the practicality threshold is orchestrator-discretion, not a discrete task. |
| C5 | none | Network guard "before any chain query" wording is consistent across spec FR-008, research D9, tasks T011. |

## 2. Requirements ↔ tasks coverage

| Req | Tasks | Status |
|---|---|---|
| FR-001 | T001, T008, T015, T016, T020 | covered |
| FR-002 | T002, T008 | covered |
| FR-003 | T002, T008 | covered |
| FR-004 | T015, T016 | covered |
| FR-005 | T020 | covered |
| FR-006 | T014, T015 | covered (partial — `--validity-hours`→upper-bound-slot link is implicit, see C3) |
| FR-007 | T016, T020 | covered |
| FR-008 | T011, T014, T019 | covered |
| FR-009 | T009, T017 | covered (the grep enforcement that FR-009 implies is owned by T021, not the goldens) |
| FR-010 | T010, T018 | covered |
| FR-011 | T009, T017, plus fixture file tasks in Slices 2 & 3 | covered |
| FR-012 | T022, T023 | covered |
| FR-013 (`just schema-check` green / no schema delta) | TRANSITIVE | relies on `./gate.sh` running schema-check; no discrete task |
| FR-014 (`SmokeSpec` unchanged) | TRANSITIVE | relies on Slice 1–4 forbidden-scope review; no mechanical grep test |
| FR-015 (bisect-safe per commit) | TRANSITIVE | every slice gate runs `./gate.sh`; no discrete task |
| NFR-001 | T008 | covered |
| NFR-002 | T008 (cabal `library` stanza only) | covered |
| NFR-003 (no DevNet code in shared modules) | TRANSITIVE | architectural posture, orchestrator review |
| NFR-004 (`tx-build` unchanged) | TRANSITIVE | no grep task; relies on forbidden-scope review |
| NFR-005 (no bundle/plan/envelope carrier) | TRANSITIVE | no grep task; relies on forbidden-scope review |
| NFR-006 (no internal simulation) | T021 | covered |
| NFR-007 (no enforced ordering between subcommands) | TRANSITIVE | architectural posture, orchestrator review |
| SC-001 | T001, T002 | covered |
| SC-002 | T009, T017 | covered |
| SC-003 | T010, T018 | covered |
| SC-004 | TRANSITIVE | `./gate.sh` runs the nix checks |
| SC-005 (`SmokeSpec` source unchanged) | TRANSITIVE | no mechanical grep; orchestrator review |
| SC-006 (`tx-build` source unchanged; grep) | UNCOVERED (no grep task) | spec promises grep; no task implements it |
| SC-007 | T021 | covered |
| SC-008 (PR body / README / docs agree) | T022, T023 (no explicit PR-body alignment task) | partial |

**Coverage**: 22 of 30 requirements have ≥1 backing task. 8 rely on `./gate.sh` transitivity or orchestrator review (FR-013, FR-014, FR-015, NFR-003, NFR-004, NFR-005, NFR-007, SC-005). SC-006 is the one **unscaffolded grep** the spec promised but no task delivers.

## 3. Tasks ↔ requirements traceability

All implementation tasks T001–T023 trace to at least one FR/NFR/SC. T024 (finalization audit) and T025 (drop gate + ready) are process tasks traceable to FR-015 only.

## 4. Plan acknowledges, tasks miss

- **Slice 2a/2b split fallback** (plan Risks Risk 5): named but no threshold task ("if Slice 2 diff > 600 lines, split"). Orchestrator-discretion only — acceptable.
- **Wallet shortfall**: T013 covers the empty-pure-ADA-UTxOs case only; spec edge case "wallet has insufficient lovelace" could also describe the non-empty-but-insufficient case. Behavioral match between spec and implementation is partial; matches `RegistryInitWizard`'s precedent.
- **PR-body alignment**: spec SC-008 names "PR body, README, docs agree"; T022/T023 cover README + docs only; PR-body alignment is part of orchestrator finalization (T024).

## 5. Constitution conflicts

- **I (faithful port of bash recipes)**: PASS. stake-reward-init is Haskell-stack-only; principle inapplicable.
- **II (pure builders, impure shell)**: PASS. Pure `*ToIntent` returning `Either`; resolver IO segregated.
- **III (pluggable data source)**: PASS. Resolver uses existing `Provider`-based seam.
- **IV (build never sign or submit)**: PASS. Wizard emits intent JSON only; FR-007/NFR-005 confirm.
- **V (test-first golden CBOR fixtures, NON-NEGOTIABLE)**: PASS. T009, T017 ship goldens; RED-before-GREEN per slice.
- **VI (Hackage-ready Haskell)**: PASS with soft gap. Plan claims PASS; no task explicitly enumerates `cabal check` / Haddock-on-export. Relies on `./gate.sh` (`nix build .#checks.lint`, `just hlint`, `just format-check`). Acceptable.
- **VII (Label-1694 metadata)**: PASS. stake-reward-init is operational, not governance; parser brief explicitly excludes rationale flags.

**No CRITICAL violations.**

## 6. Additional speckit-analyze observations

- **Ambiguity**: "standard resolver work" appears in spec FR-006 and plan Summary without a definitional anchor; readable in context (= `RegistryInitWizard`'s resolver shape).
- **Terminology drift**: "stupid command" / "stupid baseline" / "deliberately-stupid baseline" / "stupid-baseline directive" appear interchangeably across spec, plan, research. Cosmetic.
- **Underspecified error variants**: `StakeRewardInitOutputParentMissing` and `StakeRewardInitOutputExistsNoForce` appear in T007 but spec Key Entities lists only the prose "output-file conflict without `--force`". Low severity — a naming refinement, not a behavior change.

## 7. The one decision the user should weigh

**SC-006 (tx-build source unchanged) has no mechanical grep task.** The spec promised one ("Grep across `lib/Amaru/Treasury/Cli/TxBuild.hs` and `lib/Amaru/Treasury/Build/` returns the same hits before and after this PR"); the analyzer flagged it as UNCOVERED. The same gap applies to FR-014 (SmokeSpec unchanged) and NFR-004/NFR-005 (no `--plan`/`--step`/array decoder, no bundle carrier).

**Two paths:**

- **Ship as-is**: orchestrator review at every slice catches forbidden-scope edits. This matches what #158 shipped (PR #165). The analyzer's READY verdict accepts this posture.
- **Add one grep task to Slice 4**: a consolidated `tx-build`-unchanged / SmokeSpec-unchanged grep test that fails if any of the four invariants is violated. Cheap (one extra hspec spec); makes the no-regression posture mechanical. **#159-specific improvement over #158**.

Recommendation: ship as-is unless the user explicitly wants stricter mechanical enforcement. Process-trust matches the precedent set by the merged #158 / PR #165.

## 8. Verdict

**READY FOR IMPLEMENTATION** — proceed to Slice 1 dispatch under the existing tasks.md, optionally with the SC-006/FR-014 grep extension to Slice 4 if the user opts for the stricter posture.
