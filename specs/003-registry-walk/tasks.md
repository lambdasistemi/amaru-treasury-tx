# Tasks: On-chain anchor verification for the registry walk

**Input**: Design documents from `/specs/003-registry-walk/`
**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md),
[research.md](./research.md), [data-model.md](./data-model.md),
[contracts/metadata-upstream.md](./contracts/metadata-upstream.md),
[quickstart.md](./quickstart.md)

**Tests**: Required by Constitution V and FR-001..FR-007.
The mutation table on every verifiable field is the safety
property made executable.

**Reviewer reads on**: [PR #31](https://github.com/lambdasistemi/amaru-treasury-tx/pull/31).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: parallelizable (different files, no dependency on
  unfinished tasks)
- **[Story]**: which user story (US1 / US2 / US3)
- File paths absolute relative to repo root

The owning contract for any list reproduced below is the file
in brackets — see
[data-model.md](./data-model.md) and
[contracts/metadata-upstream.md](./contracts/metadata-upstream.md).

---

## Phase 1: Setup (shared infrastructure)

**Purpose**: cabal/Nix plumbing and the Plutus-blob asset
pipeline.

- [X] T001 Add `lib/Amaru/Treasury/Registry/{Constants,
      Derive, Metadata, Verify}.hs` to the
      `exposed-modules` list in
      `amaru-treasury-tx.cabal`.
- [X] T002 Add `aeson`, `file-embed`, `plutus-ledger-api`
      (or the equivalent ledger-side parameter-apply +
      script-hash module) to the library `build-depends`.
- [X] T003 Add `assets/plutus/*.cbor` to
      `extra-source-files`.
