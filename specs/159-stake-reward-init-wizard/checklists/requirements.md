# Specification Quality Checklist: stake-reward-init-wizard

**Purpose**: Validate specification completeness and quality before proceeding to planning
**Created**: 2026-05-18
**Feature**: [spec.md](../spec.md)

## Content Quality

- [x] No implementation details (languages, frameworks, APIs)

  *Caveat*: The spec names Haskell types (`StakeRewardInitScriptAccountInputs`, `StakeRewardInitPlainAccountInputs`, `DevnetStakeRewardRegistry`) and module paths because the FRs constrain the wizard to mirror an existing module shape shipped by #157 and to consume the registry artifact produced by #158. These references are to **existing** in-repo entities the operator surface must match.

- [x] Focused on user value and business needs (two independent subcommands, operator-typed funding seed, registry artifact carried across the #158→#159 boundary, explicit unsafe operator path, network safety, parity with library cores)
- [x] Written for non-technical stakeholders where the surface allows
- [x] All mandatory sections completed

## Requirement Completeness

- [x] No [NEEDS CLARIFICATION] markers remain. The carrier-shape question is resolved by carrying #158's explicit-inter-tx-unsafe directive forward unchanged.
- [x] Requirements are testable and unambiguous
- [x] Success criteria are measurable (parser test, two goldens, two round-trip properties, `tx-build` source unchanged, wizard source contains no references to the construction cores, nix-checks green)
- [x] Success criteria are technology-agnostic at the user surface
- [x] All acceptance scenarios are defined (four user stories, each with explicit Given/When/Then)
- [x] Edge cases are identified (eight listed, including the explicit acknowledgement that the wizard does NOT detect a stale `--funding-seed-txin` or an off-chain `registry.json` — by deliberate choice)
- [x] Scope is clearly bounded (Non-Goals; explicit defer-to-#163; explicit defer-to-#160/#161)
- [x] Dependencies and assumptions identified — explicit Assumptions section names the operator's hand-carry responsibility (registry path + funding TxIn) and the deliberate friction informing #163

## Feature Readiness

- [x] All functional requirements have clear acceptance criteria
- [x] User scenarios cover primary flows (per-sub-action invocation, parity per sub-action, network safety, docs)
- [x] Feature meets measurable outcomes defined in Success Criteria
- [x] No implementation details leak into specification beyond the parity/shape pins called out under Content Quality

## Notes

- **Design framing:** "Explicit inter-tx unsafe." The operator types the funding seed TxIn and hand-carries the `registry.json` path across the boundary from #158's bootstrap. The wizard does not derive or simulate inter-tx state. A stale funding TxIn, a wrong `--registry` path, or a registry from an unsubmitted bootstrap all produce invalid intents that fail at `tx-build` (best case) or at on-chain validation (worst case). This is the deliberate "stupid" baseline carried over from #158; #163 will eventually promote both wizards into a real wizard with resumable client state.
- **Override of the wizard-vs-stupid-command parent invariant:** #159 ships the stupid command for now, mirroring #158. The principle remains in memory (`feedback_wizard_vs_stupid_command`) as the design goal for #163. The override is explicit and documented in the spec body.
- **Structural simplification vs #158:** #159's two sub-actions are independent (no required ordering, no chained seed TxIns between them). The inter-step state for #159 comes from a single file (`registry.json`) and a single operator flag (`--funding-seed-txin`) per invocation. This is strictly simpler than #158's three-step chain.
- **No new schema work:** the two `SomeTreasuryIntent` variants for stake-reward-init were already added in #157; `docs/assets/intent-schema.json` is unchanged here (FR-013).
- The `tx-build` single-intent invariant is preserved. SC-006 enforces it by grep across the build surface.
- The full design vision (state-tracked bundles, cardano-cli TextEnvelope reuse, per-entry state progression, resumability as the load-bearing goal) is preserved in [#163's comment thread](https://github.com/lambdasistemi/amaru-treasury-tx/issues/163#issuecomment-4475205939) for post-#161 work.
