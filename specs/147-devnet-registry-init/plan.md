# Implementation Plan: DevNet Registry Initiator

**Branch**: `147-devnet-registry-init` | **Date**: 2026-05-16 | **Spec**: [spec.md](./spec.md)  
**Issue**: [#147](https://github.com/lambdasistemi/amaru-treasury-tx/issues/147)  
**Parent Issue**: [#151](https://github.com/lambdasistemi/amaru-treasury-tx/issues/151)

## Status

**Current**: Issue #147 has an isolated branch and draft PR. This plan
defines the production-backed registry initiator slice that must land
before #148, #149, and #150 start.

**Blockers**: No upstream blocker is known. The live DevNet proof still
requires a local Nix shell capable of starting `cardano-node-clients`
DevNet.

## Implementation Ownership

The orchestrator owns this specification, plan, task breakdown, local
review, final PR metadata, and local verification. Behavior-changing
code slices are implemented by one subagent at a time after this plan
and `tasks.md` have passed local review.

Before every subagent handoff, the orchestrator must analyze the
relevant code path, existing architecture, and task slice, then apply
any needed spec/plan/tasks/brief corrections locally. Subagents receive
corrected, narrow implementation briefs; they are not used to discover
or repair orchestration gaps.

Each subagent receives a narrow brief naming exact task ids, owned
files/modules, forbidden scope, RED proof, GREEN proof, and the gate to
run. The orchestrator reviews the returned diff, runs verification
locally, updates artifacts/PR metadata, and only then starts the next
subagent or child ticket.

## Parent Carry-Forward Invariant

For every remaining child ticket under #151 (#148, #149, and #150), the
operator command is paramount: the first P1 user story and acceptance
target must be a shipped production command for the operator-created
bootstrap transaction. A smoke phase may prove the command on DevNet,
but it must not replace the command, and the orchestrator must correct
any spec/plan/tasks draft that treats the command as optional or
follow-up before handing work to a subagent.

## Summary

Move the DevNet registry/scopes NFT publication and permissions/treasury
reference-script publication out of
`test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs` into a production
library entry point, and expose it through a shipped
`amaru-treasury-tx` DevNet registry-init command. Add a
`registry-init` opt-in DevNet smoke phase that proves the same
production command path, verifies the resulting on-chain UTxOs, and
writes structured handoff artifacts for later bootstrap child tickets.

Correction note: the earlier plan treated the public CLI wrapper as a
follow-up. That was too weak for parent issue #151, which is explicitly
about command recovery. #147 is not complete until the shipped command
surface exists and is documented.

## Technical Context

**Language/Version**: Haskell via the repository Nix shell.  
**Primary Dependencies**: `cardano-node-clients`, `cardano-tx-tools`,
Cardano ledger packages, existing Amaru registry constants.  
**Storage**: Run-directory JSON artifacts under `runs/devnet/...`.  
**Testing**: Hspec unit/devnet tests, CLI parser/runner tests,
`just ci`, opt-in `just devnet-smoke registry-init` for live boundary
evidence.
**Target Platform**: Local Linux Nix development shell.  
**Project Type**: Haskell CLI/library plus opt-in DevNet smoke.  
**Performance Goals**: Registry-init smoke completes inside the
existing DevNet wait budget; no default CI DevNet startup.  
**Constraints**: Keep normal release-facing treasury build commands
build-only; add only the explicit DevNet bootstrap command needed by
#147; reject non-DevNet networks before signing/submission; no
external-role transaction behavior in this slice.
**Scale/Scope**: One production-backed registry initiator, one shipped
DevNet command, one smoke proof phase, focused tests, docs, and PR
metadata for #147.

## Constitution Check

**I. Faithful port of the bash recipes**: PASS. This slice only
publishes local DevNet registry bootstrap state. It does not change
disburse, withdraw, or reorganize transaction parity.

**II. Pure builders, impure shell**: PASS WITH BOUNDARY NOTE. The
registry initiator necessarily queries, builds, signs, submits, and
waits inside the DevNet bootstrap boundary. The reusable construction
and artifact projection move to `lib/`; smoke remains orchestration and
verification.

**III. Pluggable data source, local-node default**: PASS. The proof uses
the local node provider/submitter path already used by the DevNet smoke.

**IV. Build, never sign or submit**: PASS WITH REVIEWED DEVNET
EXCEPTION. Normal release-facing treasury build commands remain
build-only. The registry-init command is a DevNet-only bootstrap
exception required by #151 and must reject non-DevNet networks before
signing/submitting.

**V. Test-first with golden CBOR fixtures**: PASS. Behavior changes get
RED/GREEN proof in the same reviewed slice. Live chain effects are
proved by the opt-in DevNet smoke because static golden CBOR cannot
prove submitted local-node UTxOs.

**VI. Hackage-ready Haskell**: PASS. New public modules need explicit
exports, Haddock on exports, fourmolu formatting, Cabal exposure, and
`just ci`.

**VII. Label-1694 metadata**: PASS. This slice does not change metadata
body shape or event values.

## Vertical Review Slices

1. **Spec/process slice**: create Spec Kit artifacts, solo review notes,
   and the local quality gate. No production code.
2. **Contract RED slice**: add failing contract coverage for the
   `registry-init` phase and registry artifact shape. This is the first
   subagent-owned code slice. RED evidence: current branch rejects
   `registry-init` as an unknown phase and has no production
   registry-init module.
3. **Production initiator slice**: add
   `Amaru.Treasury.Devnet.RegistryInit` under `lib/`, move reusable
   registry script derivation, publication builders, anchor types, and
   artifact projection there, expose it in Cabal, and replace the inline
   `SmokeSpec.hs` ownership with calls into the module. This remains
   subagent-owned.
4. **Live verification slice**: make `just devnet-smoke registry-init`
   submit the production-backed publication flow, query the local node
   for scopes/registry/reference-script anchors, and write
   `registry-init/*.json` artifacts. The subagent implements the slice;
   the orchestrator reruns the live proof locally.
5. **CLI command correction slice**: add the shipped
   `amaru-treasury-tx` DevNet registry-init command as a thin wrapper
   around the production module. It must accept explicit socket,
   funding address, signing source, and run directory inputs; reject
   non-DevNet networks; write the same artifact contract; and be proved
   by focused parser/runner tests plus the live DevNet smoke.
6. **Docs/metadata slice**: document the command, phase, and artifacts in README
   and local DevNet docs, then update PR metadata with the verified run
   directory and command evidence. Documentation may be orchestrator-owned
   after the code slice has been reviewed.

## Project Structure

```text
specs/147-devnet-registry-init/
|-- spec.md
|-- plan.md
|-- research.md
|-- data-model.md
|-- quickstart.md
|-- contracts/
|   `-- devnet-registry-init.md
|-- checklists/
|   `-- requirements.md
`-- tasks.md

lib/Amaru/Treasury/Devnet/
`-- RegistryInit.hs

lib/Amaru/Treasury/Cli/
`-- Devnet.hs

test/unit/Amaru/Treasury/Devnet/
`-- RegistryInitSpec.hs

test/devnet/
|-- Spec.hs
`-- Amaru/Treasury/Devnet/SmokeSpec.hs

scripts/smoke/
`-- devnet-local

docs/
`-- local-devnet-smoke.md
```

## Complexity Tracking

No constitution violations. The main risk is accidentally preserving
transaction construction ownership in `SmokeSpec.hs`; the code review
gate for #147 explicitly checks that reusable registry publication
logic lives under `lib/`.
