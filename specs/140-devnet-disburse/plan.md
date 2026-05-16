# Implementation Plan: DevNet Disburse Slice

**Branch**: `140-devnet-disburse` | **Date**: 2026-05-16 | **Spec**: [spec.md](./spec.md)
**Issue**: [#86](https://github.com/lambdasistemi/amaru-treasury-tx/issues/86)

## Status

**Completed**: #83 withdrawal materialization has merged through PR
#100 and the issue is now closed as completed. `origin/main` includes
the merged governance/withdrawal baseline and the later `swap-ready`
readiness work. Draft PR #145 is open for this #86 slice and currently
carries only spec/process work.

**Current**: Plan and task artifacts define the RED/GREEN path for a
first-class `disburse` local DevNet phase. The next implementation step
is the RED proof that the existing smoke harness still rejects
`disburse`.

**Blockers**: No blocker for ADA disburse evidence. Synthetic local
USDM treasury setup is not yet proven on `main`, so USDM may land as a
typed `missing-usdm-setup` diagnostic unless this slice adds the token
setup safely.

## Summary

Add an opt-in `disburse` phase to the local DevNet smoke. The phase
starts from live treasury state created by the governance/withdrawal
setup path, runs the existing disburse wizard resolver against the
local-node provider, writes a schema-v1 `action = "disburse"` intent,
and then runs `tx-build` to produce unsigned Conway CBOR and reports.

The slice proves disburse evidence only. It does not build or fund a
SundaeSwap order, spend an order, or reorganize treasury UTxOs. The
release-facing CLI remains build-only; any automatic fixture setup stays
inside the opt-in DevNet harness.

## Technical Context

**Language/Version**: Haskell via the repository Nix shell.
**Primary Dependencies**: existing `cardano-node-clients` DevNet
harness; local N2C `Provider`; existing `disburse-wizard` resolver;
existing `tx-build`; existing intent schema and report renderer.
**Storage**: run-directory artifacts under `runs/devnet/<timestamp>/`.
**Testing**: focused Hspec RED/GREEN, direct smoke-script RED,
`just devnet-smoke disburse`, normal unit/golden smoke coverage, and
the local PR gate.
**Target Platform**: local Linux Nix development shell first; DevNet
startup remains outside `just ci`.
**Project Type**: Haskell CLI plus opt-in DevNet harness.
**Performance Goals**: complete within the existing short-epoch DevNet
startup and reward wait budgets.
**Constraints**: release-facing commands build unsigned transactions
only; DevNet fixture setup may submit local governance/withdrawal
transactions to create spendable treasury state; success evidence must
distinguish ADA from USDM and must not claim swap-order evidence.
**Scale/Scope**: one new DevNet phase, artifact contract, focused
diagnostics, documentation, and issue metadata.

## Research

See [research.md](./research.md).

Key decisions:

- Reuse the merged governance/withdrawal setup path to create live
  treasury script UTxOs for the disburse resolver.
- Drive the existing disburse wizard/resolver and `tx-build` path
  instead of hand-writing a transaction in the smoke harness.
- Treat ADA as the first required successful live spend if local USDM
  setup is absent; record USDM as either success or a typed
  missing-token/setup diagnostic.
- Keep prerequisite withdrawal artifacts and disburse success artifacts
  separate in the run directory.

## Constitution Check

**I. Faithful port of the bash recipes**: PASS. The disburse wizard and
builder remain the release-facing implementation of the bash `disburse`
recipe. The smoke only supplies live DevNet state.

**II. Pure builders, impure shell**: PASS. Node queries, fixture setup,
and artifact writing stay in the DevNet harness. Transaction building
continues through the existing pure builder path behind `tx-build`.

**III. Pluggable data source, local-node default**: PASS. The proof uses
the local node provider and injected resolver effects.

**IV. Build, never sign or submit**: PASS WITH BOUNDARY NOTE. The
release-facing disburse command emits unsigned transaction bodies. The
DevNet harness may submit setup transactions for governance/withdrawal
prerequisites, but #86 success only requires unsigned disburse CBOR and
reports.

**V. Test-first with golden CBOR fixtures**: PASS. Offline disburse ADA
and USDM goldens already exist; this slice starts with a live-boundary
RED proof and adds smoke coverage around resolver/build artifacts.

**VI. Hackage-ready Haskell**: PASS. Any Haskell changes must pass
formatting, hlint, Cabal tests, schema checks, and the local gate.

**VII. Label-1694 metadata**: PASS. Disburse evidence must preserve the
existing `event = "disburse"` metadata behavior and must not alter the
golden body shape.

## RED/GREEN Proof And Gate

**RED**: Before production changes, prove the phase is absent:

```bash
tmp="$(mktemp -d)"
scripts/smoke/devnet-local --phase disburse --run-dir "$tmp"
```

Expected current result: exit `64` with
`devnet-smoke: unknown phase: disburse`.

**GREEN**: After implementation:

```bash
nix develop --quiet -c just devnet-smoke disburse
```

The command must exit 0 for the successful subcase and write
`disburse/intent.json`, `disburse/tx-body.cbor.hex`,
`disburse/report.json`, `disburse/report.md`,
`disburse/tx-build.log`, and `disburse/summary.json`. USDM must be
represented either by success fields or by a typed diagnostic. Before
PR handoff, run:

```bash
./llm/reviews/local-140-devnet-disburse/gate.sh
```

## Vertical Review Slices

1. **Spec/process slice**: add #86 Spec Kit artifacts, local review
   state, gate candidate, and draft PR metadata. No production code.
2. **Disburse contract RED slice**: prove the current harness rejects
   `disburse`; add focused artifact-contract coverage that requires the
   disburse run summary shape.
3. **Live treasury prerequisite slice**: reuse the governance/withdrawal
   setup path to materialize spendable local treasury state and record
   prerequisite evidence before disburse success artifacts are written.
4. **Live intent slice**: run the disburse resolver against the live
   provider and write a decodable schema-v1 disburse intent.
5. **Intent-to-build slice**: run `tx-build` on the live intent and
   record unsigned CBOR, report JSON/Markdown, build log, selected
   inputs, beneficiary, unit, amount, and validity context.
6. **USDM boundary and diagnostics slice**: either prove local USDM
   disburse or write a stable missing-USDM diagnostic; cover missing
   treasury, wallet, registry, permissions, beneficiary, token,
   network, and build state without stale success artifacts.
7. **Docs/metadata slice**: update README, local DevNet docs, release
   notes, CHANGELOG, #86 metadata, and downstream #84/#85/#136/#87
   boundary notes with verified evidence.

## Project Structure

```text
specs/140-devnet-disburse/
|-- spec.md
|-- plan.md
|-- research.md
|-- data-model.md
|-- quickstart.md
|-- contracts/
|   `-- devnet-disburse-smoke.md
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

No constitution violations. The main risk is overclaiming USDM or swap
coverage. The implementation must keep ADA, USDM, disburse, swap-order,
swap-execution, and reorganize evidence boundaries explicit in artifact
names, summaries, docs, and issue comments.
