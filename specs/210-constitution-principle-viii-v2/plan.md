# #210 plan — Constitution Principle VIII v2 + vendors.yaml registry

## Ownership split

This is a **pure docs + YAML ticket**. No production behavior, no
test suite touched, no Haskell modules edited. Per
`resolve-ticket`:

> The orchestrator may directly do non-behavioral mechanical edits:
> docs, PR body, metadata, rename-only refactors, formatter sweeps,
> config tweaks, gate.sh updates.

The entire slice is therefore **orchestrator-owned** (pane `%86`, this
ticket-orchestrator). No driver/navigator pair is dispatched.

The bottom-row panes `%87` (s1-driver for #201) and `%88` (s1-navigator
for #201) remain parked; they are the property of the sibling parked
#201 work and the epic-orchestrator will wake them after this PR
merges.

## Live-boundary diagnostic

Q: *What system boundary does this change exercise that the unit
suite cannot?*

A: **None.** The constitution is a governance doc consumed by
`/speckit.plan`'s Constitution-Compliance gate (a human-readable
process gate); `vendors.yaml` is a static registry not yet wired to
any code path. The YAML's well-formedness is verified by gate.sh
(`yq eval`); the constitution's required markers are grep-asserted.
No external service, no live ledger, no API. The plan-review
checklist's smoke item is therefore vacuous.

## Slice plan

One bisect-safe vertical slice (`S1`). No RED/GREEN — the artifact
*is* the deliverable; gate.sh verifies shape.

### S1 — rewrite Principle VIII, add vendors.yaml, CHANGELOG bullet

1. Replace the existing `### VIII. IPFS-anchored disbursement
   evidence (NON-NEGOTIABLE)` block in
   `.specify/memory/constitution.md` with the v2 text supplied by the
   brief verbatim. Existing block runs from line 106 ("`### VIII.
   IPFS-anchored disbursement evidence (NON-NEGOTIABLE)`") through the
   `[example-tx-cid]:` link reference (line 131), all replaced. The
   downstream `## Technology Constraints` section and the example-tx
   reference are not part of Principle VIII and must remain
   untouched.

2. Bump the version footer from `**Version**: 0.3.0 | **Ratified**:
   2026-05-04 | **Last Amended**: 2026-05-22` to `**Version**: 0.4.0
   | **Ratified**: 2026-05-04 | **Last Amended**: 2026-05-22`. The
   v1 amendment landed on 2026-05-22 too, so Last-Amended date is
   unchanged but Version increments to reflect the v1 → v2 step.

3. Create `vendors.yaml` at the **repository root** with the schema
   header `amaru-treasury-vendors-v1` and exactly the three entries
   from the brief (CAG payee + Cyber Castellum + Antithesis
   beneficiaries). The `onchain_address: <TBD-CAG-BECH32>` literal
   is preserved as-is so `grep TBD-CAG-BECH32` surfaces the
   follow-up gap.

4. Append one bullet to the existing `## Unreleased` section of
   `CHANGELOG.md` referencing both the amendment and the new
   registry; if no `## Unreleased` section exists, create it at the
   top of the file.

5. Run `./gate.sh` from the worktree root; expect PASS. The gate
   verifies:
   - `yq eval '.'` on `vendors.yaml` succeeds
   - `vendors.yaml` schema field is `amaru-treasury-vendors-v1`
   - the three required vendor ids are present
   - constitution version footer matches `0.4.0 | 2026-05-04 |
     2026-05-22`
   - Principle VIII section markers (`vendors.yaml` reference,
     `#### Two vendor roles`) are present
   - every commit between `origin/main` and HEAD passes
     Conventional Commits + non-empty body + Tasks: trailer (where
     applicable)

6. Create one slice commit. Subject (Conventional Commits, exact):

   ```
   docs(constitution): amend Principle VIII v2 — payee+beneficiary model + vendors.yaml registry
   ```

   Body explains motivation, names the v1 predecessor (#206 / PR
   #207 / sha cfeea015), names the downstream consumer (parked #201
   PR #209), names the deliberate `<TBD-CAG-BECH32>` placeholder
   follow-up, and ends with the Tasks: trailer.

   `docs(...):` subjects are exempt from the Tasks-trailer requirement
   in the gate, but we include it anyway for traceability — every
   task ID in `tasks.md` is closed by this single commit.

## Risks

- **Verbatim-text drift.** The brief supplies the v2 Principle VIII
  text verbatim; any unintended rephrasing turns the amendment into
  a stealth content change. Mitigation: paste verbatim from the
  brief, then `grep` the constitution for the literal section
  headers (`#### Two vendor roles`, `#### Minimum evidence set per
  disburse`, `#### Canonical legal names`) — gate.sh enforces a
  subset of these checks.
- **Version-footer dual edit.** The Ratified date stays
  `2026-05-04`; only Version bumps. The Last-Amended date already
  reads `2026-05-22` (from v1 ratification earlier today), so the
  diff for the footer is a one-character change (`0.3.0` →
  `0.4.0`). Don't accidentally bump the Ratified date.
- **vendors.yaml placement.** Must be at the repository root, not
  under `.specify/`. The brief is explicit; gate.sh checks
  `vendors.yaml` (root-relative).
- **CHANGELOG section presence.** If `CHANGELOG.md` lacks an
  `## Unreleased` section, create one rather than misplace the
  bullet under an existing released-version section.

## Carry-forward to siblings

- **#201 (parked).** Once #210 merges, the epic-orchestrator wakes
  the parked s1-driver/s1-navigator pair with a refreshed brief
  that names: `vendors.yaml` (3 vendor ids), the new 4-doc minimum
  (or 5 with cycle review), canonical-legal-name labels (e.g.
  `CYBER CASTELLUM CORPORATION`, not `Cyber Castellum`), and the
  payee CIDs already enumerated in `vendors.yaml`
  (`address_proof_cid`, `engagement_contract_cid` for CAG).
- **#196.** Disburse-wizard `--reference-*` flag surface is
  unchanged; only the manifest #201 produces will differ.
- **#202 / #203.** Plan against v2 evidence set when they start.
- **Tiny follow-up PR.** Operator fills `<TBD-CAG-BECH32>` once the
  on-chain payee address is registered.

## Plan-review checklist (self)

- [x] Connects to spec.md (P1 story: amend governance + ship
      registry, unblock #201).
- [x] Design decisions named (v2 text supplied verbatim; repo-root
      placement; preserved `<TBD-...>` placeholder).
- [x] Risks identified.
- [x] Proof strategy: gate.sh shape checks (no RED/GREEN
      applicable).
- [x] One vertical bisect-safe slice.
- [x] Live-boundary diagnostic: vacuous (governance doc + static
      YAML).
- [x] Deliverables enumerated; peer-surface check vacuous.
- [x] Orchestrator-owned-slice carve-out justified.
