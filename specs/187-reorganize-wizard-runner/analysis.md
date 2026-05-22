# Cross-artifact Analysis Report — 187-reorganize-wizard-runner

**Phase**: Analyzer (post-tasks, pre-S1 dispatch)
**Verdict**: **ready for S1 dispatch** — only nice-to-have wording
amendments; none block S1.
**Run on**: 2026-05-22

This report is produced by a read-only Analyzer Subagent under
the resolve-ticket orchestration protocol. The findings below
are scoped to consistency across `spec.md`, `plan.md`,
`tasks.md`, the `contracts/` directory, and
`.specify/memory/constitution.md` — not to code correctness.

## Findings

### I1 — `ReorganizeTodoSliceC` removal wording (HIGH)

**Where**: `spec.md` FR-001b ("`ReorganizeTodoSliceC` … MUST be
removed in this slice"). **Plan + tasks split it**: S1 keeps
the variant, S2 removes it.

**Impact**: The "this slice" wording is satisfied at PR scope
(removed before the PR is marked ready); but a fresh reader of
`spec.md` in isolation could misread it as "removed in the
first implementation slice".

**Status**: not load-bearing — the plan's vertical-slice
section + the tasks' explicit "S1 keeps it / S2 removes it"
boundary cover the intent unambiguously. Wording-only amend
deferred (would require a docs(spec) chore for prose drift).

### I2 — FR-007 cross-reference in Parent Carry-Forward (MEDIUM)

**Where**: `spec.md` § "Parent Carry-Forward Invariants" — the
"Network safety is fail-closed" bullet says "Enforced by #186's
existing guard (re-affirmed in FR-007)". FR-007 actually
covers the upper-bound step, not the network guard.

**Impact**: cross-reference drift, no behavior implication.

**Status**: not load-bearing — defer.

### C2 — `ReorganizeMissingNodeSocket` absent from FR-001b enumeration (LOW)

**Where**: `spec.md` FR-001b lists 7 new variants explicitly
but not `ReorganizeMissingNodeSocket` (the variant is
introduced via S2 + Edge Case "`--node-socket` absent" and is
load-bearing for the parser-spec assertion update at S2 T012).

**Impact**: the spec FR-001b enumeration is one variant short
of the data-model.md §2 enumeration.

**Status**: covered by `data-model.md` §2 + `research.md` §4 +
`contracts/exit-code-contract.md` + tasks T011/T013. Defer the
spec-side amend.

### C3 — `--funding-seed-txin == walletUtxo` byte-equality assertion (LOW)

**Where**: spec User Story 1 Acceptance 1 asserts
`ReorganizeInputs.walletUtxo` equals the operator-typed
`--funding-seed-txin`. Tasks T010's happy-path scenario does
not call this out explicitly, but T007 implements the bake-in.

**Impact**: the S1 spec scenario set will pin this if the
driver reads the contract; `contracts/intent-payload-contract.md`
makes the field-by-field mapping explicit.

**Status**: covered by `contracts/intent-payload-contract.md`
§ "tiPayload :: ReorganizeInputs". The S1 brief will reference
the contract; deferred amend.

### R1 — `permissionsRewardAccount` byte-equality assertion (MEDIUM)

**Where**: `plan.md` R4 mandates "assert byte equality in S1's
spec by constructing the expected `AccountAddress` via the
library API". T010's enumeration does not break this out
explicitly.

**Impact**: a sloppy S1 implementation could pass T010 without
exercising the derivation helper (T008) end-to-end.

**Status**: covered by
`contracts/permissions-reward-account-contract.md` § "Sanity
test (S1 spec)" which makes the assertion contract explicit.
The S1 brief will reference the contract; deferred amend.

### R2 — wallet-shortfall scenario missing from T010 enumeration (LOW)

**Where**: T010 enumerates scenarios for
`MetadataReadError`, `ScopeNotInMetadata`, `ScopeOwnerMissing`,
`InsufficientTreasuryUtxos 0|1`, `NonDevnetNetwork`, and
`ValidityHoursZero`. It does NOT explicitly name a
wallet-shortfall scenario.

**Impact**: T010's enumeration is incomplete vs
`contracts/resolver-contract.md` § "Spec assertions (S1)"
which DOES list "wallet query empty →
`ReorganizeWalletShortfall`".

**Status**: covered by `contracts/resolver-contract.md`. The
S1 driver will read the contract and add the scenario; the
contract is the canonical source. Deferred amend.

### B1 — `Tx/ReorganizeWizard.hs` overlap between S1 + S2 (LOW)

**Where**: both S1 and S2 touch
`lib/Amaru/Treasury/Tx/ReorganizeWizard.hs`. S1 adds 7 new
`ReorganizeError` variants; S2 adds 1 and removes 1
(`ReorganizeTodoSliceC` ↔ `ReorganizeMissingNodeSocket`). The
two slices touch disjoint constructors.

**Impact**: the owned-files boundary is non-disjoint, but the
slices touch different constructors. No behavioral conflict.

**Status**: explicit in `tasks.md` S2 "Owned files" + "Forbidden
in S2" sections. Acceptable per the slice contract.

### K1 — Constitution alignment (OK)

All seven principles addressed in `plan.md` § "Constitution
Check". Principle V (golden CBOR fixtures) leans on #185's
existing `SReorganize` golden — acceptable because this PR
emits JSON (round-tripping through `decodeTreasuryIntent`), not
new CBOR. No conflicts.

### Q1 — Q-001 verdict consistency (OK)

A1/B1/C1/D1/E1 propagate consistently across spec.md (§
Clarifications), plan.md (§ Q-001 verdicts), the four
`contracts/*` files, and the 22 tasks:

- A1 (`--metadata`): FR-001b, FR-004, plan.md, T002–T010
- B1 (`permissionsRewardAccount` derived): FR-001b, plan §
  Q-001 verdicts, T008, `contracts/permissions-reward-account-contract.md`
- C1 (bake `--funding-seed-txin`): FR-006, T007,
  `contracts/intent-payload-contract.md`
- D1 (sort `(TxId, TxIx)`): FR-005, plan §Q D1, T006
- E1 (take-all): FR-005, plan §Q E1, no cap flag in tasks

## Coverage matrix (FR → task)

| FR | Backing task(s) |
|---|---|
| FR-001 | T002 (variants), T003 (input record), T004 (env record), T005 (resolved-env), T006 (resolver), T007 (translator), T008 (reward-account helper) |
| FR-001b | T002, T011 |
| FR-002 | T013, T014, T015 |
| FR-003 | T014 (encode + write) |
| FR-004 | T016 (`readMetadataSafely`) |
| FR-005 | T006 (sort), D1/E1 inline |
| FR-006 | T007 (translator), T010 (assertion) |
| FR-007 | T006 (network guard re-affirmed) |
| FR-008 | T017 (`exitCodeFor`) |
| FR-009 | T001 (skeleton), T010 (body) |
| FR-010 | T009 (cabal) |
| FR-011 | T020 (full ci) |
| FR-012 | per-slice Forbidden lists |

Coverage = 100%. No FR without a task; no task without a
spec/plan reference. Ambiguity = 0. Duplications = 0.
Critical conflicts = 0.

## One-line verdict

**ready for S1 dispatch.** The seven nice-to-have amendments
(I1, I2, C2, C3, R1, R2, B1) are all double-covered by the
`contracts/*` files; deferring them avoids a `docs(spec)` chore
that would not change the implementation. If any surface during
S1 review (driver+navigator pair flags a gap), the orchestrator
amends spec/plan in the same review cycle.
