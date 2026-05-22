# #202 tasks

Six bisect-safe slices (S1–S6). **No driver/navigator pair is
spawned** — every slice is orchestrator-executed, either as a
mechanical edit (S1, S6) or as an operator action that the
orchestrator drives interactively with the operator in the loop
(S2–S5). The fresh-subagent dispatch in S4 is read-only and produces
prose for the orchestrator to commit.

## S0 — Open clarifications to resolve before S2 runs

- [X] **T010** Orchestrator: amend `vendors.yaml` with the resolved
      CAG `onchain_address` extracted from the address-of-record proof
      email pinned at
      `ipfs://bafkreihl2qvl4coduzqwg4hhh7l7go5ym7y5d7w3flzb5kpxvvquj3i3qm`:
      `addr1q8qrds2nnx7clx3kcpp2l0eu45twmdcahsfu9m0xcwy59j6xz3vs0hnfaz9nhje8z34kfnds4jyk7hs6dnrag6e2lfgqtyf4rl`.
      Commit subject: `fix(vendors): resolve crypto_accounting_group onchain_address`.
- [X] **T020** Resolved 2026-05-22: rebased #202 onto
      `feat/issue-196-disburse-wizard-references`; PR #213's base
      retargeted to that branch. Re-rebase onto `main` once #197
      merges.
- [X] **T030** Resolved 2026-05-22: `--extra-signer ops_and_use_cases`
      (scope alias preferred over the raw hex
      `f3ab64b0…d23e2e` from `journal/2026/metadata.json`).

## S1 — Operator helper script (orchestrator-owned, mechanical edit)

- [X] **T100** Orchestrator: write `scripts/build-may-cc-disburse.sh`
      per the plan (read manifest, validate 5-kind set, read CAG
      bech32, refuse on `<TBD>`, print/exec argv with real flag
      surface `--unit usdm --amount <1e-6 USDM> --beneficiary-addr`).
- [X] **T110** Orchestrator: usage documentation lives in the
      script's `--help` block (subsumed; no separate scripts/README).
- [X] **T120** Orchestrator: run `./gate.sh`; expect PASS.
- [X] **T130** Orchestrator: commit. Subject:
      `feat(scripts): operator helper to materialise may CC disburse-wizard argv from #201 manifest`.
      Tasks trailer: `Tasks: T100, T110, T120, T130`.

## S2 — Live build (operator action; orchestrator drives)

Blocker: T010 + T020 resolved.

- [X] **T200** `treasury-inspect --scope network_compliance` (live
      mainnet read 2026-05-22) returned 414 892.255806 USDM available
      across 55 UTxOs (largest single = 10 174.81 USDM). Threshold
      assertion 414 892 255 806 ≥ 18 750 000 000 holds (22× headroom).
- [X] **T210** `scripts/build-may-cc-disburse.sh --exec` produced
      `tx.cbor.hex` (2 204-byte unsigned Conway tx body) on the
      first try post-#216 merge. Wizard log records the 2 treasury
      UTxOs selected (`77b1b046…#1` + `3c3d5332…#1`) and confirms
      `leftoverLov=4612003` (= full treasury input lovelace, vs the
      pre-#216 buggy `2612003`). One helper-script tweak: shorten
      the default `--description` to 61 bytes (was 95 — over
      Cardano's per-text metadatum cap).
- [X] **T220** `tx-inspect --rules amaru-treasury.yaml`
      against unsigned `tx.cbor.hex`: clean (treasury inputs +
      wallet + 4 reference inputs + 2 outputs + permissions
      0-lovelace withdrawal + required signers visible).
- [X] **T230** `tx-validate --n2c-socket-path /code/cardano-mainnet/ipc/node.socket
      --network-magic 764824073 --input <hex>` returned
      `{"exit_code":0,"status":"structurally_clean"}`. All UTxO
      sources resolved via n2c. No `WithdrawalsNotInRewardsCERTS`
      false positive.
- [X] **T240** `body.references[]` carries exactly 5 entries with
      canonical legal labels verbatim:
      `Contract - CRYPTO ACCOUNTING GROUP`,
      `Address-of-record proof - CRYPTO ACCOUNTING GROUP`,
      `Contract - CYBER CASTELLUM CORPORATION`,
      `Invoice #3508 - CYBER CASTELLUM CORPORATION`,
      `May2026 cycle review - CYBER CASTELLUM CORPORATION`.
- [X] **T250** Draft rundir
      `transactions/2026/network_compliance/draft-may-cc/` populated:
      `intent.json`, `tx.cbor.hex`, `tx.envelope.json`, `build.log`,
      `tx-build.log`, `report.json`, `summary.md`. Renamed to
      `<txid>/` at S5 once the on-chain txid is confirmed
      (`a8156039625f75d2bb6f6ec34cbb23f62370478cd5be1baafbc862c359457f4b`).
- [X] **T260** One slice commit. Subject:
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