- [X] T004 [P] Lift the four Plutus blobs (`scopes`,
      `treasury_registry`, `permissions`, treasury) from a
      pinned upstream
      [`plutus.json`](https://github.com/pragma-org/amaru-treasury/blob/main/plutus.json)
      into `assets/plutus/*.cbor`.
      Record the upstream commit SHA in
      `assets/plutus/README.md`.
- [X] T005 [P] Add `test/unit/Amaru/Treasury/Registry/{Derive,
      Metadata, Verify}Spec.hs` to the test-suite stanza
      `other-modules`. Make sure `hspec-discover` picks them
      up.
- [X] T006 [P] Lift a known-good `metadata.json` into
      `test/fixtures/registry-walk/metadata.json`. Record
      the source commit in
      `test/fixtures/registry-walk/README.md`.
- [X] T007 Confirm `just ci` recipe still chains
      `build → unit → golden → format-check → hlint`; no
      recipe edit expected.

**Checkpoint**: package compiles with empty module skeletons;
fixtures + Plutus blobs present; tests discover the new
specs.

---

## Phase 2: Foundational (blocking prerequisites)

**Purpose**: Pure data + recomputation primitives.

- [X] T008 Implement `Amaru.Treasury.Registry.Constants`:
      `scopesSeedTxIdHex`, `scopesSeedIx`,
      `registrySeedTxIdHex`, `registrySeedIx`,
      `scopesTokenName`, `registryTokenName`,
      `treasuryExpirationMs`, `payoutUpperbound`, plus the
      four Plutus-blob `ByteString` constants embedded via
      `Data.FileEmbed.embedFile` over
      `assets/plutus/*.cbor`. Per
      [data-model.md §1](./data-model.md).
- [X] T009 Implement `Amaru.Treasury.Registry.Derive`:
      `applyParams :: ByteString -> [Data] -> Either String
      ByteString` and
      `scriptHashOfBlob :: ByteString -> ScriptHash` using
      the chosen plutus library. Wrap in two task-flavoured
      helpers:
      `derivedScopesNftPolicy :: ScriptHash`
      and
      `derivedRegistryNftPolicy :: ScopeId -> ScriptHash`,
      and
      `derivedPermissionsScriptHash :: ScopeId -> ScriptHash`.
- [X] T010 [P] Implement
      `Amaru.Treasury.Registry.Metadata`:
      `UpstreamMetadata`, `TreasuryEntry`, `ScriptDeployment`,
      `TxInRef`, FromJSON instances, plus local file reading.
      Per
      [data-model.md §2, §6](./data-model.md).

**Checkpoint**: types compile; parameterised script hashes can
be computed against the embedded blobs without IO.

---

## Phase 3: User Story 1 — anchor verification (Priority: P1) 🎯 MVP

**Goal**: `verifyRegistry` rejects every kind of metadata
tampering and staleness.

**Independent test**: Mutation-table fixture: for each
verifiable field, flip one byte in metadata or in the chain
stub; assert the matching `AnchorMismatch` /
`AnchorSpent` / `AnchorAmbiguous` constructor.

**Test-first ordering** (Constitution V): fixtures + spec +
golden authored *before* the verifier; spec must run RED once
before implementation lands.

- [X] T011 [P] [US1] Author
      `test/fixtures/registry-walk/anchors.json` — a
      hand-crafted record of "what the chain says": Scopes
      NFT datum, four per-scope `ScriptHashRegistry` datums,
      reference-script TxOuts. Mirrors what a real chain
      query would return for the corresponding metadata.
- [X] T012 [US1] Author
      `test/unit/Amaru/Treasury/Registry/VerifySpec.hs` with
      the happy-path `it` block plus the mutation-table.
      Each `it` block:
      - constructs a tweaked copy of the metadata fixture,
      - constructs a `Provider IO` stub returning the
        anchors fixture (sometimes tweaked),
      - asserts the expected typed error.
      Mutation entries: `owner`, `treasury_script.hash`,
      `registry_script.hash`, `permissions_script.hash`,
      `address`, each `*.deployed_at` (twice — spent vs
      wrong-ref-script), and the ambiguous-NFT case.
- [X] T013 [US1] Confirm RED: run
      `cabal test unit-tests -O0
      --test-options='--match=Verify'`; observe the spec
      failing.
- [X] T014 [US1] Implement `Amaru.Treasury.Registry.Verify`:
      `VerifiedRegistry`, `VerifiedScope`,
      `RegistryWalkError` and the
      `verifyRegistry` entry point per
      [data-model.md §3, §4, §5](./data-model.md).
      Use one acquired Provider session with at most two
      LSQ-backed queries (FR-011).
- [X] T015 [US1] Confirm GREEN: re-run the test command from
      T013; the happy path and every mutation case pass.
- [X] T016 [US1] Run `just ci`; the new spec must remain
      green end-to-end.

**Checkpoint (MVP)**: `verifyRegistry` correctly rejects every
documented tampering. SC-001, SC-002, SC-003 satisfied for the
fixture path.

---

## Phase 4: User Story 2 — local metadata file source (Priority: P1)

**Goal**: The wizard reads metadata from an operator-supplied
local file and treats the file as an untrusted hint.

**Independent test**: Drive `verifyRegistry` with the local
fixture and assert the verified projection.

- [X] T017 [US2] Implement
      `readUpstreamMetadataFile :: FilePath -> IO (Either
      RegistryWalkError UpstreamMetadata)` in
      `Amaru.Treasury.Registry.Metadata`. Surface
      `MetadataReadError` for unreadable files and
      `MetadataParse` for invalid JSON.
- [X] T018 [P] [US2] Add
      `test/unit/Amaru/Treasury/Registry/MetadataSpec.hs`
      cases for fixture parsing and unreadable/invalid local
      files.
- [ ] T019 [US2] Wire PR #28's rebase to accept only
      `--metadata <path>`; no URL/default source in this PR.

**Checkpoint**: local metadata loading works and safety remains
entirely in the verifier.

---

## Phase 5: User Story 3 — auditable build-time pin (Priority: P2)

**Goal**: The seeds + Plutus blobs in our binary are pinned
and reviewable.

- [X] T020 [US3] Add a unit test
      `test/unit/Amaru/Treasury/Registry/ConstantsSpec.hs`
      that asserts:
      - `scopesSeedTxIdHex` and `registrySeedTxIdHex` are
        64-char hex,
      - `derivedScopesNftPolicy` matches a checked-in
        expected `ScriptHash` (recorded in the fixture
        README at the same upstream commit as the blobs),
      - same for at least one scope's
        `derivedRegistryNftPolicy`.
- [X] T021 [US3] Document the pin advance procedure in
      `assets/plutus/README.md`: how to lift a new
      `plutus.json` from upstream, how to update the seeds,
      how to regenerate the expected-hash fixture used by
      T020.

**Checkpoint**: the binary's view of "what the contracts are"
is diff-reviewable and tested.

---

## Phase 6: Provider IO extension

**Purpose**: Add acquired Provider sessions upstream so the
verifier can query all registry addresses and reference inputs
against one acquired ledger snapshot.

- [X] T022 Open and merge a PR in
      `lambdasistemi/cardano-node-clients` adding Provider
      acquired sessions and `queryUTxOsAtH`.
      Implemented by
      [cardano-node-clients#128](https://github.com/lambdasistemi/cardano-node-clients/pull/128).
- [X] T023 Once T022 merges, bump the
      `cardano-node-clients` source-repository-package
      pin in this branch's
      `cabal.project` (and the `--sha256:` nix32 hash).
- [X] T024 Wire `verifyRegistry` to use `withAcquired`,
      `queryUTxOsAtH`, and `queryUTxOByTxInH`.

---

## Phase 7: Polish and cross-cutting concerns

- [X] T025 Run `just ci` (build + unit + golden +
      format-check + hlint) plus `cabal check`; resolve any
      new warnings.
- [X] T026 Update PR #31 description with the final command
      reference and link to
      [quickstart.md](./quickstart.md).
- [X] T027 Manual mainnet smoke test: invoke
      `verifyRegistry` from `cabal repl` against
      `/code/cardano-mainnet/ipc/node.socket`; assert
      `Right VerifiedRegistry` for `core_development` with
      a local metadata file. Recorded in the PR description.

**Checkpoint**: ready for merge.

---

## Dependencies

```
Setup (T001-T007)
    └── Foundational (T008-T010)
            └── Phase 3 [US1] anchor verification (T011-T016) ── MVP gate
                    ├── Phase 4 [US2] local file source (T017-T019)
                    └── Phase 5 [US3] pin auditing (T020-T021)
                            └── Phase 6 Provider extension (T022-T024)
                                    └── Phase 7 polish (T025-T027)
```

Phase 3 is the MVP. Phase 4 and Phase 5 can land on top in
either order. Phase 6 may stall on upstream review and is
isolated behind a fallback, so it does NOT block MVP merge.

## Parallel opportunities

Within Phase 1: T004, T005, T006 are independent; T001-T003
sequence first.

Within Phase 2: T010 ([P]) is in a different file from
T008/T009.

Within Phase 3: T011 ([P]) is fixture-only and runs alongside
T012 once Phase 2 compiles.

Within Phase 4: T018 ([P]) is test-only.

Within Phase 7: T025-T027 are sequential (T025 must pass
before T027's record).

## MVP scope

**MVP = Phase 1 + Phase 2 + Phase 3.** That alone gives the
safety property: the verifier rejects every documented
tampering or staleness. Phase 4 and 5 are ergonomics + audit
trail. Phase 6 is the acquired-session Provider integration,
not a separate safety property.
