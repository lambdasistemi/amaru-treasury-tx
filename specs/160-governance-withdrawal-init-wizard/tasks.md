---
description: "Task list for #160 - governance-withdrawal-init-wizard"
---

# Tasks: governance-withdrawal-init-wizard

**Input**: Design documents from `specs/160-governance-withdrawal-init-wizard/`
**Prerequisites**: [spec.md](./spec.md), [plan.md](./plan.md)
**Tests**: Required. Every behavior-changing slice ships RED + GREEN in one bisect-safe commit.

## Format: `[ID] [P?] [Story?] Description`

- **[P]**: Parallel-safe inside the same slice or sidecar lane. It must not edit the same files as another active worker.
- **[Story]**: Maps to the primary user story in `spec.md`.
- Paths are relative to the worktree root unless explicitly absolute.

## Slice and Commit Mapping

| Slice | Worker | Primary US | Commit subject |
|---|---|---|---|
| Sidecar A | `gov-init/fixture-deposit-scout` | Support | no commit - read-only note |
| Sidecar B | `gov-init/docs-scout` | Support | no commit - read-only note |
| 1 | `gov-init/scaffold` | US1 + US3 | `feat(cli): scaffold governance-withdrawal-init-wizard parser (#160)` |
| 2 | `gov-init/proposal` | US1 + US2 + US3 + US4 | `feat(tx): governance-withdrawal-init-wizard proposal (#160)` |
| 3 | `gov-init/materialization` | US1 + US2 + US3 | `feat(tx): governance-withdrawal-init-wizard materialization (#160)` |
| 4 | `gov-init/property-grep` | US2 + US3 | `test(tx): enforce governance-withdrawal wizard boundaries (#160)` |
| 5 | orchestrator | US5 | `docs(160): governance-withdrawal-init-wizard operator path` |
| 6 | orchestrator | finalization | `chore: drop gate.sh (ready for review) (#160)` |

## Phase 1: Setup

No setup tasks. Branch, draft PR, and `gate.sh` already exist.

## Phase 2: Read-only Sidecars

These sidecars may run while Slice 1 is coding. They are deliberately no-edit lanes: they reduce uncertainty for Slices 2, 3, and 5 without racing the implementation branch.

- [x] T000A [P] Fixture/deposit scout. Inspect existing `test/golden/Support/GovernanceWithdrawalInitFixtures.hs`, `lib/Amaru/Treasury/Devnet/GovernanceWithdrawalInit.hs`, `lib/Amaru/Treasury/Devnet/GovernanceWithdrawalInit/Core.hs`, and the chain-context/pparams helpers. Output `/tmp/gov-init/sidecars/fixture-deposit.md` with: canonical fixture constructors to reuse, artifact loader names, cross-validator name, registry/accounts fixture derivation notes, pparams/deposit field names, and the conservative fee/headroom recommendation. No repository edits. Completed as read-only sidecar output.
- [x] T000B [P] Docs scout. Inspect `README.md` and `docs/local-devnet-smoke.md`. Output `/tmp/gov-init/sidecars/docs-map.md` with exact insertion points for the two-subcommand operator path, witness contract, DRep-equals-proposer caveat, deposit-aware shortfall explanation, unsafe inter-step carry warning, and #161/#163 forward references. No repository edits. Completed as read-only sidecar output.

## Phase 3: Slice 1 - Parser scaffold

**Goal**: Add the public CLI surface and typed answer records, with runner stubs only.

**Independent Test**: CLI parser tests prove help text, required flags, malformed `TxIn`, malformed hex hashes, positive amounts, missing flags, and `--out` preflight behavior.

**Worker brief**: One bisect-safe commit. Do not push. Do not edit specs, docs, README, `gate.sh`, `IntentJSON.hs`, `Build.hs`, or existing devnet core/build modules. Commit body must include `Tasks: T001, T002, T003, T004, T005, T006, T007, T008, T009`.

Owned files:
- `lib/Amaru/Treasury/Tx/GovernanceWithdrawalInitWizard.hs`
- `lib/Amaru/Treasury/Cli/GovernanceWithdrawalInitWizard.hs`
- `lib/Amaru/Treasury/Cli.hs`
- `app/amaru-treasury-tx/Main.hs`
- `amaru-treasury-tx.cabal`
- `test/unit/Amaru/Treasury/Cli/GovernanceWithdrawalInitWizardParserSpec.hs`

