# Implementation Plan: Local Devnet Smoke

**Branch**: `080-local-devnet-smoke` | **Date**: 2026-05-11 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/home/paolino/amaru-treasury-tx-repo/specs/080-local-devnet-smoke/spec.md`

## Summary

Add an opt-in local devnet smoke flow for release verification. The
flow uses the repository-pinned `cardano-node-clients` devnet
sublibrary to start a short-epoch local `cardano-node`, verifies the
node socket and magic `42` before any treasury action, records timing
evidence and artifacts in a clean run directory, then exercises
withdrawal reward observation and disburse/build flows against live
local chain state.

The Amaru release CLI remains build-only: it emits unsigned Conway
transactions and reports. Any signing/submission needed to seed local
devnet state is confined to the opt-in smoke harness and is documented
as test setup, not as operator-facing CLI behavior.

## Technical Context

**Language/Version**: Haskell (GHC 9.12.3 via haskell.nix; constitution supports GHC 9.6+)  
**Primary Dependencies**: `cardano-node-clients`, public sublibrary `cardano-node-clients:devnet`, `cardano-node` binary, `optparse-applicative`, `aeson`, `directory`, `time`, Hspec  
**Storage**: Filesystem run directories only: socket/log transcript, timing evidence, intent JSON, unsigned CBOR, report JSON/Markdown  
**Testing**: Existing `just ci` with unit/golden/smoke remains the default gate; new `devnet-tests`/`just devnet-smoke` is manual and opt-in  
**Target Platform**: Local Linux Nix development shell first; Darwin docs may describe unsupported/manual status until the node binary path is proven there  
**Project Type**: Single-package Haskell CLI plus opt-in integration smoke harness  
**Performance Goals**: Node-ready or node-failed result within 2 minutes; positive withdrawal reward observed within 10 minutes or fail with last observation  
**Constraints**: Do not put devnet smoke in default CI; do not let devnet support weaken mainnet/preprod/preview validation; keep pure builders pure; keep signing/submission out of `amaru-treasury-tx` release commands; clean stale artifacts per run  
**Scale/Scope**: One maintainer-run local node at a time, one isolated run directory per smoke execution, three independently runnable phases: node, withdraw, disburse/build

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

**I. Faithful port of the bash recipes**: PASS. Release-facing
`disburse`, `withdraw`, and `tx-build` behavior remains aligned with
the bash recipes. The local devnet smoke is verification harness code,
not a replacement recipe.

**II. Pure builders, impure shell**: PASS. Transaction builders stay
pure over the existing `TxBuild` boundary. Devnet startup, reward
waiting, artifact writing, and any local chain seeding are effectful
smoke/test boundaries.

**III. Pluggable data source, local-node default**: PASS. The smoke
uses the existing N2C local-node trust model and exercises the same
backend boundary as release-facing commands.

**IV. Build, never sign or submit**: PASS WITH BOUNDARY NOTE. Amaru
commands still build unsigned transactions only. Local devnet state
preparation may sign/submit setup transactions inside the smoke
harness; those helpers must not be exposed as release operator
commands.

**V. Test-first with golden CBOR fixtures**: PASS. Existing golden
fixtures remain the release regression gate. The devnet smoke adds
live evidence and must be introduced with failing Hspec/contract
checks before green implementation where behavior changes are needed.

**VI. Hackage-ready Haskell**: PASS. New Haskell modules need explicit
exports, Haddock on exports, fourmolu formatting, warning-clean code,
and Cabal metadata updates.

## Project Structure

### Documentation (this feature)

```text
specs/080-local-devnet-smoke/
|-- plan.md
|-- research.md
|-- data-model.md
|-- quickstart.md
|-- contracts/
|   `-- local-devnet-smoke.md
`-- tasks.md
```

### Source Code (repository root)

```text
amaru-treasury-tx.cabal
flake.nix
justfile
README.md
mkdocs.yml

lib/Amaru/Treasury/
|-- Backend/N2C.hs
|-- Cli/Common.hs
|-- IntentJSON/Common.hs
|-- Tx/DisburseWizard.hs
|-- Tx/SwapWizard.hs
`-- Tx/WithdrawWizard.hs

test/unit/
|-- Amaru/Treasury/BuildSpec.hs
|-- Amaru/Treasury/IntentJSONSpec.hs
|-- Amaru/Treasury/Tx/DisburseWizardSpec.hs
|-- Amaru/Treasury/Tx/SwapWizardSpec.hs
`-- Amaru/Treasury/Tx/WithdrawWizardSpec.hs

test/devnet/
|-- Spec.hs
`-- Amaru/Treasury/Devnet/SmokeSpec.hs

scripts/smoke/
`-- devnet-local

docs/
|-- local-devnet-smoke.md
`-- release.md
```

**Structure Decision**: Use the existing single-package layout. Shared
network parsing changes belong in `lib/Amaru/Treasury/*` and their
unit tests. Live node verification belongs in a separate opt-in
`test/devnet` test suite plus `scripts/smoke/devnet-local`, keeping
slow/effectful work out of `just ci`.

## Phase 0 Output

- [research.md](./research.md) records the dependency, network-alias,
  epoch-length, chain-preparation, and release-gating decisions.

## Phase 1 Output

- [data-model.md](./data-model.md) defines the run, timing,
  prepared-state, reward-observation, and artifact entities.
- [contracts/local-devnet-smoke.md](./contracts/local-devnet-smoke.md)
  defines the manual smoke command contract and artifact layout.
- [quickstart.md](./quickstart.md) gives the target maintainer flow.

## Review Slices

Each behavior-changing slice must be committed with its RED/regression
proof and GREEN implementation together. Red-only exploratory failures
may be run locally and recorded in the handoff, but must not survive as
standalone broken commits.

1. **Spec Kit planning slice**: add `spec.md`, `plan.md`,
   `research.md`, `data-model.md`, contracts, quickstart, tasks, and
   local PR review notes. No runtime behavior changes.
2. **Network identity slice**: add `devnet` as a local-only testnet
   network name across CLI parsing, intent reward-account parsing,
   socket magic resolution, and reports, with unit tests proving
   public-network behavior is unchanged.
3. **Node smoke slice**: add the opt-in `devnet-tests` suite,
   `scripts/smoke/devnet-local`, `just devnet-smoke`, and a node-only
   live smoke using `cardano-node-clients:devnet`.
4. **Withdrawal reward slice**: add reward observation, timeout
   diagnostics, and positive-reward withdrawal intent generation for
   the local devnet.
5. **Disburse/build slice**: add local treasury-state discovery or
   typed missing-state diagnostics plus wizard-to-build artifact
   generation.
6. **Documentation/release slice**: add maintainer docs, README/MkDocs
   links, release checklist updates, and final gate evidence.

## Constitution Re-Check

Post-design status remains PASS. The only risky boundary is local
devnet chain preparation, and the design keeps it inside the opt-in
smoke harness with explicit documentation that release CLI commands
still never sign or submit.

## Complexity Tracking

No constitution violations.
