---
description: "Task list for #161 - CLI DevNet smoke proof"
---

# Tasks: CLI DevNet Smoke Proof

**Input**: Design documents from `specs/161-cli-devnet-smoke/`  
**Prerequisites**: [spec.md](./spec.md), [plan.md](./plan.md)  
**Tests**: Required. Every behavior-changing slice ships RED + GREEN in one bisect-safe commit.

## Format: `[ID] [P?] [Story?] Description`

- **[P]**: Parallel-safe inside the same slice or sidecar lane. It must not edit the same files as another active worker.
- **[Story]**: Maps to the primary user story in `spec.md`.
- Paths are relative to the worktree root.

## Slice and Commit Mapping

| Slice | Worker | Primary story | Commit subject |
|---|---|---|---|
| 1 | `cli-smoke/static-guard` | US2 | `test(smoke): guard CLI smoke against devnet runner fallback (#161)` |
| 2 | `cli-smoke/host-vault` | US1 + US2 | `feat(smoke): add DevNet CLI smoke host and vault preflight (#161)` |
| 3 | `cli-smoke/registry-stake` | US1 | `feat(smoke): drive registry and stake bootstrap via CLI (#161)` |
| 4 | `cli-smoke/governance` | US1 + US2 | `feat(smoke): drive governance materialization via CLI (#161)` |
| 5 | `cli-smoke/disburse` | US1 | `feat(smoke): verify CLI disburse after materialization (#161)` |
| 6 | orchestrator | US3 | `docs(161): document CLI DevNet smoke proof` |
| 7 | orchestrator | finalization | `chore: drop gate.sh (ready for review) (#161)` |

## Phase 1: Static Guard and Script Scaffold

**Goal**: Create the public smoke entrypoint and make runner fallback mechanically detectable before any live work.

**Independent Test**: Unit/static tests fail if `scripts/smoke/smoke.sh` or the host imports/calls forbidden library-runner surfaces.

- [X] T001 (commit: c2cab920) [P] [US2] Add `test/unit/Amaru/Treasury/Smoke/CliDevnetSmokeSpec.hs` with a RED test that scans `scripts/smoke/smoke.sh`, `app/devnet-cli-smoke-host/Main.hs` when present, and any smoke helper scripts for forbidden strings: `runDevnet`, `Amaru.Treasury.Devnet.Runner`, `cabal test devnet-tests`, and `DEVNET_SMOKE_PHASE`.
- [X] T002 (commit: c2cab920) [P] [US1] Add executable `scripts/smoke/smoke.sh` scaffold with `--run-dir`, `--inside-devnet`, `--phase`, `--timeout-seconds`, `--force`, and `--help`; it must preflight required tools and create the run-dir layout without starting DevNet yet.
- [X] T003 (commit: c2cab920) [US1] Add `just devnet-cli-smoke` to invoke `scripts/smoke/smoke.sh`.
- [X] T004 (commit: c2cab920) [US2] Add a governance reachability audit note in `specs/161-cli-devnet-smoke/plan.md` or a checked test fixture documenting that legacy `SmokeSpec` submits a separate vote tx while the shipped CLI currently has no vote action.
- [X] T005 (commit: c2cab920) [US2] Register the new static test in `amaru-treasury-tx.cabal` and make it pass without weakening the forbidden-string list.

Checkpoint: `./gate.sh` green; static no-fallback guard is active.

## Phase 2: DevNet Host and Vault Preflight

**Goal**: Start a real DevNet without using transaction runners, generate deterministic DevNet key fixtures, and prove the script can create vaults/sign via shipped CLI.

- [X] T006 (commit: 588f052c) [P] [US1] Add `app/devnet-cli-smoke-host/Main.hs` that copies the pinned genesis, applies the governance patch, calls `withCardanoNode`, exports socket/network/run-dir/key paths, and executes `scripts/smoke/smoke.sh --inside-devnet`.
- [X] T007 (commit: 588f052c) [P] [US1] Add deterministic DevNet key fixture generation for genesis funding and voter keys in the host; write cardano-cli payment signing-key envelopes with `0600` permissions and export their key hashes.
- [X] T008 (commit: 588f052c) [US1] Add vault preflight in `scripts/smoke/smoke.sh`: create DevNet-only vaults via `amaru-treasury-tx vault create --signing-key-file ... --vault-passphrase-fd ...`, then sign a harmless fixture unsigned tx through `witness` and `attach-witness`.
- [X] T009 (commit: 588f052c) [US2] Extend static guard tests so the host may import `Cardano.Node.Client.E2E.Devnet` but still fails on any transaction runner import/call.
- [X] T010 (commit: 588f052c) [US1] Add `jq` to the dev shell if the script uses it, and update preflight failure text to name the missing dependency.

Checkpoint: `just devnet-cli-smoke --phase preflight` passes and `./gate.sh` green.

## Phase 3: Registry and Stake/Reward CLI Phases

**Goal**: Prove the first five bootstrap sub-transactions are reachable through shipped CLI commands.

