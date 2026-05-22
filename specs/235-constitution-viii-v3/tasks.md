# #235 tasks

One bisect-safe slice (**S1**, mechanical edit) + one finalization
slice (**S2**). All orchestrator-owned; no driver/navigator pair.

## S1 — constitution + vendors.yaml v3 amendment

- [ ] **T100** Edit `.specify/memory/constitution.md` Principle VIII:
      keep intro / two-vendor-roles / destination-address / canonical
      legal names / final non-violation paragraph UNCHANGED; replace
      the v2 "Minimum evidence set" sub-section with the v3 version
      that:
      * Adds `#### Beneficiary contract publication carve-out (NDA-blocked)`.
      * Adds `#### Yearly cycle / contract-collapse`.
      * Adds `#### Minimum evidence sets (summary table)` with the
        four-row table from spec.md.
      * Preserves the requirement that NDA-blocked omissions MUST be
        acknowledged in `body.justification`.
- [ ] **T110** Bump the constitution version footer to `**Version**:
      0.5.0` and update `**Last Amended**` to today (2026-05-22).
- [ ] **T120** Edit `vendors.yaml`: add a top-of-file comment (or a
      short YAML key like `schema_notes`) documenting that
      `engagement_contract_cid` MAY be `null` (or omitted) for an
      NDA-blocked vendor under Principle VIII v3 carve-out A. Do NOT
      change any existing CID values in this PR.
- [ ] **T130** Run `./gate.sh`; expect PASS.
- [ ] **T140** One bisect-safe slice commit. Subject:
      `docs(constitution): amend Principle VIII v3 — NDA carve-out + yearly-cycle collapse`.
      Body references #235 and the v0.5.0 version footer bump. Ends
      with `Tasks: T100, T110, T120, T130, T140`.

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
