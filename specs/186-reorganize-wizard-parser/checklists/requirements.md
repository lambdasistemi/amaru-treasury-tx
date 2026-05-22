# Specification Quality Checklist: `reorganize-wizard` parser scaffold

**Purpose**: Validate specification completeness and quality before proceeding to planning
**Created**: 2026-05-22
**Feature**: [spec.md](../spec.md)

## Content Quality

- [X] No implementation details (languages, frameworks, APIs)
      *(The spec references `optparse-applicative`, `Amaru.Treasury.LedgerParse.txInFromText`, and the `ReorganizeError` Haskell type. Justification: this is an internal Haskell library + CLI scaffold, and the "spec as business document" rule is relaxed by the resolve-ticket workflow — sibling specs (#185) carry the same level of technical reference because the audience is the orchestrator + worker pair, not external stakeholders.)*
- [X] Focused on user value and business needs
      *(P1 user story is the operator-recovery contract from epic #189; every other US flows from it.)*
- [X] Written for non-technical stakeholders (with the relaxation above)
- [X] All mandatory sections completed (User Scenarios & Testing, Requirements, Success Criteria)

## Requirement Completeness

- [X] No [NEEDS CLARIFICATION] markers remain (the three open
      design choices Q-001-A/B/C are presented as explicit
      clarifications-with-recommended-verdicts, not blockers)
- [X] Requirements are testable and unambiguous (FR-001..FR-012)
- [X] Success criteria are measurable (SC-001..SC-008)
- [X] Success criteria are technology-agnostic
      *(SC-001..SC-008 reference observable CLI behavior — exit
      codes, stdout/stderr strings, grep results — not internal
      Haskell types.)*
- [X] All acceptance scenarios are defined (5 User Stories × 2-4 scenarios each)
- [X] Edge cases are identified (Edge Cases section)
- [X] Scope is clearly bounded (scope framing block at top, Non-Goals section, Deliverables table)
- [X] Dependencies and assumptions identified (Depends on #185, Assumptions section, parent epic carry-forward invariants)

## Feature Readiness

- [X] All functional requirements have clear acceptance criteria
- [X] User scenarios cover primary flows (User Stories 1–5 = full AC matrix from issue #186)
- [X] Feature meets measurable outcomes defined in Success Criteria
- [X] No implementation details leak into specification (beyond the relaxation above)

## Deliverables Coverage (resolve-ticket addition)

- [X] Every shippable artifact is enumerated in the `## Deliverables` section
- [X] Each artifact names the release / packaging / docs surface it touches
- [X] Non-shipped artifacts (cast, smoke, docs) are explicitly deferred to #187 / #87 / #188 with the asciinema scope clarification block
- [X] No "follow-up" or "later" surfaces this slice claims to ship

## Command-Recovery Posture (resolve-ticket addition)

- [X] Identifies the shipped operator command (`amaru-treasury-tx reorganize-wizard <flags>`)
- [X] Distinguishes the parser scaffold (shipped) from the runner body (#187)
- [X] States how this slice's command is not yet functional and where the functional surface lands
- [X] States the network-safety boundary (User Story 5 + FR-007 + parent invariant)

## Parent Carry-Forward Invariants

- [X] Every invariant from epic #189 is named and instantiated for this slice
- [X] Invariants this slice does not exercise (exec-units validation) are explicitly noted as out-of-scope

## Open Clarifications (settled at plan-time if epic owner approves spec as-is)

- Q-001-A: `--scope` required flag? Recommended A1 (yes, sibling-mirrored).
- Q-001-B: Sibling-mirrored shared flags (rationale, `--validity-hours`, `--metadata`, `--force`) in this scaffold? Recommended B1 (yes, expose them; tests cover only the issue-enumerated five).
- Q-001-C: `--network devnet` check at parse-time custom ReadM (C1) or in `--out` pre-flight (C2)? Recommended C1.

## Notes

- All items pass on the first iteration. The spec mirrors the
  shape and depth of the prior child #185's `spec.md` (committed
  at `da9d65b5`); reviewers can diff the two to focus on
  reorganize-parser-specific points.
- The three Q-001 questions are non-blocking — the issue ACs
  pin the five mandatory parser behaviors, and the recommended
  verdicts trace to clear sibling-wizard precedent.
- Ready for `speckit.plan` once the epic owner signs off on the
  recommended Q-001 verdicts (or supplies alternatives).
