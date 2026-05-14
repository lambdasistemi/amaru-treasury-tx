# Implementation Plan: DevNet Withdrawal Slice

**Branch**: `083-devnet-withdrawal` | **Date**: 2026-05-13 | **Spec**: [spec.md](./spec.md)  
**Issue**: [#83](https://github.com/lambdasistemi/amaru-treasury-tx/issues/83)

## Status

**Completed**: #83 is scoped; upstream `cardano-node-clients` #132 was
rebase-merged into `main` at `d6773e4cd8a2421617568c8dac0972b0f312a509`;
the current branch is stacked on the #82 governance proof branch; Amaru
now pins that upstream main commit in Cabal and Nix; the withdrawal
phase contract, live reward-to-intent slice, and intent-to-unsigned-build
slice are implemented. The focused diagnostics slice is also
implemented.

**Current**: Release documentation is being finalized. The withdraw
smoke now creates local DevNet
registry anchors, funds the local treasury script reward account
through governance, resolves live rewards with `withdraw-wizard`,
writes `withdraw/intent.json`, then runs `tx-build` and writes
unsigned CBOR plus JSON/Markdown review reports. Failure paths now
write typed diagnostics for reward timeout, zero rewards, network
mismatch, and tx-build failure.

**Blockers**: #82/PR #93 should remain the source of standalone
governance proof. #83 still needs the final gate and PR/issue metadata
refresh before undrafting.

## Summary

Add a `withdraw` phase to the local DevNet smoke. The phase consumes
the #82 funded reward-account setup, runs the existing
`withdraw-wizard` resolver against live local-node state, verifies that
the emitted schema-v1 withdraw intent contains positive rewards, then
runs `tx-build` to produce unsigned Conway CBOR and reports.

The slice proves withdrawal build evidence only. It does not sign or
submit the final withdrawal transaction and does not claim disburse,
SundaeSwap, or reorganize evidence.

## Technical Context

**Language/Version**: Haskell via the repository Nix shell.
**Primary Dependencies**: `cardano-node-clients` DevNet harness and
Provider queries; existing `withdraw-wizard`; existing `tx-build`;
existing intent schema and report renderer.
**Storage**: Run-directory artifacts under `runs/devnet/<timestamp>/`.
**Testing**: Hspec unit/devnet tests, smoke scripts, existing golden
and schema checks, full `just ci`, and opt-in `just devnet-smoke
withdraw`.
**Target Platform**: Local Linux Nix development shell first; CI-safe
default suite remains free of DevNet startup.
**Project Type**: Haskell CLI.
**Performance Goals**: Withdrawal smoke completes within the configured
reward wait budget on the short-epoch DevNet.
**Constraints**: DevNet setup may submit setup/governance transactions
inside the smoke harness; release-facing Amaru commands still build
unsigned transactions only.
The withdraw phase uses local seed-derived registry policy scripts and
reference-script UTxOs so the live DevNet registry view contains real
local anchors, not placeholder references.
**Scale/Scope**: One new DevNet phase, run artifacts, focused tests,
and release documentation.

## Constitution Check

**I. Faithful port of the bash recipes**: PASS. The existing withdraw
builder/wizard remains the release-facing path; this slice only proves
it against live DevNet reward state.

**II. Pure builders, impure shell**: PASS. The DevNet harness owns node
startup and setup IO; `tx-build` continues to consume an intent and
build unsigned CBOR.

**III. Pluggable data source, local-node default**: PASS. The proof uses
the local N2C provider and the upstream Provider reward queries.

**IV. Build, never sign or submit**: PASS WITH BOUNDARY NOTE. The smoke
may submit governance setup transactions to create reward state, but
the withdrawal transaction itself is only built.

**V. Test-first with golden CBOR fixtures**: PASS. Offline withdraw
fixtures already exist; this slice adds live-boundary RED/GREEN smoke
coverage.

**VI. Hackage-ready Haskell**: PASS. New code must pass formatting,
hlint, Cabal checks, and the existing CI gate.

## Vertical Review Slices

1. **Spec/process slice**: add #83 Spec Kit artifacts and local review
   state. No production code.
2. **Merged-upstream pin slice**: refresh `cardano-node-clients` from
   the temporary stack SHA to upstream `main` commit
   `d6773e4cd8a2421617568c8dac0972b0f312a509`. RED: current docs/pin
   still reference stack-only release readiness. GREEN: normal gate and
   governance smoke still pass. Status: complete on this branch.
3. **Withdrawal phase contract slice**: add `withdraw` to
   `scripts/smoke/devnet-local`, `just devnet-smoke`, and the DevNet
   Hspec selector with a failing contract for required artifacts and
   typed no-evidence diagnostics. Status: complete on this branch.
4. **Live reward-to-intent slice**: factor the #82 governance setup
   helper enough for the withdraw phase to observe funded reward state,
   then run the withdraw resolver against the live provider. RED:
   intent artifact is missing or rewards are zero. GREEN:
   `withdraw/intent.json` contains the funded account, positive reward
   amount, and local registry anchors for scopes, permissions,
   treasury, and registry scripts. Status: complete on this branch.
5. **Intent-to-build slice**: run `tx-build` on the live intent and
   record unsigned CBOR, report JSON/markdown, body hash, fee, and
   validity evidence. RED: artifact contract fails after intent
   creation. GREEN: local `just devnet-smoke withdraw` records build
   evidence. Status: complete on this branch.
6. **Diagnostics slice**: cover zero reward, timeout/stale evidence,
   network mismatch, and build failure preservation as typed
   diagnostics that do not write success artifacts. Status: complete
   on this branch.
7. **Docs/release slice**: update README, local DevNet docs, release
   notes, CHANGELOG, and #83 metadata with the verified run directory
   and boundaries. Status: current next slice.

## Project Structure

```text
specs/083-devnet-withdrawal/
|-- spec.md
|-- plan.md
|-- research.md
|-- data-model.md
|-- quickstart.md
|-- contracts/
|   `-- devnet-withdrawal-smoke.md
`-- tasks.md

test/devnet/
`-- Amaru/Treasury/Devnet/SmokeSpec.hs

scripts/smoke/
`-- devnet-local

docs/
|-- local-devnet-smoke.md
`-- release.md
```

## Complexity Tracking

No constitution violations. The main risk is accidentally treating
governance setup as withdrawal behavior. The implementation must keep
that boundary explicit in artifact names, summaries, and release notes.
