# Specification Quality Checklist: Treasury Transaction CLI

**Purpose**: Validate specification completeness and quality before proceeding to planning
**Created**: 2026-05-04
**Feature**: [spec.md](../spec.md)

## Content Quality

- [x] No implementation details (languages, frameworks, APIs)
- [x] Focused on user value and business needs
- [x] Written for non-technical stakeholders
- [x] All mandatory sections completed

> Note on the redeemer Plutus-data shapes (FR-006…FR-009): these are
> *external contracts* with the on-chain validators (Sundae and
> Amaru permissions), not internal implementation details. They are
> visible to anyone inspecting transactions on chain and must be
> exact. Including them in the spec is appropriate.

## Requirement Completeness

- [x] No [NEEDS CLARIFICATION] markers remain
- [x] Requirements are testable and unambiguous
- [x] Success criteria are measurable
- [x] Success criteria are technology-agnostic (no implementation details)
- [x] All acceptance scenarios are defined
- [x] Edge cases are identified
- [x] Scope is clearly bounded
- [x] Dependencies and assumptions identified

## Feature Readiness

- [x] All functional requirements have clear acceptance criteria
- [x] User scenarios cover primary flows
- [x] Feature meets measurable outcomes defined in Success Criteria
- [x] No implementation details leak into specification

## Notes

- The redeemer-shape FRs reference the upstream validators they
  contract against ([Sundae treasury validator](https://github.com/SundaeSwap-finance/treasury-contracts/blob/main/validators/treasury.ak),
  [Amaru permissions](https://github.com/pragma-org/amaru-treasury/blob/main/lib/permissions.ak)).
  Treat these as boundary contracts, not implementation choices.
- The bash recipes in
  [`pragma-org/amaru-treasury/journal/2026/`](https://github.com/pragma-org/amaru-treasury/tree/main/journal/2026)
  are the behavioural source of truth per Constitution Principle I.
- USDM policy/asset constants are inherited from the bash defaults
  ([`defaults.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/defaults.sh)).
