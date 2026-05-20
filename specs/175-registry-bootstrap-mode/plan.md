# Implementation Plan: registry-init fresh DevNet bootstrap mode

**Branch**: `175-registry-bootstrap-mode` | **Date**: 2026-05-20 | **Spec**: [spec.md](./spec.md)
**Issue**: [#175](https://github.com/lambdasistemi/amaru-treasury-tx/issues/175)
**Parent Issue**: [#156](https://github.com/lambdasistemi/amaru-treasury-tx/issues/156)
**Draft PR**: [#176](https://github.com/lambdasistemi/amaru-treasury-tx/pull/176)

## Summary

Split `registry-init-wizard` into two explicit resolver modes:

- **verified mode**: the existing default path from #158, still calling
  `verifyRegistry` and projecting a real `RegistryView`;
- **bootstrap mode**: DevNet-only, opt-in, and allowed to emit the three
  registry-init intents before any registry anchors exist on chain.

The bootstrap mode still uses the existing intent JSON and `tx-build`
registry-init builders. It does not build, sign, submit, or verify
transactions inside the wizard. A separate shipped artifact writer
materializes `registry.json` after the operator or #161 smoke has
submitted the three transactions.

## Technical Context

**Language/Version**: Haskell, GHC via repository Nix shell
**Primary Dependencies**: existing `registry-init-wizard`,
`IntentJSON`, `Build.RegistryInit`, `Devnet.RegistryInit` script
derivation/artifact helpers, `optparse-applicative`
**Testing**: Hspec unit tests, golden tests, existing `just ci`
**Target Platform**: local Linux Nix development shell
**Constraints**: DevNet-only, no in-wizard construction/signing/submission,
one bisect-safe commit per behavior slice

## Live-Boundary Diagnostic

Question: what boundary does this exercise that unit tests cannot?

The actual fresh-chain failure was found by #161's live smoke. This PR
does not replace that live proof. It adds the missing shipped CLI surface
and unit/golden evidence that the surface can emit buildable intents
without existing registry anchors. The final live proof remains #161:
`scripts/smoke/smoke.sh --phase registry-stake` must run the new surface
through `tx-build`, `witness`, `attach-witness`, and `submit` against a
real DevNet.

## Design Decisions

### Bootstrap Is Explicit

Use an explicit bootstrap switch on the existing three subcommands
(`--bootstrap`) rather than making fresh-chain behavior implicit. This
keeps the default #158 behavior intact and makes the dangerous path
visible in shell history, docs, and the smoke transcript.

### Skeleton Scope Is Intent-Only

The registry-init `tx-build` translators consume the wallet block,
network, validity upper bound, and registry-init payload fields. They do
not use the post-deployment `ScopeJSON` anchors for construction. The
bootstrap resolver may therefore construct a minimal skeleton scope for
intent JSON, but runtime artifacts written after submit must use real tx
ids and refs.

### Artifact Writer Is Post-Submit

The wizard cannot know submitted tx ids when it emits intents. Therefore
artifact writing is a separate shipped command under the registry-init
surface. It takes:

- `--seed-split-txid`
- `--registry-mint-txid`
- `--reference-scripts-txid`
- `--scopes-seed-txin`
- `--registry-seed-txin`
- `--owner-key-hash`
- `--network-magic`
- `--run-dir` or `--out-dir`

It derives scripts from the seed TxIns using `deriveDevnetScripts`, maps
registry mint output `#0/#1` to scopes/registry anchors, maps
reference-scripts output `#0/#1` to permissions/treasury anchors, and
writes the existing registry-init artifact shape.

## Vertical Review Slices

1. **Slice 1 - Bootstrap parser and mode split.** Add `--bootstrap` to
   the three registry-init subcommands, introduce explicit verified vs
   bootstrap runner branches, and add focused parser/source tests proving
   the default path still verifies while bootstrap does not.
2. **Slice 2 - Bootstrap resolver and three intents.** Add a
   DevNet-only bootstrap resolver that selects wallet UTxOs and validity
   upper bound without `verifyRegistry`; wire seed-split, mint, and
   reference-scripts bootstrap intent emission; add round-trip and golden
   coverage through existing `tx-build`.
3. **Slice 3 - Artifact writer.** Add the shipped post-submit artifact
   writer and tests for tx-id-derived anchors, script/policy derivation,
   malformed input, non-DevNet fail-closed behavior, and no partial
   artifact writes on failure.
4. **Slice 4 - Docs and #161 handoff.** Update README/local smoke docs
   and PR body with the command sequence #161 must consume. Comment on
   #175/#161/#156 with the handoff once verified.
5. **Slice 5 - Finalization.** Full local gate, finalization audit, drop
   `gate.sh`, and mark PR #176 ready only after evidence exists.

## Project Structure

```text
specs/175-registry-bootstrap-mode/
|-- spec.md
|-- plan.md
|-- tasks.md
`-- checklists/requirements.md

lib/Amaru/Treasury/Tx/RegistryInitWizard.hs
lib/Amaru/Treasury/Cli/RegistryInitWizard.hs
test/unit/Amaru/Treasury/Tx/RegistryInitWizard*.hs
test/unit/Amaru/Treasury/Cli/RegistryInitWizard*.hs
test/golden/Amaru/Treasury/Tx/RegistryInitWizard*.hs
README.md
docs/local-devnet-smoke.md
gate.sh
```

No planned changes to `IntentJSON`, `Build.RegistryInit`, or the #161
smoke branch in this PR.

## Risks & Mitigations

- **Risk**: Bootstrap skeleton scope leaks into runtime artifacts.
  **Mitigation**: Unit tests assert the artifact writer uses submitted tx
  ids for anchors and derived scripts/policies for hashes, never skeleton
  placeholders.
- **Risk**: Default verified mode regresses.
  **Mitigation**: Existing #158 tests stay in the gate; add a focused
  test that default mode still calls the verified path.
- **Risk**: A hidden in-process runner slips back in.
  **Mitigation**: Keep wizard output to intent/artifact writing only.
  #161 static guards still reject `runDevnet*` in the smoke path.
- **Risk**: The command grows into #163.
  **Mitigation**: No state file, no resumability, no bundle. Operator
  still hand-carries inter-tx state.
