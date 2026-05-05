# Implementation Plan: On-chain anchor verification

**Branch**: `003-registry-walk` | **Date**: 2026-05-05 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/003-registry-walk/spec.md`
**Tracking issue**: [#30](https://github.com/lambdasistemi/amaru-treasury-tx/issues/30)
**Unblocks**: [PR #28](https://github.com/lambdasistemi/amaru-treasury-tx/pull/28)
**Upstream follow-up**: [lambdasistemi/cardano-node-clients#126](https://github.com/lambdasistemi/cardano-node-clients/issues/126)

## Summary

Land a registry walker that verifies every claim from an
operator-supplied (or upstream-fetched) `metadata.json`
against on-chain anchors and build-time-pinned constants. The
metadata becomes an untrusted hint, not a trust source. The
work also extends `Provider IO` with a batched address-set
query so the chain check is two LSQ round-trips per run.

## Technical Context

**Language/Version**: Haskell, GHC 9.6+.
**Primary Dependencies**:
- `http-client` + `http-client-tls` for the metadata HTTPS
  fetch.
- `aeson` for parsing.
- `plutus-ledger-api` (or `cardano-ledger-plutus`) for
  parameter-applying compiled Plutus blobs and computing
  script hashes.
- existing `Cardano.Node.Client.Provider` extended with
  `queryUTxOsAt :: Set Addr -> m (Map Addr [...])`.
- `file-embed` (Template Haskell) for embedding the Plutus
  blobs in non-Nix builds.

**Storage**: build-time assets (compiled Plutus blobs) under
`assets/` or pulled by Nix into `$out`.
**Testing**: Hspec unit tests + a mutation table that flips
each verifiable field and asserts the matching
`AnchorMismatch` constructor. Stub `MetadataFetcher` and stub
`Provider IO` (no HTTPS or socket in tests).
**Target Platform**: Linux + macOS.
**Project Type**: library + (downstream) CLI consumer.
**Performance Goals**: ≤ 2 LSQ round-trips per run (FR-011).
Sub-second on a warm socket.
**Constraints**:
- Constitution II/III: pure verification, IO confined to
  metadata fetch + Provider calls.
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
| III. Pluggable data source | ✅ | `MetadataFetcher` and `Provider` are records-of-functions, stub-friendly. |
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
                       # MetadataFetcher
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
gains:

```haskell
queryUTxOsAt :: Provider m -> Set Addr -> m (Map Addr [(TxIn, TxOut ConwayEra)])
```

Lands as a separate small PR in `cardano-node-clients`. This
branch's `cabal.project` bumps the SRP pin once that lands.

## Branch interaction

This branch lands on `main` first. Then PR #28 rebases:
- replaces its file-loading `loadRegistry` with
  `verifyRegistry`,
- drops `--registry PATH`,
- adds `[--metadata-url <url> | --metadata-file <path>]`.

That rebase is a separate PR step.

## Complexity Tracking

> Constitution Check passed without violations; section omitted.
