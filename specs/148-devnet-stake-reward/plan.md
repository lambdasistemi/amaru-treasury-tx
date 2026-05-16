# Implementation Plan: DevNet Stake And Reward Setup

**Branch**: `148-devnet-stake-reward` | **Date**: 2026-05-16 | **Spec**: [spec.md](./spec.md)  
**Issue**: [#148](https://github.com/lambdasistemi/amaru-treasury-tx/issues/148)  
**Parent Issue**: [#151](https://github.com/lambdasistemi/amaru-treasury-tx/issues/151)

## Status

**Current**: Draft PR #153 is open with the temporary `gate.sh`.
Specs, plan, contracts, quickstart, and tasks are orchestrator-owned.
The command and parser implementation slices are complete; the live
smoke proof exposed a permissions certificate-purpose mismatch that must
be corrected before finalization.

**Phase Review Choice**: User said "merge and proceed" after #147, so
the workflow continues with phase stop `none`. Artifacts are still
committed before any implementation handoff.

## Implementation Ownership

The orchestrator owns issue analysis, parent-ticket invariants,
specification, plan, task breakdown, local review, final PR metadata,
documentation, and verification. Behavior-changing code slices are
implemented by one subagent at a time from narrow briefs.

Before each subagent handoff, the orchestrator inspects the relevant
code path, applies artifact corrections locally, and gives the subagent
exact task ids, owned files, forbidden scope, RED proof, GREEN proof,
and commit requirements.

## Parent Carry-Forward Invariant

For #148, #149, and #150, the operator command is paramount. The first
P1 user story and acceptance target must be the shipped production
command for the operator-created bootstrap transaction. Smoke proof is
evidence for the command; it does not replace the command.

## Summary

Add a DevNet-only `amaru-treasury-tx devnet stake-reward-init` command
that consumes #147 registry artifacts, submits the setup transaction
that registers the treasury script reward account, emits the permissions
script reward account as the available withdraw-zero target, writes
structured setup artifacts, and rejects non-DevNet networks before
effects. Update disburse reward-account parsing so DevNet permissions
zero-withdrawal uses a ledger `Testnet` reward account. Update the
DevNet smoke so `just devnet-smoke stake-reward-init` proves the same
command runner path.

## Technical Context

**Language/Version**: Haskell through the repository Nix shell.  
**Primary Dependencies**: `cardano-node-clients`, `cardano-tx-tools`,
Cardano ledger packages, #147 `Amaru.Treasury.Devnet.RegistryInit`.  
**Storage**: Run-directory JSON artifacts under `runs/devnet/...`.  
**Testing**: Hspec unit/devnet tests, CLI parser/runner tests,
`just ci`, opt-in `just devnet-smoke stake-reward-init`.  
**Target Platform**: Local Linux Nix development shell.  
**Project Type**: Haskell CLI/library plus opt-in DevNet smoke.  
**Constraints**: DevNet-only signing/submission command; reject
non-DevNet before effects; no governance funding, treasury withdrawal
materialization, disburse, swap, or external-role behavior in this PR.

## Constitution Check

**I. Faithful port of bash recipes**: PASS. This slice prepares
reward/stake prerequisites only and does not redefine disburse or
withdraw construction.

**II. Pure builders, impure shell**: PASS WITH BOUNDARY NOTE. Setup
submission is a DevNet bootstrap boundary. Reusable construction and
artifact projection live under `lib/`; smoke remains orchestration and
verification.

**III. Pluggable data source, local-node default**: PASS. The command
uses the local node provider/submitter path already introduced for
DevNet registry-init.

**IV. Build, never sign or submit**: PASS WITH REVIEWED DEVNET
EXCEPTION. Normal release-facing treasury commands remain build-only.
The stake/reward setup command is an explicit DevNet bootstrap
exception required by #151 and must reject non-DevNet networks before
signing/submission.

**V. Test-first with golden CBOR fixtures**: PASS. Behavior-changing
slices need RED/GREEN proof. Live chain effects are proved by the
opt-in DevNet smoke because static fixtures cannot prove local reward
account state.

**VI. Hackage-ready Haskell**: PASS. New modules need explicit exports,
Haddock on exports, fourmolu formatting, Cabal exposure, and `just ci`.

**VII. Label-1694 metadata**: PASS. This slice does not change CIP-1694
metadata body shape or event values.

## Code Paths Inspected By Orchestrator

- `lib/Amaru/Treasury/Cli/Devnet.hs`: existing #147 DevNet command
  parser and runner pattern.
- `app/amaru-treasury-tx/Main.hs` and `lib/Amaru/Treasury/Cli.hs`:
  executable dispatch and nested `devnet` command parser.
- `lib/Amaru/Treasury/Devnet/RegistryInit.hs`: production artifact
  projection and registry script/hash source for #148.
- `lib/Amaru/Treasury/IntentJSON/Common.hs`: network-aware
  `parseRewardAccountForNetwork`.
- `lib/Amaru/Treasury/IntentJSON.hs` and
  `lib/Amaru/Treasury/Tx/DisburseIntentJSON.hs`: disburse paths that
  still call Mainnet-only reward-account parsing.
- `test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs`: existing inline
  governance/stake setup that must be split so #148 owns setup and #149
  owns governance funding.
- `docs/trust-model.md`: permissions reward account is the permissions
  script hash used by withdraw-zero.
- PR #145 `Wip.md`: submitted disburse exposed missing DevNet
  permissions reward-account setup and network-aware parsing.

## Vertical Review Slices

1. **Spec/process slice**: this plan, contracts, quickstart, tasks,
   and local gate. No behavior-changing code.
2. **Parser/network RED slice**: add focused tests proving the
   `devnet stake-reward-init` command shape and DevNet disburse
   reward-account parsing expectation fail before implementation.
3. **Production setup command slice**: add
   `Amaru.Treasury.Devnet.StakeRewardInit`, CLI parser/runner wiring,
   artifact rendering, and Cabal exposure. This is subagent-owned.
4. **Smoke proof slice**: update DevNet smoke to run registry-init as
   prerequisite when needed, invoke the production setup runner, verify
   ledger effects, and record live artifacts. This is subagent-owned.
5. **Docs/finalization slice**: orchestrator aligns README, docs,
   contracts, tasks, PR body, and removes `gate.sh` before ready.

## Repository Structure

```text
specs/148-devnet-stake-reward/
|-- spec.md
|-- plan.md
|-- research.md
|-- data-model.md
|-- quickstart.md
|-- tasks.md
|-- checklists/
`-- contracts/

lib/Amaru/Treasury/Devnet/
|-- RegistryInit.hs
`-- StakeRewardInit.hs

test/unit/Amaru/Treasury/Devnet/
`-- StakeRewardInitSpec.hs

test/unit/Amaru/Treasury/Cli/
`-- DevnetSpec.hs

test/devnet/Amaru/Treasury/Devnet/
`-- SmokeSpec.hs
```

## Risks

- `Provider.queryRewardAccounts` alone may not distinguish
  unregistered accounts from registered accounts with zero rewards.
  The implementation brief must require a stronger verification signal
  or a typed diagnostic if the pinned dependency cannot expose one.
- Live DevNet evaluation rejects the permissions script when it is used
  as a Conway certificate witness. The command must register only the
  treasury script reward account and emit the permissions reward account
  as available for later withdraw-zero validation.
- Existing smoke code combines account setup, governance proposal, vote,
  and reward increase. #148 must not carry #149 behavior into this PR.
- Disburse intent translation has both unified and legacy paths; tests
  must lock the path used by later DevNet disburse work.

## Gate

Current branch gate:

```bash
./gate.sh
```

Ticket-specific live proof before finalization:

```bash
nix develop --quiet -c just devnet-smoke stake-reward-init
```
