# Specification Quality Checklist: disburse-wizard --reference flags + RationaleBody references[]

**Purpose**: Validate specification completeness and quality before proceeding to planning.
**Created**: 2026-05-22
**Feature**: [spec.md](../spec.md)

## Content Quality

- [x] No implementation details (languages, frameworks, APIs)
      *Caveat: spec names `lib/Amaru/Treasury/AuxData.hs`, the field
       `rbReferences`, and module paths as a load-bearing parity contract
       with the existing codebase. This is intentional for a library-shape
       change — the worker pair must touch exactly these names. The
       acceptance scenarios and success criteria themselves remain
       technology-agnostic (operator commands + on-chain shape).*
- [x] Focused on user value and business needs
      *(IPFS audit chain for vendor disbursements.)*
- [x] Written for non-technical stakeholders
      *(Scenarios are operator-level; FRs name the modules because
       reviewers need to verify the parity contract.)*
- [x] All mandatory sections completed

## Requirement Completeness

- [x] No [NEEDS CLARIFICATION] markers remain
- [x] Requirements are testable and unambiguous
- [x] Success criteria are measurable
- [x] Success criteria are technology-agnostic
      *(SC-001/SC-002/SC-003 are CBOR equality + on-chain inspection;
       SC-005 names `nix flake check` because it's the project's
       canonical gate — same as every other PR in this repo.)*
- [x] All acceptance scenarios are defined
- [x] Edge cases are identified
- [x] Scope is clearly bounded
- [x] Dependencies and assumptions identified

## Feature Readiness

- [x] All functional requirements have clear acceptance criteria
- [x] User scenarios cover primary flows
- [x] Feature meets measurable outcomes defined in Success Criteria
- [x] No implementation details leak into specification
      *(Same caveat as above: module names are the parity contract,
       not implementation choices.)*

## Resolve-Ticket Additions

- [x] Paramount user story is P1 (Scope Owner preparing vendor disburse).
- [x] Command-recovery rule: spec names the operator command
      (`disburse-wizard --reference-uri … --reference-label …`) as
      the shipped surface. Smoke proof (golden tests) does not replace
      the command.
- [x] **Deliverables enumeration**: spec lists every artifact + every
      surface (library shape, schema, CLI, tests, cabal version,
      CHANGELOG, release matrix, README docs, asciinema cast).
- [x] **Asciinema cast for executable surface change**: listed as a
      deliverable (`docs/assets/asciinema/disburse-wizard-references.cast`)
      per the vertical-deliverables rule.
- [x] Discovery command for peer surfaces recorded in spec.

## Notes

- Validation passed on first iteration; no spec revisions required.
- The "implementation details" caveat (naming `AuxData.hs` and
  `rbReferences`) is deliberate and documented in the spec — the
  upstream parity contract with the d6c14625 mainnet precedent is
  load-bearing, and the worker pair needs the exact module + field
  names to honor it.
- Ready for `/speckit.clarify` (none needed) or `/speckit.plan`.
