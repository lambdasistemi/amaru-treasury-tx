---
description: "Task list for #175 - registry-init fresh DevNet bootstrap mode"
---

# Tasks: registry-init fresh DevNet bootstrap mode

**Input**: Design documents from `specs/175-registry-bootstrap-mode/`
**Prerequisites**: [spec.md](./spec.md), [plan.md](./plan.md)
**Tests**: Required. Every behavior-changing slice ships RED + GREEN in
one bisect-safe commit.

## Slice and Commit Mapping

| Slice | Worker | Primary story | Commit subject |
|---|---|---|---|
| 1 | `registry-bootstrap/mode-split` | US1 + US3 | `feat(cli): split registry-init verified and bootstrap modes (#175)` |
| 2 | `registry-bootstrap/intents` | US1 | `feat(tx): emit registry-init bootstrap intents (#175)` |
| 3 | `registry-bootstrap/artifacts` | US2 | `feat(cli): write registry-init bootstrap artifacts (#175)` |
| 4 | orchestrator | US4 | `docs(175): document registry bootstrap handoff` |
| 5 | orchestrator | finalization | `chore: drop gate.sh (ready for review) (#175)` |

## Phase 1: Bootstrap parser and mode split

**Goal**: Make bootstrap an explicit CLI mode without changing the
default verified behavior.

- [ ] T001 [P] [US1] Add parser tests showing
  `registry-init-wizard {seed-split,mint,reference-scripts} --bootstrap`
  is accepted and included in help output.
- [ ] T002 [P] [US3] Add a source/runner test proving the default path
  still calls `verifyRegistry` before emitting intents.
- [ ] T003 [P] [US1] Add a source/runner test proving the bootstrap path
  does not call `verifyRegistry`.
- [ ] T004 [US1] Add explicit verified/bootstrap mode plumbing in
  `lib/Amaru/Treasury/Cli/RegistryInitWizard.hs` while keeping existing
  verified behavior unchanged.

Checkpoint: focused parser/unit tests green and `./gate.sh` green.

## Phase 2: Bootstrap resolver and three intents

**Goal**: Emit buildable registry-init intents on a fresh DevNet without
existing registry anchors.

- [ ] T005 [P] [US1] Add a DevNet-only bootstrap resolver in
  `lib/Amaru/Treasury/Tx/RegistryInitWizard.hs` that selects wallet UTxOs
  and validity upper bound without registry metadata verification.
- [ ] T006 [P] [US1] Add tests proving bootstrap mode fails closed for
  non-DevNet networks before chain queries or file writes.
- [ ] T007 [US1] Wire bootstrap seed-split intent emission through the
  existing `registryInitSeedSplitToIntent`/`tx-build` path, using only
  resolver-selected wallet and validity data.
- [ ] T008 [US1] Wire bootstrap mint intent emission with
  operator-supplied seed TxIns and owner key hash.
- [ ] T009 [US1] Wire bootstrap reference-scripts intent emission with
  operator-supplied seed TxIns and funding seed TxIn.
- [ ] T010 [US1] Add round-trip/golden coverage proving all three
  bootstrap intents decode and build through existing registry-init
  translators.

Checkpoint: all three bootstrap intent paths functional; existing #158
verified-mode tests still green; `./gate.sh` green.

## Phase 3: Artifact writer

**Goal**: Produce registry-init handoff artifacts from real submitted tx
ids after build/sign/submit has happened outside the wizard.

- [ ] T011 [P] [US2] Add parser/tests for the artifact writer command
  arguments: submitted tx ids, seed refs, owner key hash, network magic,
  and output/run directory.
- [ ] T012 [US2] Implement artifact construction from submitted tx ids:
  registry mint `#0/#1` become scopes/registry anchors and
  reference-scripts `#0/#1` become permissions/treasury anchors.
- [ ] T013 [US2] Derive policies, script hashes, and treasury target from
  `deriveDevnetScripts` using the operator-supplied seed TxIns.
- [ ] T014 [US2] Write `registry-init/summary.json`,
  `registry-init/registry.json`, `registry-init/provenance.json`, and the
  top-level summary paths using the existing registry-init artifact shape.
- [ ] T015 [US2] Add negative tests for malformed tx ids/refs, malformed
  owner key hash, non-DevNet input, and no partial writes after failure.

Checkpoint: artifact writer tests green and `./gate.sh` green.

## Phase 4: Docs and #161 handoff

**Orchestrator-owned**.

- [ ] T016 [US4] Update `README.md` and `docs/local-devnet-smoke.md` with
  the fresh bootstrap command sequence and the explicit hand-carry fields
  #161 must record.
- [ ] T017 [US4] Refresh PR #176 body with delivered behavior,
  verification, and the #161 handoff command sequence.
- [ ] T018 [US4] Comment on #175, #161, and #156 with the merged-surface
  handoff once local verification passes.

## Phase 5: Finalization

**Orchestrator-owned**.

- [ ] T019 Run full `./gate.sh` and record the evidence in PR #176.
- [ ] T020 Run finalization audit: commit messages, `Tasks:` trailers,
  tasks checked, docs/spec/plan/tasks/PR body agree.
- [ ] T021 Drop `gate.sh` in the final commit and mark PR #176 ready.

## Dependencies and Execution Order

Behavior-changing slices are serial. They share the same CLI parser,
wizard module, and golden fixtures:

```text
Slice 1 -> Slice 2 -> Slice 3 -> Slice 4 -> Slice 5
```

Safe parallelism is limited to read-only code scouting or docs scouting.
No two workers should write `RegistryInitWizard.hs` files concurrently.
