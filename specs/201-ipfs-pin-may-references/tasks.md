# #201 tasks

One bisect-safe slice (**S1**). Driver = `%87`, navigator = `%88`.

## S1 — pin + collect + assemble (driver writes; navigator reviews)

- [ ] **T010** Driver: read `PINATA_JWT` from `~/.secrets/pinata/jwt`
      into a subshell env var; verify `curl -sS -H "Authorization:
      Bearer $PINATA_JWT" https://api.pinata.cloud/data/testAuthentication`
      returns success. Do not echo the JWT.
- [ ] **T020** Driver: resolve the 3 already-pinned CIDs (Castellum
      contract, Castellum invoice, Antithesis contract) via Pinata
      `GET /data/pinList`. Disambiguate by `metadata.name`; on
      ambiguity Q-file the orchestrator.
- [ ] **T030** Driver: pin the 2 missing PDFs (Castellum May 2026
      plan acceptance, Antithesis invoice) via `POST
      /pinning/pinFileToIPFS`. Source-PDF paths come from operator
      inline (orchestrator forwards via Q/A). Record CIDs +
      invoice numbers.
- [ ] **T040** Driver: write
      `transactions/2026/network_compliance/may-references.json` per
      schema `amaru-treasury-may-references-v1`. Labels:
      `Contract - Cyber Castellum`,
      `Invoice #<N> - Cyber Castellum`,
      `May2026 plan acceptance - Cyber Castellum`,
      `Contract - Antithesis`,
      `Invoice #<N> - Antithesis`. Every `type` = `"Other"`. Every
      `uri` = `ipfs://<CID>`.
- [ ] **T050** Driver: write `scripts/verify-may-references.sh`
      (executable). For each ref in the manifest, `curl -fsS -I
      "https://ipfs.io/ipfs/${cid}" >/dev/null`; print PASS/FAIL per
      CID and exit non-zero on first failure.
- [ ] **T060** Driver: add an Unreleased bullet to `CHANGELOG.md`
      referencing #201 and the manifest path.
- [ ] **T070** Driver: run `./gate.sh`; expect PASS. Navigator
      observes; reports any RED/GREEN-order or secret-leak concern.
- [ ] **T080** Driver: create one slice commit. Subject:
      `feat(transactions): may 2026 network_compliance disburse-reference manifest`.
      Body: non-empty, references Principle VIII (v0.3.0) and #205,
      ends with `Tasks: T010, T020, T030, T040, T050, T060, T070,
      T080`. No JWT, no Pinata account ID, no API token in body.
- [ ] **T090** Navigator: pre-commit diff review on driver's HEAD
      candidate; secret-leak grep
      (`grep -rE 'eyJ|PINATA_JWT=' .`); commit-shape check; sign off
      via STATUS.md `REVIEW-APPROVED green`.
- [ ] **T100** Orchestrator: rerun `./gate.sh` at HEAD; rerun
      secret-leak grep; amend HEAD to check off tasks T010–T100 in
      this `tasks.md`; push to PR #209; log `SLICE-DONE S1`.

## S2 — finalization (orchestrator-owned)

- [ ] **T200** Orchestrator: `git rm gate.sh` + `chore: drop gate.sh
      (ready for review)` commit; push; `gh pr ready 209`; append
      `COMPLETE https://github.com/lambdasistemi/amaru-treasury-tx/pull/209`
      to STATUS.md.

## Notes

- Tasks T010–T070 are not separable into RED/GREEN pairs — they are
  data assembly + a live-boundary verification script. Proof of
  correctness is gate.sh + verify-script output, captured in the
  slice's WIP.md.
- The single slice maps to one bisect-safe commit; T090 (navigator
  sign-off) and T100 (orchestrator amend) do not introduce new
  commits — T090 is a review act, T100 is the in-place amend that
  carries the tasks.md checkboxes onto the same SHA the driver
  produced.
