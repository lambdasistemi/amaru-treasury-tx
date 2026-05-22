# #201 tasks

One bisect-safe slice (**S1**). After #210 landed and the v2 schema
became binding, all 5 CIDs are known (4 pinned during the original
A-001 run, 1 added during post-#210 operator review) and the manifest
work collapses to a mechanical literal-JSON write. The orchestrator
takes this slice directly under the mechanical-edit carve-out (no
RED/GREEN test pair applicable; gate.sh + verify-may-references.sh are
the proof).

## S0 — orchestration amendments (orchestrator-owned, completed)

- [X] **T000** Rebase `201-ipfs-pin-may-references` onto fresh
      `origin/main` (post-#210 / sha 078a1ce2).
- [X] **T001** Amend `spec.md`, `plan.md`, `tasks.md` to reflect
      Principle VIII v2 / schema v2.
- [X] **T002** Extend `gate.sh` to validate the v2 schema
      (`disbursements[]` + per-disbursement minimum evidence set).

## S1 — write the manifest (orchestrator-owned mechanical edit)

- [X] **T040** Write
      `transactions/2026/network_compliance/may-references.json` per
      schema `amaru-treasury-may-references-v2`. Two disbursements:
      `may-2026-cyber-castellum` (18750 USDM, 5 refs including cycle
      review), `may-2026-antithesis` (400000 USDM, 4 refs, no cycle
      review per yearly cadence). Canonical labels verbatim:
      `Contract - CRYPTO ACCOUNTING GROUP`,
      `Address-of-record proof - CRYPTO ACCOUNTING GROUP`,
      `Contract - CYBER CASTELLUM CORPORATION`,
      `Invoice #3508 - CYBER CASTELLUM CORPORATION`,
      `May2026 cycle review - CYBER CASTELLUM CORPORATION`,
      `Contract - ANTITHESIS OPERATIONS LLC`,
      `Invoice INV-635 - ANTITHESIS OPERATIONS LLC`.
- [X] **T050** Write `scripts/verify-may-references.sh` (executable).
      Dedupes URIs across disbursements, `curl -fsS -I
      "$IPFS_GATEWAY/${cid}"`; prints PASS/FAIL per CID; exits
      non-zero on first failure.
- [X] **T060** Add an Unreleased bullet to `CHANGELOG.md` referencing
      #201, the manifest path, and Principle VIII v2.
- [X] **T070** Run `./gate.sh`; expect PASS.
- [X] **T080** Create one slice commit. Subject:
      `feat(transactions): may 2026 network_compliance disburse-reference manifest (v2 schema)`.
      Body: non-empty, references Principle VIII v2 (v0.4.0) and #210.
      Ends with `Tasks: T040, T050, T060, T070, T080`.

## S2 — finalization (orchestrator-owned)

- [X] **T200** Orchestrator: `git rm gate.sh` + `chore: drop gate.sh
      (ready for review)` commit; push; `gh pr ready 209`; append
      `COMPLETE https://github.com/lambdasistemi/amaru-treasury-tx/pull/209`
      to STATUS.md.

## Notes

- T010–T030 (Pinata authentication, pinList, pin missing PDFs) were
  executed during the original A-001 run before the #210 amendment;
  all 5 CIDs are now known and inlined in the worker brief, so the
  remaining work is pure data assembly with no live Pinata calls.
- This slice is one bisect-safe commit; T040–T070 fold into the single
  commit produced by T080. The tasks.md checkboxes are amended onto
  that same commit.