Tasks:

- [x] T001 [P] [US1] Add parser test: `governance-withdrawal-init-wizard --help` lists `proposal` and `materialization`. Completed in Slice 1 commit.
- [x] T002 [P] [US1] Add parser tests: `proposal --help` lists shared flags plus `--funding-stake-key-hash`, `--voter-key-hash`, `--withdrawal-amount-lovelace`, `--anchor-url`, `--anchor-hash`. Completed in Slice 1 commit.
- [x] T003 [P] [US1] Add parser tests: `materialization --help` lists shared flags plus `--rewards-lovelace`. Completed in Slice 1 commit.
- [x] T004 [P] [US3] Add parser test: malformed `--funding-seed-txin` is rejected via `Amaru.Treasury.LedgerParse.txInFromText`. Completed in Slice 1 commit.
- [x] T005 [P] [US3] Add parser tests: malformed `--funding-stake-key-hash` and `--voter-key-hash` are rejected unless exactly 56 hex characters. Completed in Slice 1 commit.
- [x] T006 [P] [US3] Add parser test: malformed `--anchor-hash` is rejected unless exactly 64 hex characters. Completed in Slice 1 commit.
- [x] T007 [P] [US3] Add parser tests: zero or negative `--withdrawal-amount-lovelace` and `--rewards-lovelace` are rejected. Completed in Slice 1 commit.
- [x] T008 [P] [US3] Add parser/preflight tests: missing required flags, missing output parent directory, and existing `--out` without `--force` fail before any runner work. Completed in Slice 1 commit.
- [x] T009 [US1] Implement `GovernanceWithdrawalInitProposalAnswers`, `GovernanceWithdrawalInitMaterializationAnswers`, `GovernanceWithdrawalInitError`, hex/amount readers, parser, runner stubs, cabal exposure, top-level CLI wiring, and executable dispatch wiring. Runner stubs must exit non-zero and must not query chain or write intent JSON. Completed in Slice 1 commit.

Checkpoint: parser tests and `./gate.sh` green at HEAD.

## Phase 4: Slice 2 - Proposal resolver, translation, parity, and deposit shortfall

**Goal**: Make `proposal` functional end-to-end and prove byte-for-byte parity with the existing library core.

**Independent Test**: New proposal golden proves wizard intent -> `tx-build` CBOR equals `buildGovernanceWithdrawalProposalCore` output on equivalent fixture inputs. Unit tests prove devnet guard, artifact parse errors, cross-validation, round-trip JSON, and deposit-aware wallet shortfall.

**Worker brief**: One bisect-safe commit. Do not push. Use sidecar note `/tmp/gov-init/sidecars/fixture-deposit.md` if present. Do not edit materialization runner/translation except placeholder network-guard scaffolding needed by tests. Commit body must include `Tasks: T010, T011, T012, T013, T014, T015, T016, T017, T018`.

Owned files:
- `lib/Amaru/Treasury/Tx/GovernanceWithdrawalInitWizard.hs`
- `lib/Amaru/Treasury/Cli/GovernanceWithdrawalInitWizard.hs`
- `test/golden/Support/GovernanceWithdrawalInitWizardFixtures.hs`
- `test/golden/Amaru/Treasury/Tx/GovernanceWithdrawalInitWizardProposalSpec.hs`
- `test/fixtures/governance-withdrawal-init-wizard/registry.json`
- `test/fixtures/governance-withdrawal-init-wizard/accounts.json`
- `test/fixtures/governance-withdrawal-init-wizard/proposal-answers.json`
- `test/fixtures/governance-withdrawal-init-wizard/proposal-intent.json`
- `test/unit/Amaru/Treasury/Tx/GovernanceWithdrawalInitWizardSpec.hs`
- `test/unit/Amaru/Treasury/Tx/GovernanceWithdrawalInitWizardNetworkGuardSpec.hs`

Tasks:

