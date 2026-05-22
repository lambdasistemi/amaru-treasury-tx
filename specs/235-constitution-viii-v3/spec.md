# #235 — Constitution Principle VIII v3 (NDA carve-out + yearly-cycle collapse)

Full motivation and concrete numeric table live in
[issue #235](https://github.com/lambdasistemi/amaru-treasury-tx/issues/235);
this spec mirrors the issue at the moment of branch creation. The issue
is the source of truth.

## P1 user story

As the **Amaru treasury operator**, when a beneficiary's engagement
contract is NDA-blocked from publication (Antithesis Operations LLC),
I need Principle VIII to permit a disburse with a smaller evidence
set — payee_contract + payee_address_proof + beneficiary_invoice
(redacted) — while preserving every other invariant (canonical legal
names, verified payee address, signed metadata). And when the
beneficiary's review_cycle is yearly and the annual renewal contract
IS the cycle's plan/review evidence, no separate cycle-review
document should be required.

The amendment unblocks the May 2026 Antithesis disburse (sibling of
[#202](https://github.com/lambdasistemi/amaru-treasury-tx/issues/202))
without weakening the v2 invariants for any other vendor.

## Acceptance criteria

### Constitution edit

- [ ] `.specify/memory/constitution.md` Principle VIII rewritten to
      include two new sub-sections:
      `#### Beneficiary contract publication carve-out (NDA-blocked)`
      and `#### Yearly cycle / contract-collapse`.
- [ ] The new sub-sections precede the existing
      `#### Canonical legal names` and final non-violation paragraph,
      which remain UNCHANGED in wording.
- [ ] The existing v2 sub-sections (two vendor roles, destination
      address, minimum evidence set, canonical legal names) remain
      load-bearing; the carve-outs ADD optionality, they do NOT
      remove any v2 constraint.
- [ ] A new sub-section
      `#### Minimum evidence sets (summary table)` codifies the
      four resulting min-doc cases in a table:

  | beneficiary review cycle | NDA-blocked? | min docs | slots |
  |---|---|---|---|
  | periodic (mo/bi-mo/qtr/etc.) | no | 5 | payee_contract + payee_address_proof + beneficiary_contract + beneficiary_invoice + beneficiary_cycle_review |
  | periodic | yes | 4 | payee_contract + payee_address_proof + beneficiary_invoice + beneficiary_cycle_review |
  | yearly (renewal-as-cycle) | no | 4 | payee_contract + payee_address_proof + beneficiary_contract + beneficiary_invoice |
  | yearly (renewal-as-cycle) | yes | **3** | payee_contract + payee_address_proof + beneficiary_invoice |
  | payee == beneficiary (slots 1/3 merge) | n/a | 3 | (collapsed) contract + payee_address_proof + invoice |

- [ ] Version footer bumped: `**Version**: 0.5.0 | **Ratified**:
      2026-05-04 | **Last Amended**: 2026-05-22` (or amendment date).

### `vendors.yaml` edit

- [ ] `vendors.yaml` updated so `antithesis_operations_llc` may have
      `engagement_contract_cid` set to `null` (or the field omitted)
      to denote NDA-blocked, without violating the schema.
- [ ] Optional: schema docstring / comment at the top of
      `vendors.yaml` (or in a `schemas/` file if we add one) records
      that `engagement_contract_cid` is nullable when the vendor is
      NDA-blocked AND the constitution's carve-out applies.

### Docs

- [ ] (Optional, may defer) A short paragraph in `docs/` or operator
      runbook explaining what counts as an acceptable redacted
      invoice (amount + period + beneficiary identity must remain
      legible; counter-party-blind or dollar-amount-blind redactions
      otherwise are operator-side discipline).

## Operator command shape impact

`disburse-wizard` already accepts an arbitrary number of
`--reference-uri/--reference-type/--reference-label` triplets; the
amendment doesn't change the CLI flag surface. The wizard caller for
the Antithesis disburse simply passes 3 `--reference-*` triplets
instead of 5 (or 4), and adds a `--justification` paragraph naming
the NDA prohibition. No tooling change required.

## Exclusions / non-goals

- No source-code edits to `lib/`, `app/`, `test/`, or any helper
  script.
- No changes to the on-chain Aiken validators or to
  `treasury-contracts/` (the validators don't inspect
  `references[]`; the constitution is the only enforcement layer for
  this).
- No changes to `transactions/2026/network_compliance/may-references.json`
  in this PR — that's updated separately (under the Antithesis
  disburse ticket) once the redacted invoice CID exists.
- No re-pinning of any existing reference document (Cyber Castellum
  evidence and CAG payee evidence stay as-is on IPFS).
- No re-signing of the already-submitted #202 disburse — it carries
  the full 5-doc set and is unaffected by the amendment.

## Deliverables

| Artifact | Surface |
|---|---|
| `.specify/memory/constitution.md` (v2 → v3) | The constitution itself; the source-of-truth doc. |
| `vendors.yaml` (nullable engagement_contract_cid for NDA-blocked) | Vendor registry. |
| Optional: `docs/redaction.md` or runbook paragraph | Operator-facing guidance. |

No new executable. No new release surface. No asciinema cast.

## Constitutional alignment

- **Principle I** (faithful port of bash recipes) — unaffected; bash
  recipes don't enforce or interpret references[].
- **Principle IV** (build, never sign or submit) — unaffected.
- **Principle V** (test-first) — unaffected (no behavior change).
- **Principle VII** (label-1694 body-shape) — unaffected; references[]
  cardinality is independent of CBOR body shape.

## Non-claims

- This PR does NOT pin the redacted Antithesis invoice — that's a
  separate operator action with its own ticket.
- This PR does NOT submit any mainnet transaction.
- This PR does NOT amend any other principle. Principles I–VII and
  IX+ (if present) remain untouched.
