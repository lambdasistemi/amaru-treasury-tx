# Specification Quality Checklist: registry-init-wizard

**Purpose**: Validate specification completeness and quality before proceeding to planning
**Created**: 2026-05-17 (rewritten 2026-05-18 for the explicit-inter-tx-unsafe design)
**Feature**: [spec.md](../spec.md)

## Content Quality

- [x] No implementation details (languages, frameworks, APIs)

  *Caveat*: The spec names Haskell types (`RegistryInitMintAnswers`, etc.) and module paths because the FRs constrain the wizard to mirror an existing module shape. These references are to **existing** in-repo entities the operator surface must match.

- [x] Focused on user value and business needs (three subcommands, operator-typed inter-tx state, explicit unsafe operator path, network safety, parity)
- [x] Written for non-technical stakeholders where the surface allows
- [x] All mandatory sections completed

## Requirement Completeness

- [x] No [NEEDS CLARIFICATION] markers remain. The carrier-shape escalation has been resolved by the 2026-05-18 explicit-inter-tx-unsafe directive.
- [x] Requirements are testable and unambiguous
- [x] Success criteria are measurable (parser test, three goldens, three round-trip properties, `tx-build` source unchanged, wizard source contains no references to the construction cores, nix-checks green)
- [x] Success criteria are technology-agnostic at the user surface
- [x] All acceptance scenarios are defined (four user stories, each with explicit Given/When/Then)
- [x] Edge cases are identified (seven listed, including the explicit acknowledgement that the wizard does NOT detect inter-step inconsistencies — by deliberate choice)
- [x] Scope is clearly bounded (Non-Goals; explicit defer-to-#163; explicit defer-to-#159/#160/#161)
- [x] Dependencies and assumptions identified — explicit Assumptions section names the operator's hand-carry responsibility, the txid-derivation step the operator runs externally, and the deliberate friction informing #163

## Feature Readiness

- [x] All functional requirements have clear acceptance criteria
- [x] User scenarios cover primary flows (per-sub-action invocation, parity per sub-action, network safety, docs)
- [x] Feature meets measurable outcomes defined in Success Criteria
- [x] No implementation details leak into specification beyond the parity/shape pins called out under Content Quality

## Notes

- **Design framing:** "Explicit inter-tx unsafe." The operator types every value that crosses a sub-step boundary; the wizard does not derive or carry inter-tx state. Mistyping a TxIn, swapping the `#0`/`#1` ordering, or pasting the wrong key hash all produce invalid intents that fail at `tx-build` (best case) or at on-chain validation (worst case). This is the deliberate "stupid" baseline; #163 will eventually promote it to a real wizard with resumable client state.
- **Override of the wizard-vs-stupid-command parent invariant:** #158 ships the stupid command for now. The principle remains in memory (`feedback_wizard_vs_stupid_command`) as the design goal for #163. The override is explicit and documented in the spec body.
- **Override of the prior "wizard simulates internally" design:** Earlier spec drafts had FR-005 require the wizard to simulate the three sub-step tx bodies internally using the production cores. That requirement is DROPPED in this rewrite. The wizard does no cross-step simulation. SC-007 enforces this by grep.
- The `tx-build` single-intent invariant is preserved. SC-006 enforces it by grep across the build surface.
- The full design vision (state-tracked bundles, cardano-cli TextEnvelope reuse, per-entry state progression, resumability as the load-bearing goal) is preserved in [#163's comment thread](https://github.com/lambdasistemi/amaru-treasury-tx/issues/163#issuecomment-4475205939) for post-#161 work.
