# Implementation Plan: DevNet Governance Action Slice

**Branch**: `080-local-devnet-smoke` | **Date**: 2026-05-11 | **Spec**: [spec.md](./spec.md)
**Issue**: [#82](https://github.com/lambdasistemi/amaru-treasury-tx/issues/82)

## Status

**Completed**: Spec Kit artifacts exist; local-only `devnet` network
identity support and the node phase have been implemented in prior
commits; node docs are present.

**Current**: Scope is narrowed to the governance action slice. The
dirty withdrawal experiment is not part of this slice and should not be
folded into the next reviewed commit.

**Blockers**: `cardano-node-clients` needs first-class support for the
Conway governance/certificate/query boundaries tracked by
lambdasistemi/cardano-node-clients#130 and #131.

## Summary

Deliver the first DevNet experiment slice: start the pinned
`cardano-node-clients` DevNet, prove the node boundary, then prepare
and submit the Conway treasury-withdrawal governance action that funds
an Amaru treasury script reward account.

Follow-up DevNet slices are deliberately split out:

- [#83](https://github.com/lambdasistemi/amaru-treasury-tx/issues/83): consume funded reward-account state with `withdraw-wizard` and `tx-build`.
- [#86](https://github.com/lambdasistemi/amaru-treasury-tx/issues/86): run `disburse-wizard` and `tx-build` against live treasury UTxOs, with USDM as the common operator path.
- [#84](https://github.com/lambdasistemi/amaru-treasury-tx/issues/84): build/fund a SundaeSwap V3-compatible order on local DevNet using the public V3 contract interface.
- [#85](https://github.com/lambdasistemi/amaru-treasury-tx/issues/85): spend/execute that SundaeSwap V3 order on local DevNet.
- [#87](https://github.com/lambdasistemi/amaru-treasury-tx/issues/87): consolidate live treasury UTxOs through the future reorganize builder.

## Technical Context

**Language/Version**: Haskell via the repository Nix shell.
**Primary Dependencies**: `cardano-node-clients:devnet`,
`cardano-node`, `cardano-cli` only as temporary harness evidence while
upstream support is missing.
**Testing**: Existing `just ci` remains deterministic; DevNet smoke is
manual and opt-in.
**Target Platform**: Local Linux Nix development shell first.
**Constraints**: Do not add signing/submission to release-facing CLI
commands; keep DevNet setup harness code separate from pure builders;
do not claim withdrawal, disburse, swap-order, swap-spend, or
reorganize proof in this slice.

## Constitution Check

**I. Faithful port of the bash recipes**: PASS. The governance setup
uses the original Amaru pattern for script stake registration and
always-abstain vote delegation.

**II. Pure builders, impure shell**: PASS. DevNet startup, setup
submission, and governance observation stay in the smoke harness.

**III. Pluggable data source, local-node default**: PASS. The slice
uses the local node boundary and records the observed network identity.

**IV. Build, never sign or submit**: PASS WITH BOUNDARY NOTE. Local
DevNet setup may submit setup transactions; release-facing commands do
not sign or submit.

**V. Test-first with golden CBOR fixtures**: PASS. Behavior-changing
library work should have RED/GREEN proof in the same reviewed commit.
The live governance smoke is manual boundary evidence.

**VI. Hackage-ready Haskell**: PASS. Any new public modules need normal
exports, docs, formatting, and Cabal updates.

## Review Slices

1. **Spec scope slice**: update #82, #83, #86, #84, #85, #87 and Spec
   Kit artifacts so governance is slice 1 and the rest of the DevNet
   roadmap is tracked as follow-up work.
2. **Node boundary slice**: keep the already-implemented `node` phase
   green and documented.
3. **Upstream TxBuild slice**: add the required Conway certificate and
   treasury-withdrawal proposal support to `cardano-node-clients`
   (#130), with tests.
4. **Upstream query slice**: add the node queries needed to observe
   governance/reward state without permanent `cardano-cli` calls
   (#131), with tests.
5. **Governance smoke slice**: add `governance` phase to the Amaru
   DevNet smoke, wire it to the upstream capabilities, and record the
   action evidence.
6. **Docs/release slice**: update README, docs, and release notes to
   distinguish node evidence, governance evidence, later withdrawal
   proof, disburse evidence, SundaeSwap V3 order-build evidence,
   order-spend proof, and reorganize evidence.

## Project Structure

```text
specs/080-local-devnet-smoke/
|-- spec.md
|-- plan.md
|-- research.md
|-- data-model.md
|-- quickstart.md
|-- contracts/
|   `-- local-devnet-smoke.md
`-- tasks.md

test/devnet/
|-- Spec.hs
`-- Amaru/Treasury/Devnet/SmokeSpec.hs

scripts/smoke/
`-- devnet-local
```

## Complexity Tracking

No constitution violations. The risky boundary is governance
submission/observation, and that risk is deliberately isolated in #82
plus the upstream issues instead of being hidden inside withdrawal.
