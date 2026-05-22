# #235 plan — Principle VIII v3 amendment

## Ownership split

This is a **constitution-edit ticket**. There is no behaviour-changing
code; no helper script; no archive; no mainnet operator action.
Everything is text edits in `.specify/memory/constitution.md` plus a
small nullability relaxation in `vendors.yaml`. The orchestrator
writes all of it directly under the mechanical-edit carve-out — no
driver/navigator pair is dispatched.

## Live-boundary diagnostic

Q: *What system boundary does this change exercise that the unit suite
cannot?*

A: **None.** The on-chain Aiken validators do not inspect the rationale
`references[]` cardinality (that's an off-chain operator-side
discipline enforced by `vendors.yaml` + the constitution + the
disburse helper script). No live-boundary smoke applies; no
`tx-validate` or `tx-inspect` step is meaningful for this PR.

The downstream verification is **operator behaviour**: future
disburse-wizard invocations for NDA-blocked beneficiaries pass 3 (or
4) `--reference-*` triplets instead of 5, with an explicit
`--justification` paragraph naming the prohibition. The Antithesis
disburse (a separate ticket) is the first consumer that exercises
v3's relaxed minimum; its PR will reference v0.5.0 in its rationale
text.

## Slice plan

Two slices:

### S1 — Constitution + vendors.yaml edit (orchestrator-owned, mechanical edit)

1. Edit `.specify/memory/constitution.md` Principle VIII:
   * Keep the existing intro paragraph, two-vendor-roles, destination
     address, canonical legal names, and final non-violation
     paragraph UNCHANGED.
   * Replace the v2 "Minimum evidence set per disburse" sub-section
     with the v3 version that adds the two carve-outs (NDA-blocked
     and yearly cycle / contract-collapse) and the summary table.
   * Bump the version footer to v0.5.0; update `**Last Amended**`.
2. Edit `vendors.yaml`:
   * Note in a top-of-file comment (or a short README) that
     `engagement_contract_cid` MAY be `null` (or omitted) when the
     vendor is NDA-blocked AND the constitution's carve-out A
     applies.
   * Leave the existing `antithesis_operations_llc` entry's CID as-is
     for now (don't pre-emptively null it; that's the Antithesis
     disburse ticket's job once the redacted-contract decision is
     final).

### S2 — Finalization (orchestrator-owned)

- `git rm gate.sh` + `chore: drop gate.sh (ready for review)`.
- Push; `gh pr ready`.

## Risks

- **Wording-level friction with auditors.** The two carve-outs add
  optionality. An external auditor reading v3 cold might worry the
  carve-out swallows the rule. Mitigation: the four-row summary
  table makes the minimum count concrete per case; the NDA carve-out
  REQUIRES an explicit justification paragraph on every disburse it
  applies to, which auditors can grep for. No silent omission is
  permitted.
- **Off-chain audit-only document mention.** Carve-out A says a
  non-IPFS internal-only reference MAY be retained off-chain. This is
  not enforced by anything; it's purely a recommendation. If we
  later want to enforce it (e.g., hash registered in `vendors.yaml`)
  that's a v4 amendment.
- **Redaction quality is operator-side.** The constitution doesn't
  prescribe a redaction format — it just says "redacted invoice is
  acceptable provided amount + period + beneficiary identity
  remain legible". Future ambiguity around redaction quality is an
  operator-runbook problem, not a constitutional one.

## Carry-forward to siblings

- The Antithesis disburse (sibling of #202) cites Principle VIII v3
  and v0.5.0 in its rationale's `justification` paragraph (per
  carve-out A).
- The redacted Antithesis invoice pin is a separate ticket; once it
  lands, `transactions/2026/network_compliance/may-references.json`
  is updated to point `may-2026-antithesis.beneficiary_invoice.uri`
  at the new CID and `beneficiary_contract` is removed.
- Future yearly-cycle NDA-blocked vendors inherit the same
  3-doc minimum automatically.

## Plan-review checklist (orchestrator-self)

- [x] Connects to spec.md (P1 = NDA carve-out + yearly cycle collapse).
- [x] Names the ownership split (orchestrator-only, no pair).
- [x] Identifies risks (above) — wording, off-chain reference,
      redaction quality.
- [x] Defines proof strategy: no on-chain proof needed (validators
      don't enforce references[] cardinality); operator behaviour
      via the Antithesis disburse ticket is the downstream test.
- [x] One vertical slice (S1) + finalization (S2).
- [x] Live-boundary smoke vacuous (validators don't read this).
- [x] Deliverables enumerated; no release pipeline surface.
