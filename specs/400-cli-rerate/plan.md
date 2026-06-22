# Implementation Plan: CLI Swap Re-Rate

**Branch**: `400-cli-rerate` | **Date**: 2026-06-22 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `specs/400-cli-rerate/spec.md`

## Summary

Add a dedicated `swap-rerate` CLI command that reuses the merged pure
re-rate planner/builder (`RerateIntent`, `planRerate`,
`runSwapRerate`) and the existing `swap-cancel` ownership/defaulting
logic. The command remains offline-capable for CI fixtures and uses N2C
only when `--node-socket` is provided. It writes unsigned product
artifacts only; the devnet smoke signs/submits solely as test proof.

## Technical Context

**Language/Version**: Haskell, GHC 9.12.3  
**Primary Dependencies**: `optparse-applicative`, `aeson`,
`cardano-ledger-conway`, `cardano-node-clients`, `cardano-tx-tools`  
**Storage**: Filesystem artifacts only  
**Testing**: Hspec unit tests, shell smoke scripts, opt-in
`devnet-tests`  
**Target Platform**: Linux CLI in the Nix dev shell  
**Project Type**: Haskell CLI plus test/smoke harness  
**Performance Goals**: CLI parser/help remains fast; no new persistent
service  
**Constraints**: Product path builds unsigned bodies only; pure builder
modules remain unchanged; live node access is opt-in  
**Scale/Scope**: One treasury scope per invocation, one or more selected
pending orders within the budget planner limits

## Constitution Check

- Principle II, pure builders/impure shell: PASS. This ticket wires CLI
  and gathering only; it reuses existing pure re-rate modules.
- Principle III, local-node default/pluggable source: PASS. N2C is
  opt-in through existing global socket handling.
- Principle IV, build never sign or submit: PASS for product CLI.
  Devnet signing/submission is test-only and must not add product flags.
- Principle V, test-first: PASS. Each implementation slice starts with
  RED tests or a documented RED-skip for shell smoke wiring.
- Principle VI, Hackage-ready Haskell: PASS. New exports need Haddock,
  explicit export lists, fourmolu/cabal-fmt, and `./gate.sh`.

### Live-Boundary Diagnostic

Question: what system boundary does this exercise that the unit suite
cannot?

Answer: the live SundaeSwap + treasury validator boundary and the live
N2C UTxO gathering boundary. Frozen unit contexts already contain every
UTxO, so they cannot prove the CLI asked the node for the selected order
UTxOs, order script ref, scope refs, wallet fuel, and collateral. The
devnet `RerateSmoke` must prove phase-2 acceptance and old/new order UTxO
transition, or the PR must stay draft with a named transcript artifact.

## Project Structure

```text
lib/Amaru/Treasury/Cli/
├── SwapRerate.hs          # new parser, runner, reports, selection glue
├── SwapCancel.hs          # read-only reuse/reference for helpers
├── SwapWizard.hs          # read-only fallback behavior reference
└── TreasuryInspect.hs     # pending-order discovery reference

app/amaru-treasury-tx/Main.hs
lib/Amaru/Treasury/Cli.hs

test/unit/Amaru/Treasury/Cli/
└── SwapRerateSpec.hs      # parser/branch behavior tests

scripts/smoke/
└── swap-rerate-offline    # fixture-backed CLI smoke

test/devnet/Amaru/Treasury/Devnet/
└── RerateSmoke.hs         # live N2C + phase-2 proof
```

**Structure Decision**: Add a CLI module and top-level command wiring.
Do not edit HTTP API, Operate UI, or the merged #398/#399 pure logic
unless a compile error exposes a missing export required by the CLI.

## Implementation Slices

### Slice 1 - CLI Surface And Branch Logic

Add `Amaru.Treasury.Cli.SwapRerate` with parser types, top-level
`swap-rerate` command wiring, report shape, selection modes, and unit
tests for parser and branch decisions. This slice may use stubs for
actual live/offline resolution but must compile and leave existing
commands unchanged.

### Slice 2 - Offline Re-Rate Build And Split Fallback

Implement offline fixture input resolution into `RerateIntent` and
`RerateProgramInputs`, call `runSwapRerate` for `SingleTx`, call the #399
budget planner for split output, write CBOR/report artifacts, and add
the offline `scripts/smoke/swap-rerate-offline` check to `just smoke`.

### Slice 3 - Live Discovery And Devnet Boundary Smoke

Wire N2C discovery from pending orders for one scope, gather the full
required UTxO set, and add `test/devnet/Amaru/Treasury/Devnet/RerateSmoke.hs`.
If runtime makes this too expensive for `./gate.sh`, keep the PR draft
and update the PR body with the named operator transcript path required
before readiness.

## Complexity Tracking

No constitution violations are planned. The only deliberate test-only
exception is devnet signing/submission inside `RerateSmoke`; product CLI
signing/submission remains out of scope.