- [x] T010 [P] [US2] Add `Support.GovernanceWithdrawalInitWizardFixtures` and proposal parity golden co-derived from existing governance-withdrawal library fixtures. Completed in Slice 2 commit.
- [x] T011 [P] [US1] Add round-trip test for proposal `SomeTreasuryIntent` JSON. Completed in Slice 2 commit.
- [x] T012 [P] [US3] Add network-guard tests: `mainnet`, `preprod`, and `preview` fail with `GovernanceWithdrawalInitNonDevnetNetwork` before wallet/artifact work. Completed in Slice 2 commit.
- [x] T013 [P] [US1] Add registry parse-error tests: missing file, unparseable JSON, wrong phase, wrong network. Completed in Slice 2 commit.
- [x] T014 [P] [US1] Add stake-reward accounts parse-error tests: missing file, unparseable JSON, wrong phase, wrong network. Completed in Slice 2 commit.
- [x] T015 [P] [US1] Add cross-validation mismatch test for `accounts.treasury.scriptHash != registry.treasuryScriptHash`. Completed in Slice 2 commit.
- [x] T016 [P] [US4] Add deposit-aware wallet-shortfall test naming `govActionDeposit`, `stakeDeposit`, `drepDeposit`, estimated fee/headroom, and total. Completed in Slice 2 commit.
- [x] T017 [US3] Implement `GovernanceWithdrawalInitEnv`, resolver environment, artifact parsing via `readDevnetGovernanceWithdrawalRegistry` and `readDevnetGovernanceStakeRewardAccounts`, cross-validation via `validateGovernanceWithdrawalPrerequisites`, devnet guard, wallet selection, upper-bound-slot sampling, and deposit-aware shortfall. Completed in Slice 2 commit.
- [x] T018 [US1] Implement pure `governanceWithdrawalInitProposalToIntent` and wire the `proposal` runner to resolve -> translate -> `encodeSomeTreasuryIntent` -> atomic `--out` write honoring `--force`. Completed in Slice 2 commit.

Checkpoint: proposal subcommand functional; proposal golden, unit tests, and `./gate.sh` green.

## Phase 5: Slice 3 - Materialization

**Goal**: Make `materialization` functional and prove parity with the existing library core.

**Worker brief**: One bisect-safe commit. Do not push. Use sidecar note `/tmp/gov-init/sidecars/fixture-deposit.md` if present. Commit body must include `Tasks: T019, T020, T021, T022, T023, T024`.

Owned files:
- `lib/Amaru/Treasury/Tx/GovernanceWithdrawalInitWizard.hs`
- `lib/Amaru/Treasury/Cli/GovernanceWithdrawalInitWizard.hs`
- `test/golden/Support/GovernanceWithdrawalInitWizardFixtures.hs`
- `test/golden/Amaru/Treasury/Tx/GovernanceWithdrawalInitWizardMaterializationSpec.hs`
- `test/fixtures/governance-withdrawal-init-wizard/materialization-answers.json`
- `test/fixtures/governance-withdrawal-init-wizard/materialization-intent.json`
- `test/unit/Amaru/Treasury/Tx/GovernanceWithdrawalInitWizardSpec.hs`
- `test/unit/Amaru/Treasury/Tx/GovernanceWithdrawalInitWizardNetworkGuardSpec.hs`

Tasks:

- [x] T019 [P] [US2] Extend fixture helper and add materialization parity golden. Completed in Slice 3 commit.
- [x] T020 [P] [US1] Add round-trip test for materialization `SomeTreasuryIntent` JSON. Completed in Slice 3 commit.
- [x] T021 [P] [US3] Refine materialization network-guard tests with real answers. Completed in Slice 3 commit.
- [x] T022 [P] [US4] Add materialization shortfall test proving the total does not include governance deposits. Completed in Slice 3 commit.
- [x] T023 [US1] Implement pure `governanceWithdrawalInitMaterializationToIntent`, extracting treasury reward account hash, treasury address, treasury ref TxIn, registry ref TxIn, and operator-typed rewards lovelace from parsed inputs. Completed in Slice 3 commit.
- [x] T024 [US1] Wire the `materialization` runner to resolve -> translate -> `encodeSomeTreasuryIntent` -> atomic `--out` write honoring `--force`. Completed in Slice 3 commit.

