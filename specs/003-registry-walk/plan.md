# Implementation Plan: On-chain anchor verification

**Branch**: `003-registry-walk` | **Date**: 2026-05-05 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/003-registry-walk/spec.md`
**Tracking issue**: [#30](https://github.com/lambdasistemi/amaru-treasury-tx/issues/30)
**Unblocks**: [PR #28](https://github.com/lambdasistemi/amaru-treasury-tx/pull/28)
**Upstream dependency**: [lambdasistemi/cardano-node-clients#128](https://github.com/lambdasistemi/cardano-node-clients/pull/128)

## Summary

Land a registry walker that verifies every claim from an
operator-supplied local `metadata.json` against on-chain
anchors and build-time-pinned constants. The metadata becomes
an untrusted hint, not a trust source. The work consumes
`Provider IO` acquired sessions so the chain check runs two
LSQ-backed queries against one acquired ledger snapshot.

## Technical Context

**Language/Version**: Haskell, GHC 9.12.3.
**Primary Dependencies**:
- `aeson` for parsing the local metadata file.
- `plutus-ledger-api` (or `cardano-ledger-plutus`) for
  parameter-applying compiled Plutus blobs and computing
  script hashes.
- existing `Cardano.Node.Client.Provider` with
  `withAcquired` and the acquired handle selectors
  `queryUTxOsAtH` / `queryUTxOByTxInH`.
- `file-embed` (Template Haskell) for embedding the Plutus
  blobs in non-Nix builds.

**Storage**: build-time assets (compiled Plutus blobs) under
`assets/` or pulled by Nix into `$out`.
**Testing**: Hspec unit tests + a mutation table that flips
each verifiable field and asserts the matching
`AnchorMismatch` constructor. Use a local metadata fixture and
stub `Provider IO` (no HTTPS or socket in tests).
**Target Platform**: Linux + macOS.
**Project Type**: library + (downstream) CLI consumer.
**Performance Goals**: one acquired Provider session and ≤ 2
LSQ-backed queries per run (FR-011).
Sub-second on a warm socket.
**Constraints**:
- Constitution II/III: pure verification, IO confined to
  local file read + Provider calls.
- Constitution V: test-first; mutation table is the safety
  property made executable.
- Constitution VI: Hackage-ready; new exports get Haddock.

**Scale/Scope**: One new module tree
(`Amaru.Treasury.Registry.{Constants,Metadata,Verify,Derive}`),
one Provider extension, one CLI flag rename, ~300 lines of
test code.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Faithful port of bash recipes | ✅ | The wizard's behaviour mirrors the bash recipes' use of `metadata.json`; we just refuse to trust it without verification. |
| II. Pure builders, impure shell | ✅ | `verifyRegistry` is the only IO entry point; everything inside is parameter-application + comparison. |
| III. Pluggable data source | ✅ | The only data-source surface in this PR is the local metadata file plus stub-friendly `Provider`. |
| IV. Build, never sign or submit | ✅ | This module produces typed values; no tx logic. |
| V. Test-first with golden fixtures | ✅ | The mutation table on every verifiable field is the spec made executable. |
| VI. Hackage-ready Haskell | ✅ | New module follows `/haskell` style. |

No violations.

## Project Structure

### Documentation (this feature)

```text
specs/003-registry-walk/
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/
│   └── metadata-upstream.md
└── tasks.md
```

### Source Code (repository root)

```text
lib/Amaru/Treasury/Registry/
├── Constants.hs       # NEW: seeds, token names, expiration,
                       # Plutus blobs (TH-embedded)
├── Derive.hs          # NEW: parameter-apply + hash helpers
├── Metadata.hs        # NEW: UpstreamMetadata + FromJSON +
                       # local file reader
└── Verify.hs          # NEW: VerifiedRegistry + verifyRegistry

assets/plutus/
├── scopes.cbor                  # NEW: lifted from upstream plutus.json
├── treasury_registry.cbor       # NEW
├── permissions.cbor             # NEW
└── treasury.cbor                # NEW

test/unit/Amaru/Treasury/Registry/
├── DeriveSpec.hs
├── MetadataSpec.hs
└── VerifySpec.hs                # mutation table

test/fixtures/registry-walk/
├── metadata.json                # lifted from a pinned upstream commit
└── README.md                    # records the upstream commit
```

### Provider IO extension

`lambdasistemi/cardano-node-clients/lib/Cardano/Node/Client/Provider.hs`
gained, via
[`cardano-node-clients#128`](https://github.com/lambdasistemi/cardano-node-clients/pull/128):

```haskell
withAcquired :: Provider m -> (QueryHandle m -> m a) -> m a
queryUTxOsAtH :: QueryHandle m -> Set Addr -> m (Map Addr [(TxIn, TxOut ConwayEra)])
queryUTxOByTxInH :: QueryHandle m -> Set TxIn -> m (Map TxIn (TxOut ConwayEra))
```

This branch's `cabal.project` pins the merged upstream commit.

## Branch interaction

This branch lands on `main` first. Then PR #28 rebases:
- replaces its file-loading `loadRegistry` with
  `verifyRegistry`,
- drops `--registry PATH`,
- adds `--metadata <path>`.

That rebase is a separate PR step.

## Complexity Tracking

> Constitution Check passed without violations; section omitted.
