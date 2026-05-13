# Implementation Plan: DevNet Governance Action Slice

**Branch**: `080-local-devnet-smoke` | **Date**: 2026-05-11 | **Spec**: [spec.md](./spec.md)
**Issue**: [#82](https://github.com/lambdasistemi/amaru-treasury-tx/issues/82)

## Status

**Completed**: Spec Kit artifacts exist; local-only `devnet` network
identity support and the node phase have been implemented in prior
commits; node docs are present.

**Current**: Scope is narrowed to the governance action slice. The
remaining work must land as vertical TDD commits: each behavior-changing
commit carries its own failing proof, implementation, focused
verification, and task/doc status update.

**Blockers**: The downstream branch may consume the current
`cardano-node-clients` #137 draft head to prove direction locally, but
release/merge readiness still depends on the upstream PR stack being
accepted or explicitly pinned for the release.

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

## Vertical Review Slices

1. **Spec/process slice**: update Spec Kit artifacts and local PR review
   state. No production code. Gate: checklist and cross-artifact review.
2. **Upstream pin/API slice**: pin `cardano-node-clients` to the current
   #137 head and adapt Amaru test/provider stubs to the expanded
   `Provider` interface. RED: the pinned dependency exposes missing
   fields in local `Provider` construction. GREEN: focused unit/build
   gate passes.
3. **Reward-query boundary slice**: replace Amaru's direct LSQ reward
   helper with the #137 `Provider` reward-account query. RED: a unit
   regression proves missing reward rows are zero and the resolver uses
   provider reward accounts. GREEN: withdraw resolver tests pass without
   the bespoke LSQ path.
4. **Governance smoke slice**: replace the typed upstream blocker with a
   real local DevNet governance proof: patch short-epoch genesis, submit
   the treasury-withdrawal governance action, vote as required, wait for
   epoch advancement, and observe the target reward account through
   provider queries. RED: the governance phase fails on the old blocker
   or missing artifact contract. GREEN: `just devnet-smoke governance`
   records the expected action/reward evidence.
5. **Docs/release slice**: update README, docs, release notes, and issue
   metadata to distinguish proven governance evidence from later
   withdrawal, disburse, swap-order, swap-spend, and reorganize proofs.

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
submission/observation, and that risk is deliberately isolated in #82.
Release-facing commands still build unsigned transactions only; signing
and submission remain inside the opt-in DevNet smoke harness.
