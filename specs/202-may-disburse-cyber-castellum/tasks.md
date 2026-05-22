# #202 tasks

Six bisect-safe slices (S1–S6). **No driver/navigator pair is
spawned** — every slice is orchestrator-executed, either as a
mechanical edit (S1, S6) or as an operator action that the
orchestrator drives interactively with the operator in the loop
(S2–S5). The fresh-subagent dispatch in S4 is read-only and produces
prose for the orchestrator to commit.

## S0 — Open clarifications to resolve before S2 runs

- [ ] **T010** Operator: confirm or supply the resolved CAG
      `onchain_address` (bech32). Update path: amend `vendors.yaml`
      via a separate small PR before S2 — `vendors.yaml` is NOT
      owned by this PR. Track status in this PR body.
- [ ] **T020** Operator + orchestrator: confirm PR #197 status
      (merged vs draft) before S2 starts. If still draft, decide:
      wait, or pin S2 to `feat/issue-196-disburse-wizard-references`
      with a `Depends-on: #197` note in the PR body.
- [ ] **T030** Operator: confirm the `--extra-signer` bech32 for the
      other `network_compliance` scope owner against the on-chain
      registry.

## S1 — Operator helper script (orchestrator-owned, mechanical edit)

- [ ] **T100** Orchestrator: write `scripts/build-may-cc-disburse.sh`
      per the plan (read manifest, validate 5-kind set, read CAG
      bech32, refuse on `<TBD>`, print/exec argv).
- [ ] **T110** Orchestrator: write a small README block under
      `scripts/` (or extend the existing one) documenting the helper.
- [ ] **T120** Orchestrator: run `./gate.sh`; expect PASS.
- [ ] **T130** Orchestrator: commit. Subject:
      `feat(scripts): operator helper to materialise may CC disburse-wizard argv from #201 manifest`.
      Tasks trailer: `Tasks: T100, T110, T120, T130`.

## S2 — Live build (operator action; orchestrator drives)

Blocker: T010 + T020 resolved.

- [ ] **T200** Orchestrator: `treasury-inspect --scope
      network_compliance` — capture USDM balance; assert ≥ 18 750.
- [ ] **T210** Orchestrator: `scripts/build-may-cc-disburse.sh --exec`
      with operator-supplied `--wallet-addr`, `--extra-signer`,
      `--metadata journal-metadata.json`, `--validity-hours 48`.
      Capture stdout + stderr to a draft rundir.
- [ ] **T220** Orchestrator: `tx-inspect --rules amaru-treasury.yaml`
      against unsigned `tx.cbor`; expect clean.
- [ ] **T230** Orchestrator: `tx-validate` against unsigned `tx.cbor`;
      expect clean or only `WithdrawalsNotInRewardsCERTS` false
      positive.
- [ ] **T240** Orchestrator: assert `body.references | length == 5`
      and the canonical labels are present verbatim.
- [ ] **T250** Orchestrator: stage the draft rundir
      (`transactions/2026/network_compliance/draft-<short>/`) with
      `intent.json`, `tx.cbor`, `tx.envelope.json`, `summary.md`.
- [ ] **T260** Orchestrator: commit. Subject:
      `feat(transactions): build may CC 18 750 USDM disburse (unsigned tx + summary)`.
      Tasks trailer: `Tasks: T200, T210, T220, T230, T240, T250, T260`.

## S3 — Witness collection (operator action; orchestrator audits)

- [ ] **T300** Operator: produce owner witness file(s); deliver to
      orchestrator via the worktree.
- [ ] **T310** Orchestrator: `attach-witness` for each witness file;
      capture `signed-tx.hex` + `signed-tx.tx`.
- [ ] **T320** Orchestrator: re-run `tx-inspect` + `tx-validate`
      post-attach; expect clean.
- [ ] **T330** Orchestrator: assert witness roster satisfies
      `permissions.ak` against the on-chain registry.
- [ ] **T340** Orchestrator: commit. Subject:
      `feat(transactions): attach owner witnesses to may CC disburse`.
      Tasks trailer: `Tasks: T300, T310, T320, T330, T340`.

## S4 — Pre-submit brief (fresh subagent)

- [ ] **T400** Orchestrator: dispatch `general-purpose` Agent
      (read-only) with the rundir path; prompt to produce
      `pre-submit-brief.md` per the plan.
- [ ] **T410** Orchestrator: commit the returned brief into the
      rundir. Subject:
      `docs(transactions): pre-submit brief for may CC disburse`.
- [ ] **T420** Orchestrator: show the brief to the operator
      **verbatim**. Wait for explicit go.

## S5 — Submit + submitted-log audit (operator-go gated)

Blocker: T420 explicit operator go.

- [ ] **T500** Orchestrator: rename draft rundir to
      `transactions/2026/network_compliance/<txid>/` using the
      txid from the signed tx.
- [ ] **T510** Operator-driven: `submit-tx` against the signed tx;
      capture `submit.log` (exit 0) and `submitted.json`.
- [ ] **T520** Orchestrator: `amaru-treasury-tx audit-submit-log
      <txid>`; expect PASS.
- [ ] **T530** Orchestrator: populate `inputs/<parent-txid>.cbor`
      for every input parent.
- [ ] **T540** Orchestrator: update `summary.md` with the final
      txid, fee, submission timestamp.
- [ ] **T550** Orchestrator: add a CHANGELOG.md Unreleased bullet
      naming the txid + amount + beneficiary.
- [ ] **T560** Orchestrator: run `./gate.sh`; expect PASS
      (archive-completeness now active).
- [ ] **T570** Orchestrator: commit. Subject:
      `feat(transactions): submit may CC 18 750 USDM disburse + submitted-log audit`.
      Tasks trailer: `Tasks: T500, T510, T520, T530, T540, T550, T560, T570`.

## S6 — Finalization (orchestrator-owned)

- [ ] **T600** Orchestrator: `git rm gate.sh` +
      `chore: drop gate.sh (ready for review)` commit.
- [ ] **T610** Orchestrator: push; `gh pr ready` against this PR.
      Append `COMPLETE <pr-url>` to STATUS.md.

## Notes

- This phase stop is **specs + plan + tasks**. T100 onwards do not
  execute until the operator green-lights S1 (and S0 clarifications
  are resolved for S2+).
- Per the resolve-ticket protocol the tasks.md checkboxes get
  amended onto each slice commit at acceptance time.
- No RED/GREEN test pair applies: the proof is `tx-inspect` +
  `tx-validate` clean at three transitions + `audit-submit-log` pass
  + archive completeness enforced by `gate.sh`.
