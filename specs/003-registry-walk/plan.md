# Implementation Plan: Upstream metadata fetch + chain sanity-check

**Branch**: `003-registry-walk` | **Date**: 2026-05-05 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/003-registry-walk/spec.md`
**Tracking issue**: [#30](https://github.com/lambdasistemi/amaru-treasury-tx/issues/30)
**Unblocks**: [PR #28](https://github.com/lambdasistemi/amaru-treasury-tx/pull/28)

## Summary

Add a small IO-bearing module that fetches
`pragma-org/amaru-treasury/journal/2026/metadata.json` at a
pinned commit, verifies every TxIn it names is still unspent
against `Provider IO`, and projects the result into the existing
`RegistryView` shape on branch `002-swap-wizard`. Removes the
`--registry PATH` flag and replaces it with `--metadata-commit
<sha>` (default = a baked-in constant). The wizard never reads
registry data from disk.

## Technical Context

**Language/Version**: Haskell, GHC 9.6+ (matches the rest of the
project).
**Primary Dependencies**:
- `http-client` + `http-client-tls` for the HTTPS GET against
  `raw.githubusercontent.com`.
- `aeson` for parsing `metadata.json` (already a dep).
- existing `Cardano.Node.Client.Provider` `queryUTxOByTxIn` for
  the chain-sanity check.
- existing `Amaru.Treasury.Tx.SwapWizard` types
  (`RegistryView`, `ScopeOwners`, `TreasuryRefs`,
  `ResolverError`) — extended on this branch to add the new
  error constructors; the v1 wizard from PR #28 will rebase on
  top.

**Storage**: none. The metadata is fetched per run; no local
cache.
**Testing**: Hspec unit tests with a stub `Manager`-equivalent
(or pluggable HTTP function) and a stub `Provider IO` per the
existing pattern in `SwapWizardSpec`. A checked-in
`metadata.json` fixture lifted from a known upstream commit.
**Target Platform**: Linux (CI) + macOS (dev), x86_64 + aarch64.
**Project Type**: library extension + CLI wiring — same package.
**Performance Goals**: one HTTPS round trip + N small
`queryUTxOByTxIn` calls (N ≤ ~12). Total ≤ 2 s warm. Not a hot
path.
**Constraints**:
- **No local-file metadata input** (FR-004). The CLI cannot
  accept `--metadata-path` or `--registry`.
- `defaultUpstreamCommit` is a 40-char hex SHA (FR-010). No
  branches, no tags. PRs that advance it must show the SHA delta.
- `Provider IO` reachability is a hard precondition. The
  resolver fails closed if the chain check can't run.
- Hackage-ready style (Constitution VI): Haddock on every
  export, fourmolu 70-col, `-Werror`.

**Scale/Scope**: Adds one new module
(`Amaru.Treasury.Metadata.Upstream`), one CLI flag rename, one
fixture file, ~150 lines of test code. Touches PR #28's wiring
to drop `--registry PATH`.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Faithful port of bash recipes | ✅ | Uses upstream's own `metadata.json` — same source the bash recipes already `jq`. |
| II. Pure builders, impure shell | ✅ | Pure: `parseUpstreamMetadata`, `projectRegistryView`. Impure: `fetchMetadata`, `verifyMetadataAgainstChain`, both behind small typed interfaces. |
| III. Pluggable data source | ✅ | The HTTP fetch sits behind a `MetadataFetcher m` record so tests can stub without `http-client`. |
| IV. Build, never sign or submit | ✅ | This module produces JSON only; no tx logic. |
| V. Test-first with golden fixtures | ✅ | Spec is authored RED first; checked-in fixture metadata.json drives the unit tests. |
| VI. Hackage-ready Haskell | ✅ | New module follows the `/haskell` skill rules; `cabal check` re-run as polish. |

No violations. Complexity Tracking omitted.

## Project Structure

### Documentation (this feature)

```text
specs/003-registry-walk/
├── plan.md          # this file
├── research.md      # Phase 0 output
├── data-model.md    # Phase 1 output
├── quickstart.md    # Phase 1 output
├── contracts/
│   └── metadata-upstream.md   # schema mirror + URL contract
└── tasks.md         # Phase 2 output
```

### Source Code (repository root)

```text
lib/Amaru/Treasury/Metadata/
└── Upstream.hs                # NEW: types + parser + fetch +
                               # chain verification + projection

app/amaru-treasury-tx/
└── Main.hs                    # touched on the rebased PR #28:
                               # drop --registry PATH; add
                               # --metadata-commit <sha>; call
                               # resolver via Upstream module

test/unit/Amaru/Treasury/Metadata/
└── UpstreamSpec.hs            # NEW: parser + projection +
                               # verifier (stubbed Provider) +
                               # error-paths

test/fixtures/metadata-upstream/
├── metadata.json              # NEW: lifted from a pinned
                               # upstream commit
└── README.md                  # records the upstream commit SHA
```

**Structure Decision**: The new module lives under
`Amaru.Treasury.Metadata.*` rather than alongside the wizard, so
the rest of the CLI (`disburse`, `reorganize`, `withdraw`) can
adopt the same source of truth incrementally. The wizard wiring
stays on its own branch (002) and rebases on top.

## Branch interaction

This branch lands on `main` first. PR #28 (`002-swap-wizard`)
then rebases on top of merged `main` and:

- replaces `loadRegistry :: FilePath -> IO RegistryView` with
  the new `Upstream` module,
- drops `--registry PATH` from `WizardOpts`,
- adds `--metadata-commit <sha>` (with the same default
  constant),
- updates the integration test stub.

That rebase is a separate PR step, not part of this branch's
diff.

## Complexity Tracking

> Constitution Check passed without violations; this section is
> omitted.