- [X] T011 (commit: 73cf97b3) [P] [US2] Extend the static guard so product smoke paths fail on external `cardano-cli` usage; the smoke must not hide address derivation, tx id extraction, chain queries, or protocol inspection behind `cardano-cli`.
- [X] T012 (commit: 73cf97b3) [US1] Replace the stale `cardano-cli` funding-address derivation in `registry-stake` with Amaru-owned output from the host or a shipped `amaru-treasury-tx` surface, and remove `cardano-cli` from phase preflight requirements.
- [X] T013 (commit: 1affc52b) [US1] Implement a shared shell function that runs `tx-build`, one or more `witness` calls with expected key hashes, `attach-witness`, `submit`, and tx-id/report consistency checks using Amaru-owned outputs only.
- [X] T014 (commit: 1affc52b) [US1] Implement `registry-init-wizard seed-split`, `mint`, and `reference-scripts` through the #175 `--bootstrap` CLI path; submit them, record tx ids/output refs, and run `registry-init-wizard write-artifacts`.
- [X] T015 (commit: 1affc52b) [US1] Implement `stake-reward-init-wizard script-account` and `plain-account` through CLI; submit both and write/verify `accounts.json`.
- [X] T016 (commit: 1affc52b) [US1] Add chain assertions for registry/reference-script anchors and treasury/permissions reward-account artifact fields without external `cardano-cli` queries.

Checkpoint: `just devnet-cli-smoke --phase registry-stake` passes and `./gate.sh` green.

## Phase 4: Governance Materialization CLI Phase

**Goal**: Prove governance withdrawal materialization is reachable through shipped CLI commands, or fail with the explicit missing-surface diagnostic.

- [X] T017 [US1] Implement `governance-withdrawal-init-wizard proposal` through CLI using `registry.json`, `accounts.json`, funding/voter key hashes, and the fixed DevNet governance anchor.
- [X] T018 [US1] Build/sign/submit the proposal tx through `tx-build`, `witness`, `attach-witness`, and `submit`; record proposal tx id and voter base output details.
- [X] T019 [US2] Add reward/enactment polling that does not call the legacy in-process vote path; if reward accrual does not happen under patched genesis, exit non-zero with `missing-shipped-governance-vote` and retain diagnostics.
- [X] T020 [US1] Implement `governance-withdrawal-init-wizard materialization` through CLI using observed rewards; build/sign/submit and verify the materialized treasury UTxO.
- [X] T021 [US1] Write `governance-withdrawal-init/materialized.json`, phase summary, and chain assertion transcripts in the run directory.

Checkpoint: `just devnet-cli-smoke --phase governance` either passes with materialization evidence or fails with `missing-shipped-governance-vote`; the PR cannot be marked ready on the missing-surface path.

## Phase 5: Disburse CLI Phase and Final Summary

**Goal**: Spend the materialized treasury UTxO through the shipped disburse operator path and prove beneficiary receipt plus treasury reduction.

- [X] T022 [US1] Implement `disburse-wizard` through CLI against the materialized treasury artifact and a DevNet beneficiary address.
- [X] T023 [US1] Build/sign/submit the disburse tx through shipped CLI commands.
- [X] T024 [US1] Verify beneficiary output address/lovelace, consumed materialized input, and reduced treasury output; write `disburse-submit/beneficiary.json` and summary artifacts.
- [X] T025 [US1] Write final `summary.json` linking all phase summaries, artifact paths, tx ids, run-dir, socket path, and verification status.

Checkpoint: `just devnet-cli-smoke` full run passes and `./gate.sh` green.

## Phase 6: Docs, Gate, and Runner-Retention Decision

**Orchestrator-owned**.

- [ ] T026 [US3] Update `README.md` to show `just devnet-cli-smoke` as the CLI/operator proof and retain `just devnet-smoke` as the library proof command.
- [ ] T027 [US3] Update `docs/local-devnet-smoke.md` with proof-layer split, expected run-dir artifacts, governance vote reachability behavior, and troubleshooting diagnostics.
- [ ] T028 [US3] Decide and document whether `lib/Amaru/Treasury/Devnet/*Init.hs` runners remain; default is keep them because `SmokeSpec` is the library proof layer.
- [ ] T029 Extend `gate.sh` with the no-fallback static test and the ticket-specific live CLI smoke command once the live run is reliable enough for branch verification.
- [ ] T030 Refresh PR #171 body and parent #156 comment with the delivered proof, any governance-vote finding, and verification evidence.

## Phase 7: Finalization

**Orchestrator-owned**.

- [ ] T031 Run full `./gate.sh` and record the CLI smoke run directory and tx ids in the PR body.
- [ ] T032 Run finalization audit: every behavior commit has a `Tasks:` trailer, every task has a matching checked box, docs/spec/plan/tasks/PR body agree, and `gate.sh` is absent only in the final commit.
- [ ] T033 Remove `gate.sh` in `chore: drop gate.sh (ready for review) (#161)`, push, and mark PR #171 ready for review.

## Dependencies and Execution Order

Behavior-changing slices are mostly serial because `scripts/smoke/smoke.sh`, the host, cabal registration, and run-dir contract are shared surfaces:

```text
Slice 1 -> Slice 2 -> Slice 3 -> Slice 4 -> Slice 5 -> Slice 6 -> Slice 7
```

Safe parallelism is limited to read-only scouting or within-slice tasks marked `[P]`. Do not run multiple writers against `scripts/smoke/smoke.sh` or `app/devnet-cli-smoke-host/Main.hs` concurrently.

## Notes

- Workers must not call `AskUserQuestion`; they use the tmux-pane-worker Q/A files.
- Implementation workers do not push. The orchestrator reviews, amends task checkboxes into the returned commit, runs `./gate.sh`, then pushes.
- If Slice 4 returns `missing-shipped-governance-vote`, stop implementation and update #156/#161 before adding any new shipped surface.
