# Implementation Plan: DevNet Swap Contract Readiness Slice

**Branch**: `119-devnet-swap-readiness` | **Date**: 2026-05-15 | **Spec**: [spec.md](./spec.md)
**Issue**: [#132](https://github.com/lambdasistemi/amaru-treasury-tx/issues/132)

## Status

**Completed**: Issue #132 has been created as the readiness prerequisite
for #84, and #84 has been commented with the split. The repository is
based on `origin/main` at `675b573`, which includes the merged #83
withdrawal proof. The current harness baseline rejects `swap-ready`
with exit `64` and `devnet-smoke: unknown phase: swap-ready`, proving
the phase is not already present.

**Current**: Spec Kit artifacts define the readiness-only boundary,
the public SundaeSwap V3 source assumptions, and the TDD gate. No
production code has been changed. The next task is the focused Hspec
RED test that captures the readiness artifact contract.

**Blockers**: The implementation must pin or otherwise obtain the
public SundaeSwap V3 `order.spend` validator artifact before a GREEN
readiness run can be accepted. A fixture-only validator is not
compatibility evidence.

## Summary

Add a local DevNet `swap-ready` phase that publishes or verifies the
SundaeSwap V3 order validator reference material needed by the later
#84 order build/funding slice. The phase writes a readiness registry
with the local order address, script hash, reference-script UTxO,
source provenance, network identity, and artifact paths. It does not
build, fund, submit, or spend a swap order.

The first implementation action is a RED proof: add a focused DevNet
artifact-contract test for the readiness phase and run it against the
current branch before any production code. GREEN is `just devnet-smoke
swap-ready` writing verified readiness artifacts with no toy validator.

## Technical Context

**Language/Version**: Haskell via the repository Nix shell.
**Primary Dependencies**: existing `cardano-node-clients` DevNet
harness; `Provider`/`Submitter`; existing Plutus V3 script hashing and
reference-script TxOut helpers; public `SundaeSwap-finance/sundae-contracts`
V3 order validator.
**Storage**: run-directory artifacts under `runs/devnet/<timestamp>/`
and, if needed, a pinned public validator blob under `assets/plutus/`.
**Testing**: focused Hspec RED/GREEN, `just devnet-smoke swap-ready`,
normal unit/golden smoke coverage, and the local PR gate.
**Target Platform**: local Linux Nix development shell first; DevNet
smoke remains opt-in and outside `just ci`.
**Project Type**: Haskell CLI plus opt-in DevNet harness.
**Performance Goals**: readiness phase completes within the existing
local DevNet startup/setup budget.
**Constraints**: release-facing commands remain build-only; readiness
setup may submit local reference-script publication transactions inside
the DevNet harness; no Amaru-only toy swap validator may be accepted as
SundaeSwap compatibility evidence.
**Scale/Scope**: one readiness phase, one readiness registry contract,
focused diagnostics, docs/release metadata, and follow-up #84 handoff.

## Research

See [research.md](./research.md).

Key decisions:

- Use #132 as the separate readiness ticket before #84.
- Use the public `SundaeSwap-finance/sundae-contracts` V3
  `order.spend` validator as the compatibility target.
- Reuse the existing DevNet reference-script publication pattern from
  the withdrawal registry setup instead of inventing a new harness.
- Treat fixture-only validators as diagnostics or developer fixtures,
  never as successful compatibility evidence.

## Constitution Check

**I. Faithful port of the bash recipes**: PASS. The slice prepares
contract references for the existing swap path; it does not change the
swap transaction semantics.

**II. Pure builders, impure shell**: PASS. Publication/query IO stays in
the DevNet smoke harness. Any reusable parsing/hash helpers remain pure.

**III. Pluggable data source, local-node default**: PASS. The proof uses
the local node provider and run-directory artifacts.

**IV. Build, never sign or submit**: PASS WITH BOUNDARY NOTE. The
release-facing CLI remains build-only. The opt-in DevNet harness may
submit local setup transactions that publish reference scripts, matching
the governance/withdrawal precedent.

**V. Test-first with golden CBOR fixtures**: PASS WITH LIVE-BOUNDARY
NOTE. The feature starts with a failing readiness artifact-contract test.
No swap CBOR golden is expected in this readiness slice because no swap
order is built; #84 owns order-build CBOR/report evidence.

**VI. Hackage-ready Haskell**: PASS. New public exports need Haddock,
explicit export lists, formatting, hlint, and Cabal updates.

## RED/GREEN Proof And Gate

**RED**: Add a focused DevNet test in
`test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs` for `swap-ready`
readiness evidence, then run:

```bash
nix develop --quiet -c cabal test devnet-tests -O0 \
  --test-show-details=direct \
  --test-option=--match \
  --test-option='swap-ready readiness'
```

Expected RED on the current code: the readiness phase/evidence
contract does not exist, or `scripts/smoke/devnet-local --phase
swap-ready` is rejected as an unknown phase.

**GREEN**: After implementation, run:

```bash
nix develop --quiet -c just devnet-smoke swap-ready
```

The command must exit 0 and write `swap-ready/summary.json`,
`swap-ready/registry.json`, and any referenced contract/provenance
artifacts. Before PR handoff, run the local gate:

```bash
./llm/reviews/local-119-devnet-swap-readiness/gate.sh
```

## Vertical Review Slices

1. **Spec/process slice**: add #132 Spec Kit artifacts, local review
   state, and gate candidate. No production code.
2. **Readiness contract RED slice**: write the focused failing
   DevNet/Hspec proof that requires a `swap-ready` phase and readiness
   artifact contract. Observe the failure before implementation.
3. **Public V3 order artifact slice**: pin or load the public
   SundaeSwap V3 `order.spend` validator artifact. RED: a pure test
   expects the order validator blob/hash to exist and match the pinned
   public identity. GREEN: the artifact hash and existing mainnet
   address/hash constants agree or the mismatch is a typed diagnostic.
4. **DevNet readiness publication slice**: extend
   `scripts/smoke/devnet-local`, `just devnet-smoke`, and the DevNet
   harness with `swap-ready`. Publish or verify the order validator
   reference script and write readiness registry artifacts.
5. **Failure diagnostics slice**: cover missing artifact, hash mismatch,
   missing reference UTxO, reference-script mismatch, stale run
   directory, and fixture-only evidence with typed diagnostics.
6. **Docs/metadata slice**: update local DevNet docs, release notes,
   README/CHANGELOG as needed, #132 metadata, and #84 handoff notes with
   verified run evidence.

## Project Structure

```text
specs/119-devnet-swap-readiness/
|-- spec.md
|-- plan.md
|-- research.md
|-- data-model.md
|-- quickstart.md
|-- contracts/
|   `-- devnet-swap-readiness.md
`-- tasks.md

test/devnet/
`-- Amaru/Treasury/Devnet/SmokeSpec.hs

scripts/smoke/
`-- devnet-local

llm/reviews/local-119-devnet-swap-readiness/
|-- gate.sh
|-- state.md
|-- plan-review.md
`-- tasks-review.md
```

## Complexity Tracking

No constitution violations. The risky boundary is contract identity:
the implementation must never report a toy or fixture validator as
SundaeSwap V3 compatibility evidence.
