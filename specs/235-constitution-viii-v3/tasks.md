# #235 tasks

One bisect-safe slice (**S1**, mechanical edit) + one finalization
slice (**S2**). All orchestrator-owned; no driver/navigator pair.

## S1 — constitution + vendors.yaml v3 amendment

- [X] **T100** Edited `.specify/memory/constitution.md` Principle
      VIII: kept intro / two-vendor-roles / destination-address /
      canonical legal names / final non-violation paragraph
      UNCHANGED; added `#### Beneficiary contract publication
      carve-out (NDA-blocked)`, `#### Yearly cycle /
      contract-collapse`, and `#### Minimum evidence sets (summary
      table)` with the four-row table from spec.md; folded the
      "redacted invoice acceptable" sentence into the existing slot 4
      definition; preserved the NDA-omission `justification` field
      requirement.
- [X] **T110** Bumped constitution version footer to
      `**Version**: 0.5.0 | **Ratified**: 2026-05-04 | **Last
      Amended**: 2026-05-22`.
- [X] **T120** Added schema-notes comment block at the top of
      `vendors.yaml` documenting nullability of
      `engagement_contract_cid` under carve-out A, plus the v3
      `review_cycle` enum reminder. No existing CID values changed.
- [X] **T130** `./gate.sh` PASS.
- [X] **T140** One bisect-safe slice commit. Subject:
      `docs(constitution): amend Principle VIII v3 — NDA carve-out + yearly-cycle collapse`.
      Tasks trailer: `Tasks: T100, T110, T120, T130, T140`.

## S2 — Finalization (orchestrator-owned)

- [ ] **T200** `git rm gate.sh` +
      `chore: drop gate.sh (ready for review)` commit; push;
      `gh pr ready` against this PR.
- [ ] **T210** Comment on the Antithesis disburse ticket once it's
      opened, noting that v0.5.0 is the constitutional anchor for
      its 3-doc evidence set. Comment on PR #232 (and the not-yet-
      opened Antithesis PR) that #235 has merged and they can rebase
      onto refreshed main. Append `COMPLETE <pr-url>` to STATUS.md.

## Notes

- No RED/GREEN test pair applies (no behaviour change).
- No `--reference-*` flag surface change; `disburse-wizard` accepts
  arbitrary cardinality already.
- The Antithesis disburse ticket — separate from this one — is the
  consumer that will exercise the new minimum in practice.
- The redacted Antithesis invoice pin is also a separate operator
  action, also not in this PR's scope.
