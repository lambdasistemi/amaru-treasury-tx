# #210 tasks

Single bisect-safe slice (**S1**), orchestrator-owned (docs + YAML
mechanical edit). No driver/navigator dispatch.

## S1 — rewrite Principle VIII v2, add vendors.yaml, CHANGELOG bullet

- [ ] **T010** Replace `### VIII. IPFS-anchored disbursement evidence
      (NON-NEGOTIABLE)` section in `.specify/memory/constitution.md`
      verbatim with the v2 text from the worker brief (payee +
      beneficiary roles, 2+2+1 evidence-set structure,
      canonical-legal-name rule). Preserve every other section.
- [ ] **T020** Bump constitution version footer: `**Version**: 0.3.0`
      → `**Version**: 0.4.0`. Keep `Ratified: 2026-05-04` and
      `Last Amended: 2026-05-22`.
- [ ] **T030** Create `vendors.yaml` at repository root with schema
      `amaru-treasury-vendors-v1` and the 3 entries
      (`crypto_accounting_group` payee with
      `<TBD-CAG-BECH32>` literal placeholder,
      `cyber_castellum_corporation` beneficiary,
      `antithesis_operations_llc` beneficiary). Match the YAML from
      the worker brief exactly.
- [ ] **T040** Add one `## Unreleased` bullet to `CHANGELOG.md`
      referencing both the Principle VIII v2 amendment and the new
      `vendors.yaml` registry. Create the `## Unreleased` section if
      it does not exist.
- [ ] **T050** Run `./gate.sh` from the worktree root; expect
      `gate.sh PASS`. If it fails, fix the cause in-place (do not
      add a separate commit until S1 is committed).
- [ ] **T060** Single slice commit. Subject:
      `docs(constitution): amend Principle VIII v2 — payee+beneficiary model + vendors.yaml registry`.
      Body explains motivation, names #206 / PR #207 (sha
      cfeea015) as v1 predecessor, names parked #201 PR #209 as the
      downstream consumer, names the `<TBD-CAG-BECH32>` follow-up,
      and ends with `Tasks: T010, T020, T030, T040, T050, T060`.
- [ ] **T070** Push to PR #211; rerun `./gate.sh` at HEAD; log
      `SLICE-DONE S1` and `COMMIT <sha>` in
      `/tmp/epic-205/amaru-treasury-tx-210/STATUS.md`. Amend HEAD to
      check off T010–T070 in this `tasks.md`.

## S2 — finalization (orchestrator-owned)

- [ ] **T100** `git rm gate.sh` + `chore: drop gate.sh (ready for
      review)` commit; push; `gh pr ready 211`; append `COMPLETE
      https://github.com/lambdasistemi/amaru-treasury-tx/pull/211`
      to STATUS.md.

## Notes

- This ticket has no RED/GREEN pair — `docs:` slice with no
  executable behavior. The "test" is gate.sh's structural shape
  check on `vendors.yaml` and on the constitution version footer +
  v2 markers.
- T070's amend is the only legitimate slice-commit rewrite (per
  resolve-ticket invariants): it folds the tasks.md checkbox flip
  into the same SHA the slice produced.
- T100 (drop gate.sh) is a separate commit on the branch, sequenced
  after S1 lands.
