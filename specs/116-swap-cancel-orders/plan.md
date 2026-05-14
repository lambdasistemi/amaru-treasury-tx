# Implementation Plan: Cancel Pending SundaeSwap Orders

**Branch**: `116-swap-cancel-orders` | **Date**: 2026-05-14 |
**Spec**: [spec.md](./spec.md)

## Status

**Completed**: issue created, WIP worktree opened, cancel authority
rules confirmed from SundaeSwap V3 and current Amaru order datum shape;
Spec Kit artifacts; RED/GREEN tests for cancel redeemer, datum owner /
destination validation, pure cancel transaction body shape, stable datum
diagnostics, explicit-order `swap-cancel` parser/runner/report output,
operator docs, and full local CI.  
**Current**: inspect-report integration handoff.  
**Blockers**: #109 pending-order discovery/report shape for direct
inspect-to-cancel integration.

## Summary

Add a treasury `swap-cancel` path that spends one pending SundaeSwap V3
order with the cancel redeemer, returns the order value to the selected
treasury, and requires the signer policy encoded in the order datum.
Keep discovery and live-order selection behind #109; this slice works
from an explicit order UTxO and frozen fixtures.

## Technical Context

**Language/Version**: Haskell, current repo GHC via Nix dev shell.  
**Primary Dependencies**: `cardano-node-clients` `TxBuild`,
Cardano ledger Conway types, `PlutusCore.Data`.  
**Storage**: N/A.  
**Testing**: Hspec unit tests plus eventual golden/frozen build tests.  
**Target Platform**: CLI on Linux and macOS.  
**Project Type**: Single Haskell library plus CLI executable.  
**Performance Goals**: N/A; one-order build path.  
**Constraints**: build only; no signing or submission; pure builder
remains separate from node queries; cancellation must fail closed on
unrecognized datum authority.  
**Scale/Scope**: one order per command invocation in this issue.

## Constitution Check

*GATE: Must pass before implementation and re-check after design.*

- **I. Faithful port of bash recipes.** Pass with documented extension.
  The original bash swap recipe creates orders but has no cancel entry
  point; this feature is a new operator command because cancellation was
  not covered by the original recipe set.
- **II. Pure builders, impure shell.** Pass. The cancel transaction shape
  lives in a pure `TxBuild` program. Node queries and order discovery stay
  in CLI/backend code.
- **III. Pluggable data source, local-node default.** Pass. The command
  will use the existing backend boundary; #109 owns richer discovery.
- **IV. Build, never sign or submit.** Pass. The command emits unsigned
  CBOR/report only.
- **V. Test-first with golden CBOR fixtures.** Pass for this slice with
  RED/GREEN unit tests first. Golden frozen CBOR is a later task once
  reference-script fixture data is available.
- **VI. Hackage-ready Haskell.** Pass. New exports need Haddock and
  formatting/lint gates.

## Project Structure

### Documentation

```text
specs/116-swap-cancel-orders/
+-- spec.md
+-- plan.md
+-- research.md
+-- data-model.md
+-- quickstart.md
+-- contracts/
|   +-- swap-cancel-cli.md
+-- checklists/
|   +-- requirements.md
+-- tasks.md
```

### Source Code

```text
lib/Amaru/Treasury/
+-- Redeemer.hs                 # add SundaeSwap V3 cancel redeemer
+-- Tx/SwapCancel.hs            # pure cancel transaction program
+-- Tx/SwapCancel/Datum.hs      # minimal safe parser for Amaru order datum
+-- Cli/SwapCancel.hs           # CLI parser and runner after foundations
+-- Cli.hs                      # command registration

test/unit/Amaru/Treasury/Tx/
+-- SwapCancelSpec.hs           # pure program and datum parser tests
```

## Phase 0: Research Output

See [research.md](./research.md).

## Phase 1: Design Output

See:

- [data-model.md](./data-model.md)
- [contracts/swap-cancel-cli.md](./contracts/swap-cancel-cli.md)
- [quickstart.md](./quickstart.md)

## Implementation Slices

### Slice 1 - Cancel datum and redeemer foundations

Add the SundaeSwap cancel redeemer (`Constr 1 []`) and a parser for the
Amaru-generated V3 order datum owner/destination. The parser supports
legacy `AllOf` all-owner signatures and current `AtLeast 2` all-owner
signatures, and rejects unsupported authority forms.

### Slice 2 - Pure cancel transaction program

Add a pure `swapCancelProgram` that spends wallet fuel, uses wallet fuel
as collateral, spends the order script input with the cancel redeemer,
references the Sundae order script, pays the full order value to the
treasury destination, adds required signers, and applies validity.

### Slice 3 - CLI runner

Add `swap-cancel` parser and runner once the minimal input contract is
stable. The runner can accept an explicit `--order-txin` first; #109
will later add inspect-report selection.

### Slice 4 - Inspect integration

Wire #109 pending-order output into `swap-cancel` once that report shape
is merged.

## Complexity Tracking

No constitution violations. The only extension is that this command has
no legacy bash equivalent; the reason is operational safety for already
created SundaeSwap orders.
