# Implementation Plan: bump cardano-tx-tools reward-state validation

**Branch**: `191-bump-tx-tools` | **Date**: 2026-05-21 | **Spec**: [spec.md](./spec.md)
**Issue**: [#191](https://github.com/lambdasistemi/amaru-treasury-tx/issues/191)
**Parent Issue**: [#189](https://github.com/lambdasistemi/amaru-treasury-tx/issues/189)
**Draft PR**: [#192](https://github.com/lambdasistemi/amaru-treasury-tx/pull/192)

## Status

**Current**: `spec.md` is committed at `dd6fa6f4` and approved by the
epic owner. `gate.sh` is committed and runs `git diff --check` plus
`nix develop --quiet -c just ci`.

**Planning clarification**: upstream release `v0.2.0.0` is represented
by annotated tag object `d53943d842b740b313b6b67c7784f4308e5847f0`,
but `cabal.project` `source-repository-package tag:` must use the tag's
commit object:
`9e77e90728729bdd22e3bfbe0cf7515b33d5ea13`.

**Blocked successor**: #185 remains parked until this PR merges. This
branch must not edit reorganize implementation modules.

## Summary

Bump the `cardano-tx-tools` source-repository-package pin from
`25d7ce349f826e9888fb8565eeb816babb06d922` to
`9e77e90728729bdd22e3bfbe0cf7515b33d5ea13`, regenerate the matching
nix32 fixed-output hash, then remove downstream Phase-1 validation skips
that only existed because the old tx-tools validator could not seed
reward-account state. The primary code change is to make
`validateFinalPhase1` call `validatePhase1` for withdrawal-bearing
transactions again while still treating missing vkey witnesses as
signing-step noise.

The governance-withdrawal-init path is a decision point, not an
assumption: after the bump, existing proposal and materialization
fixtures are run through the active validation path. If they pass, the
skip helper is removed. If a separate ledger rule still fails, the skip
is retained only with a comment naming the residual rule and upstream
tracking issue, and implementation stops for parent-owner clarification
before expanding scope.

## Implementation Ownership

The orchestrator owns this plan, `research.md`, `data-model.md`,
`quickstart.md`, `contracts/`, `tasks.md`, `gate.sh`, PR metadata, and
phase-stop Q/A files. Behavior-changing implementation slices are
worker-owned after plan and task review. Workers receive exact owned
files, RED proof, GREEN proof, and one bisect-safe commit contract per
slice. Workers are not alone in the codebase and must not revert edits
made by others.

## Technical Context

**Language/Version**: Haskell, GHC 9.6+ via the repository Nix shell
(current haskell.nix toolchain uses GHC 9.12.3).
**Primary Dependencies**: `cardano-tx-tools` via `cabal.project`
source-repository-package; `cardano-node-clients`; Cardano ledger
libraries; `aeson`; Hspec.
**Storage**: N/A for runtime behavior. Planning artifacts live under
`specs/191-bump-tx-tools/`.
**Testing**: Hspec unit and golden suites through `just ci`; focused
unit/golden patterns for withdrawal final Phase-1 and
governance-withdrawal-init; `nix flake check` as the full reproducible
dependency proof.
**Target Platform**: Local Linux Nix development shell and CI NixOS
runner.
**Project Type**: Haskell CLI/library.
**Performance Goals**: No measurable performance target; validation
coverage increases by removing skips. Existing build/test runtime stays
within the repository gate.
**Constraints**: One dependency bump only; `cabal.project tag:` must be
`9e77e90728729bdd22e3bfbe0cf7515b33d5ea13`; regenerate the matching
`--sha256`; no reorganize module edits; no operator live-chain workflow;
no fixture rewrites except assertion changes directly tied to Phase-1
success; `ccEvaluateTx` exec-unit checks remain in place.
**Scale/Scope**: One source-repository-package pin, one shared
validation helper, one governance-withdrawal-init skip disposition, and
focused regression tests.

## Constitution Check

**I. Faithful port of the bash recipes**: PASS. The bump changes
offline validation coverage only. It does not change transaction body
construction or the bash-parity goldens except where existing tests prove
the now-active Phase-1 path.

**II. Pure builders, impure shell**: PASS. `validateFinalPhase1` remains
the shared build-runner pre-flight over an already built `ConwayTx` and
an injected `ChainContext`.

**III. Pluggable data source, local-node default**: PASS. No new backend
or chain query is introduced. Existing `ChainContext` fields feed
tx-tools validation.

**IV. Build, never sign or submit**: PASS. The PR never signs or submits
transactions and does not run operator treasury commands.

**V. Test-first with golden CBOR fixtures**: PASS. Each behavior change
has an explicit RED proof: a withdrawal-bearing final Phase-1 regression
and a governance-withdrawal-init fixture decision. RED and GREEN stay in
the same reviewed slice commit.

**VI. Hackage-ready Haskell**: PASS. Worker slices must preserve explicit
exports, Haddock on exports, fourmolu formatting, and warnings-clean
builds through `just ci`.

**VII. Label-1694 metadata**: PASS. No metadata shape or event enum
change.

Post-design check: PASS. The design still satisfies the constitution
after research/data-model/contracts: pure builders stay pure, no
operator command is added, and validation proof is local to existing
unit/golden gates.

## Live-Boundary Diagnostic

The behavior change is at the offline validation boundary between
`amaru-treasury-tx` and the pinned `cardano-tx-tools`
`validatePhase1` implementation. Unit and golden tests can exercise this
boundary deterministically because the validation input is a frozen
`ChainContext` plus a built `ConwayTx`; no live node state is required.

No extra live-boundary smoke is added to `gate.sh`. The full proof is:

- `./gate.sh` for repository-local unit/golden/schema/build coverage.
- Focused tests that prove withdrawal-bearing transactions now reach
  final Phase-1 validation and only witness-completeness failures are
  filtered.
- Governance-withdrawal-init fixture tests that either pass the normal
  path or surface the named residual ledger rule before scope expansion.
- `nix flake check` after the dependency bump to prove the fixed-output
  hash and clean Nix fetch across shipped checks.

## Deliverables And Surfaces

- `cabal.project` dependency pin and `--sha256`: canonical surface is
  `cabal.project`. Empirical release/docs scan
  `git grep -l 'cardano-tx-tools' .github/ flake.nix nix/ docs/
  README.md CHANGELOG.md` returns no additional release, packaging, or
  docs surfaces that name this dependency directly.
- Final Phase-1 validation behavior: canonical surfaces are
  `lib/Amaru/Treasury/Build/Common.hs` and every existing build runner
  that calls `validateFinalPhase1`. No executable or flag surface is
  added.
- Governance-withdrawal-init skip disposition: canonical surface is
  `lib/Amaru/Treasury/Build/GovernanceWithdrawalInit.hs` plus focused
  unit/golden tests.
- Regression proof: Hspec unit/golden tests and `./gate.sh`; `nix flake
  check` remains the full dependency proof.
- PR metadata: PR #192 body must name the selected upstream commit,
  version delta, regenerated hash proof, and workaround disposition.

## Vertical Review Slices

Each behavior-changing slice is one bisect-safe worker commit with RED
and GREEN in the same commit. The orchestrator reviews the returned
diff, reruns `./gate.sh`, and pushes only accepted commits.

1. **Slice 1 - Dependency pin and fetch proof.** Update
   `cabal.project` to pin `cardano-tx-tools` at
   `9e77e90728729bdd22e3bfbe0cf7515b33d5ea13` and replace the
   `--sha256` with the nix32 hash for that exact commit. RED proof:
   stale or wrong hash causes the Nix fixed-output fetch to fail. GREEN
   proof: the focused Nix prefetch/fetch succeeds for the commit, and
   `nix flake check` is started or run as the full dependency proof.

2. **Slice 2 - Withdrawal-bearing final Phase-1 validation.** Remove
   `validateFinalPhase1`'s withdrawal short-circuit and obsolete
   docstring/imports in `lib/Amaru/Treasury/Build/Common.hs`. Add a
   focused regression that constructs or reuses a withdrawal-bearing
   final transaction and proves `validateFinalPhase1` calls
   `validatePhase1`, accepts witness-completeness noise, and rejects
   structural failures. GREEN proof: focused unit/golden command plus
   `./gate.sh`.

3. **Slice 3 - Governance-withdrawal-init disposition.** Run existing
   governance-withdrawal-init proposal and materialization fixtures
   against the bumped validator. If both pass the normal path, replace
   `materializeResultSkipPhase1` with `materializeResult` and remove the
   helper/comment. If a separate residual rule remains, keep only the
   narrow skip, refresh the comment with the exact ledger failure and
   upstream issue, and open a Q-file before editing outside #191's
   boundary. GREEN proof: existing
   `GovernanceWithdrawalInitMaterializationSpec`,
   `GovernanceWithdrawalInitWizardMaterializationSpec`, proposal golden,
   and `./gate.sh`.

4. **Slice 4 - Metadata and full gate.** Update PR #192 metadata with
   the upstream commit, version delta, hash proof, and workaround
   disposition. Run `nix flake check` if not already completed in Slice
   1, then `./gate.sh`. This is orchestrator-owned unless metadata
   changes require task stamping after implementation.

## Project Structure

```text
specs/191-bump-tx-tools/
|-- spec.md
|-- plan.md
|-- research.md
|-- data-model.md
|-- quickstart.md
|-- contracts/
|   |-- dependency-pin.md
|   `-- final-phase1-validation.md
`-- tasks.md                  # produced after plan review by /speckit.tasks

cabal.project                 # cardano-tx-tools commit + nix32 hash
lib/Amaru/Treasury/Build/Common.hs
lib/Amaru/Treasury/Build/GovernanceWithdrawalInit.hs
test/unit/Amaru/Treasury/Build/GovernanceWithdrawalInitSpec.hs
test/golden/Amaru/Treasury/Tx/GovernanceWithdrawalInitWizardMaterializationSpec.hs
test/golden/Amaru/Treasury/Tx/GovernanceWithdrawalInitWizardProposalSpec.hs
```

**Structure Decision**: keep the feature inside the existing single
Haskell package. No new module family, executable, release artifact, or
operator documentation surface is introduced.

## Risks And Mitigations

| Risk | Mitigation |
|------|------------|
| The annotated tag object SHA is accidentally used in `cabal.project`. | Contracts and tasks must name only `9e77e90728729bdd22e3bfbe0cf7515b33d5ea13` as the `tag:` value. |
| The regenerated hash is for the wrong revision. | Nix fixed-output fetch and `nix flake check` must fail loudly before acceptance. |
| Removing the withdrawal skip exposes non-witness structural failures. | The regression must retain witness-completeness filtering while rejecting all other ledger failures. |
| Governance-withdrawal-init still fails for a separate deposit or return-account rule. | Stop through Q-file before expanding scope; retain a narrow skip only if the residual ledger rule and upstream issue are named. |
| Dependency bump changes APIs outside validation. | Worker stops for clarification before touching unrelated modules or adding compatibility refactors. |

## Complexity Tracking

No constitution violations or added architectural complexity.