Checkpoint: both subcommands functional; materialization golden, unit tests, and `./gate.sh` green.

## Phase 6: Slice 4 - Boundary enforcement tests

**Goal**: Add negative-space tests for what this wizard must not do.

**Worker brief**: One bisect-safe commit. Do not push. Commit body must include `Tasks: T025`.

Owned file:
- `test/unit/Amaru/Treasury/Tx/GovernanceWithdrawalInitWizardPropertyEnforcementSpec.hs`

Tasks:

- [x] T025 [P] [US2] Add hspec source-grep suite that strips Haskell comments and asserts: no `buildGovernanceWithdrawalProposalCore` or `buildGovernanceWithdrawalMaterializationCore`; no key-material APIs or string literals such as `readVaultPassphrase`, `decryptAgeVault`, `decodeWitnessVault`, `signingSourceKeyHash`, `Crypto.Age`, `.skey`, `.vkey`, `blake2b224`, `blake2b256`; no reward chain-query identifiers such as `queryRewardAccountBalance` or `getRewards`. Completed in Slice 4 commit.

Checkpoint: boundary tests and `./gate.sh` green.

## Phase 7: Slice 5 - Documentation alignment

**Goal**: Align user-facing docs with delivered behavior.

**Orchestrator-owned**. Use sidecar note `/tmp/gov-init/sidecars/docs-map.md` if present. Commit body must include `Tasks: T026, T027, T028`.

Tasks:

- [x] T026 [US5] Update `README.md` with `governance-withdrawal-init-wizard proposal` and `materialization` examples, full flag set, witness contract, DRep-equals-proposer caveat, deposit-aware shortfall reasoning, unsafe inter-step carry warning, and #161/#163 references. Completed in Slice 5 commit.
- [x] T027 [US5] Update `docs/local-devnet-smoke.md` with the same operator path and warnings, explicitly positioning `smoke.sh` as #161's CLI proof. Completed in Slice 5 commit.
- [x] T028 [US5] Refresh PR #169 body so scope, status, delivered behavior, and remaining review notes match the implementation. Completed during Slice 5 finalization.

Checkpoint: docs, PR body, and `./gate.sh` green.

## Phase 8: Slice 6 - Finalization

**Orchestrator-owned**.

Tasks:

- [x] T029 Run finalization audit: every behavior commit has a `Tasks:` trailer, every task completed by code has a matching checked box with commit SHA, `README.md`/docs/PR body/spec/plan/tasks agree, CI is green or pending only for expected docs-preview cleanup. Completed before final drop-gate commit.
- [x] T030 Remove `gate.sh` in `chore: drop gate.sh (ready for review) (#160)`, push, and mark PR #169 ready for review. Completed in final drop-gate commit.

## Dependencies and Execution Order

Behavior-changing slices are serial:

```text
Slice 1 -> Slice 2 -> Slice 3 -> Slice 4 -> Slice 5 -> Slice 6
```

Reason: Slices 1-3 share the new tx module, CLI module, cabal exposure, fixture helper, and unit/golden test registration. Running them as parallel writers on the same branch would create same-file conflicts and weaken bisect-safe review.

Safe parallelism:

```text
Sidecar A + Sidecar B may run while Slice 1 runs.
```

They are read-only scouts and produce notes under `/tmp/gov-init/sidecars/`. They must not edit the repository, stage files, commit, push, or change PR metadata. The orchestrator folds their findings into later worker briefs and docs edits.

Within a slice, `[P]` tasks may be written in any order by that slice worker, but RED evidence must be observed before GREEN implementation and the final commit must be bisect-safe.

## Notes

- `gate.sh` remains in the branch until finalization.
- Workers must not call `AskUserQuestion`. Questions go to `/tmp/gov-init/<worker-id>/questions/`; the orchestrator answers in `/tmp/gov-init/<worker-id>/answers/`.
- Implementation workers do not push. The orchestrator reviews, amends task checkboxes into the returned commit, runs `./gate.sh`, then pushes.
- #161 remains blocked until #160 is ready/merged. #163 remains parked future state.
