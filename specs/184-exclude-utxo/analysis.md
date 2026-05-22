# Cross-Artifact Analysis Report — #184

Output of the resolve-ticket Analyzer Subagent run on
`spec.md`, `plan.md`, and `tasks.md` (initial versions at
`5168ef88`), plus the project constitution at
`.specify/memory/constitution.md`. The orchestrator looped back
through `tasks.md` to fix the issues below before pair dispatch.

## Verdict (initial pass)

**Loop back to tasks.md** for: missing FR-009 coverage, tighter
FR-005 pool attribution, FR-006 ordering, FR-011 parity, and a
small wording correction on T046.

## Findings and resolution

| ID | Severity | Issue | Resolution |
|---|---|---|---|
| C1 | MEDIUM | FR-011 "identical phrasing across wizards" not asserted; implicit via shared parsers. | Added **T045a** in Slice 8: assert `--help` parity across the seven wizards, OR document that parity is guaranteed by every wizard consuming the shared `excludeUtxoP` / `extraTxInP` helpers. |
| C2 | LOW | FR-005 pool attribution (`wallet`/`treasury`/`both`) not RED-asserted. | Added **T010b** in Slice 2 (canary) covering all three branches; extended **T011, T019, T024, T029, T034, T039** GREEN tasks to include pool-attribution in the log line. |
| C3 | LOW | Inert exclusion log signal + `--extra-tx-in` already-in-pool dedup not in Slice 1 tests. | Extended **T003** to cover both edge cases in the shared `filterPool` test set. |
| C4 | LOW | `--extra-tx-in` multi-ref ordering preservation not asserted. | Extended **T003** to assert input-order preservation for multi-ref `--extra-tx-in`. |
| C5 | MEDIUM-CRITICAL | FR-009 "extra input not found on wallet" error had **no backing task**. | Added **T010a** in Slice 2 (canary) as the RED proof; extended **T011, T019, T024, T029, T034, T039** GREEN tasks to implement the not-on-wallet error per wizard. |
| I1 | LOW | Plan-status SHAs unverifiable from artifacts alone. | No change: orchestrator verified `c6339cbc` (spec) and `62c1e256` (gate.sh) are on the branch. |
| I2 | LOW | T046 wording "merged-state branch" is impossible pre-merge. | Reworded T046: "at HEAD before the drop commit". |
| D1 | LOW | FR-013 (gate.sh) is a workflow rule, not a product requirement. | No change: existing project specs treat `./gate.sh` as a product-level commitment for the PR lifecycle. |
| O1 | LOW | T029/T039 GREEN didn't make all-modes byte stability explicit. | Tightened T029 and T039 to call out "BOTH call sites" explicitly. |
| B1 | LOW | Slice 1 cabal exposure may trigger `-Wunused-top-binds`. | Added a warning to the Slice 1 worker brief: every export must be exercised by tests. |
| B2 | LOW | Slice 2 worker should be warned not to amend Slice 1. | Added a "Slice 1 is FROZEN" note to T011. |
| K1 | INFO | Constitution Check fully addressed; no conflicts. | No change. |
| K2 | INFO | The `reorganize-wizard` scope drop is a planning-phase refinement, not a constitution conflict. | No change. |
| A1 | INFO | Asciinema deferral satisfies the "documented operator follow-up with verifiable artifact" rule (T047 issue + T048 PR-body link + T040 docs link). | No change. |
| S1 | INFO | Live-boundary diagnostic is sound — flags act pre-selector on already-fetched candidate pool. | No change. |

## Coverage Summary (after loop-back)

| Req | Backing tasks |
|---|---|
| FR-001 (--exclude-utxo) | T007, T014, T021, T026, T031, T036 |
| FR-002 (--extra-tx-in) | T008, T016, T022, T027, T032, T037 |
| FR-003 (outref format + pre-query validation) | T001, T004 |
| FR-004 (filter before selector) | T007, T011, T015, T019 |
| FR-005 (log + pool attribution) | T010b, T011, T019, T024, T029, T034, T039 |
| FR-006 (extraTxIns order + dedup) | T003, T008, T011 |
| FR-007 (contradiction pre-query) | T002, T006, T013, T020, T025, T030, T035 |
| FR-008 (shortfall names excluded refs) | T009, T017, T023, T028, T033, T038 |
| FR-009 (not-on-wallet error) | T010a, T011, T019, T024, T029, T034, T039 |
| FR-010 (byte-identical no-flag) | T010, T018, T023, T028, T033, T038 |
| FR-011 (identical `--help` phrasing) | T045a (and the shared parsers from Slice 1) |
| FR-012 (shared module) | T004, T005 |
| FR-013 (gate.sh + nix flake check) | T012, T049 |
| SC-001 .. SC-006 | T046 + per-slice RED+GREEN |

Total tasks after loop-back: 53 (T001–T050 plus T010a, T010b, T045a).

## Next step

After this report is committed, re-dispatch the Analyzer Subagent
for a confirmation pass over the corrected tasks.md before any
pair-programming slice runs.
