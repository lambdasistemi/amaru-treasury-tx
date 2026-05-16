# Implementation Plan: DevNet Disburse Submit

**Branch**: `150-devnet-disburse-beneficiary`
**Date**: 2026-05-16
**Spec**: [spec.md](./spec.md)
**Issue**: #150
**Parent**: #151

## Summary

Add a DevNet-only `disburse-submit` command that consumes registry and
#149 materialization artifacts, builds an ADA disburse through
production disburse/tx-build code, signs/submits it, verifies treasury
and beneficiary ledger effects, writes structured artifacts, and is
proven by a thin `just devnet-smoke disburse-submit` phase.

## Technical Context

- Language: Haskell
- Build: Cabal through Nix dev shell
- Existing build path: `Amaru.Treasury.Tx.Disburse`,
  `Amaru.Treasury.Tx.DisburseWizard`, `Amaru.Treasury.Build`,
  `Amaru.Treasury.Cli.TxBuild`
- Existing DevNet patterns:
  `Amaru.Treasury.Devnet.RegistryInit`,
  `Amaru.Treasury.Devnet.StakeRewardInit`,
  `Amaru.Treasury.Devnet.GovernanceWithdrawalInit`
- Verification: focused unit tests, `cabal build`, `just ci`, opt-in
  `just devnet-smoke disburse-submit`

## Constitution Check

- Production-backed command is mandatory.
- Smoke must remain orchestration/proof only.
- One subagent owns one bisect-safe behavior-changing slice at a time.
- Docs, README, release notes, quickstart, contract, tasks, and PR body
  must align before ready.

## Project Structure

```text
lib/Amaru/Treasury/Devnet/DisburseSubmit.hs
lib/Amaru/Treasury/Cli/Devnet.hs
lib/Amaru/Treasury/Cli.hs
app/amaru-treasury-tx/Main.hs
test/unit/Amaru/Treasury/Devnet/DisburseSubmitSpec.hs
test/unit/Amaru/Treasury/Cli/DevnetSpec.hs
test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs
scripts/smoke/devnet-local
docs/local-devnet-smoke.md
docs/release.md
README.md
```

## Phases

1. Command slice: parser, production DevNet module, artifact rendering,
   prerequisite validation, focused tests.
2. Submission/effect slice: live signing/submission and chain-state
   verification through the command runner.
3. Smoke proof slice: add `disburse-submit` phase and assert artifacts.
4. Documentation/finalization slice: align README/docs/contracts/tasks
   and remove `gate.sh`.

## Risks

- The selected #149 treasury UTxO may need exact datum/value handling to
  satisfy the disburse validator.
- Beneficiary verification must distinguish the submitted output from
  unrelated pre-existing UTxOs at the same address.
- The command must not silently fall back to arbitrary treasury UTxOs if
  the #149 materialized handoff is missing or stale.
