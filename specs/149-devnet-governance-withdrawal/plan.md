# Implementation Plan: DevNet Governance And Withdrawal Setup

**Branch**: `149-devnet-governance-withdrawal` | **Date**: 2026-05-16 | **Spec**: [spec.md](./spec.md)
**Issue**: [#149](https://github.com/lambdasistemi/amaru-treasury-tx/issues/149)
**Parent Issue**: [#151](https://github.com/lambdasistemi/amaru-treasury-tx/issues/151)

## Status

**Current**: Draft PR #154 is open with temporary branch-local
`gate.sh`. The predecessor #148 is merged, so #149 starts from
`origin/main` containing `registry-init` and `stake-reward-init`
commands.

**Phase Review Choice**: User said "merge and proceed", so the workflow
continues with phase stop `none`. Requirements, spec, plan, research,
contracts, quickstart, tasks, and analyzer notes are still committed
before any implementation handoff.

## Implementation Ownership

The orchestrator owns issue analysis, parent-ticket invariants,
specification, plan, task breakdown, analyzer fixes, local review,
documentation, final PR metadata, and verification. Behavior-changing
code slices are implemented by one subagent at a time from narrow
briefs.

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

Add a DevNet-only `amaru-treasury-tx devnet
governance-withdrawal-init` command that consumes #147 registry
artifacts and #148 stake/reward artifacts, submits the governance
proposal and vote needed to fund the already-registered treasury script
reward account, waits for the reward increase, builds/signs/submits the
withdrawal materialization transaction through production withdraw and
tx-build code, verifies ADA locked at the treasury spending validator,
and writes structured handoff artifacts for #150.

## Technical Context

**Language/Version**: Haskell through the repository Nix shell.
**Primary Dependencies**: `cardano-node-clients`, `cardano-tx-tools`,
Cardano ledger packages, #147 `Amaru.Treasury.Devnet.RegistryInit`, #148
`Amaru.Treasury.Devnet.StakeRewardInit`, existing withdraw and tx-build
modules.
**Storage**: Run-directory JSON and CBOR-hex artifacts under
`runs/devnet/...`.
**Testing**: Hspec unit/devnet tests, CLI parser/runner tests,
`just ci`, opt-in `just devnet-smoke governance-withdrawal-init`, and
compatibility evidence for existing `withdraw` smoke phase if it remains
documented.
**Target Platform**: Local Linux Nix development shell.
**Project Type**: Haskell CLI/library plus opt-in DevNet smoke.
**Constraints**: DevNet-only signing/submission command; reject
non-DevNet before effects; consume #147/#148 artifacts; do not
re-register reward accounts; no #150 disburse, swap, external-role, or
reorganize behavior in this PR.

## Constitution Check

**I. Faithful port of bash recipes**: PASS. This slice prepares local
DevNet state required before submitted disburse proof; it does not
change release-facing disburse, withdraw, or reorganize semantics.

**II. Pure builders, impure shell**: PASS WITH BOUNDARY NOTE. The
withdrawal transaction itself must use the production withdraw/tx-build
path. Governance setup and DevNet submission live behind a DevNet
bootstrap command boundary, not in pure builders.

**III. Pluggable data source, local-node default**: PASS. The command
uses the existing local-node provider/submitter path introduced by
`registry-init` and `stake-reward-init`.

**IV. Build, never sign or submit**: PASS WITH REVIEWED DEVNET
EXCEPTION. Normal release-facing treasury commands remain build-only.
This command is an explicit DevNet bootstrap exception required by
parent #151 and must reject non-DevNet networks before signing or
submission.

**V. Test-first with golden CBOR fixtures**: PASS. Behavior-changing
slices need RED/GREEN proof. Live chain effects are proved by opt-in
DevNet smoke because static fixtures cannot prove governance enactment
or reward materialization.

**VI. Hackage-ready Haskell**: PASS. New modules need explicit exports,
Haddock on exports, fourmolu formatting, Cabal exposure, and the
branch gate.

**VII. Label-1694 metadata**: PASS. This slice does not change
CIP-1694 rationale body shape or event values.

## Code Paths Inspected By Orchestrator

- `lib/Amaru/Treasury/Cli.hs`: nested `devnet` command parser and
  top-level command variants.
- `lib/Amaru/Treasury/Cli/Devnet.hs`: existing #147/#148 DevNet
  command parser, network guards, signer parsing, and runner pattern.
- `app/amaru-treasury-tx/Main.hs`: executable dispatch for DevNet
  commands.
- `lib/Amaru/Treasury/Devnet/RegistryInit.hs`: registry artifact
  projection, deployed script refs, treasury target, and registry view.
- `lib/Amaru/Treasury/Devnet/StakeRewardInit.hs`: #148 accounts
  artifact shape and treasury/permissions reward-account contract.
- `lib/Amaru/Treasury/Tx/WithdrawWizard.hs` and
  `lib/Amaru/Treasury/Cli/WithdrawWizard.hs`: production withdraw
  resolver and schema-v1 intent creation.
- `lib/Amaru/Treasury/Cli/TxBuild.hs`: production tx-build runner and
  report writer used by the current smoke.
- `lib/Amaru/Treasury/Tx/AttachWitness.hs` and
  `lib/Amaru/Treasury/Tx/Submit.hs`: signing/submission helpers
  available for the DevNet bootstrap exception.
- `test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs`: existing inline
  governance proposal, vote, withdrawal intent, tx-build, sign, submit,
  and materialization logic that #149 must move behind production code.
- `scripts/smoke/devnet-local`, `justfile`, README, and
  `docs/local-devnet-smoke.md`: current smoke phase and documentation
  surfaces that must be realigned before PR readiness.

## Vertical Review Slices

1. **Spec/process slice**: this plan, spec, checklist, research,
   data model, contract, quickstart, tasks, analyzer notes, and local
   gate. No behavior-changing code.
2. **Production command slice**: add the
   `governance-withdrawal-init` command, production module, artifact
   rendering, prerequisite artifact readers, governance/vote flow, and
   withdrawal materialization path. This is subagent-owned.
3. **Thin smoke proof slice**: update DevNet smoke to prepare a
   governance-enabled node, run #147 and #148 prerequisites, call the
   #149 command runner, and verify ledger/artifact effects. This is
   subagent-owned.
4. **Docs/finalization slice**: orchestrator aligns README,
   `docs/local-devnet-smoke.md`, `docs/release.md`, contracts,
   quickstart, tasks, and PR body; then removes `gate.sh` before ready.

## Repository Structure

```text
specs/149-devnet-governance-withdrawal/
|-- spec.md
|-- plan.md
|-- research.md
|-- data-model.md
|-- quickstart.md
|-- tasks.md
|-- analysis.md
|-- checklists/
`-- contracts/

lib/Amaru/Treasury/Devnet/
|-- RegistryInit.hs
|-- StakeRewardInit.hs
`-- GovernanceWithdrawalInit.hs

test/unit/Amaru/Treasury/Devnet/
`-- GovernanceWithdrawalInitSpec.hs

test/unit/Amaru/Treasury/Cli/
`-- DevnetSpec.hs

test/devnet/Amaru/Treasury/Devnet/
`-- SmokeSpec.hs
```

## Risks

- Governance flow currently lives entirely in `SmokeSpec.hs`; moving it
  to production code risks accidentally carrying over smoke-only genesis
  assumptions. The command must require a governance-enabled local
  DevNet and record the observed network state.
- #148 registers the treasury reward account only. #149 must not
  re-register treasury or attempt permissions registration; both would
  hide the child-ticket boundary.
- The existing smoke uses a deterministic voter key. The production
  command must either preserve a documented DevNet-only voter identity
  or derive one explicitly from supplied signing material and record it
  in artifacts.
- `tx-build` currently exits on failure. The command must surface
  failed reports and stable diagnostics without leaving stale success
  artifacts.
- Existing docs mention `governance` and `withdraw` phases. They must be
  updated before the PR is ready, or compatibility aliases must call the
  same production runner.

## Gate

Current branch gate:

```bash
./gate.sh
```

Ticket-specific live proof before finalization:

```bash
nix develop --quiet -c just devnet-smoke governance-withdrawal-init
```

If `withdraw` remains documented as a compatibility phase, it must pass
through the same production command runner:

```bash
nix develop --quiet -c just devnet-smoke withdraw
```
