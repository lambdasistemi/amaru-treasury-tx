# Tasks: vault-backed transaction witness command

**Input**: Design documents from `/specs/118-vault-witness/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md,
contracts/cli.md, quickstart.md

## Phase 1: Setup And Research Reset

- [x] T001 Replace the SOPS research decision with native age
  passphrase encryption in `specs/118-vault-witness/research.md`.
- [x] T002 Add `vault create` to the feature scope in
  `specs/118-vault-witness/spec.md`, `contracts/cli.md`, and
  `quickstart.md`.
- [x] T003 Remove SOPS from the runtime dependency story in `flake.nix`
  and Cabal metadata.

## Phase 2: Foundational RED Tests

- [x] T004 [P] Add RED age vault tests for encrypt/decrypt,
  wrong-passphrase failure, malformed-file failure, and redacted
  diagnostics in `test/unit/Amaru/Treasury/Vault/AgeSpec.hs`.
- [x] T005 [P] Add RED vault schema encoding tests for `vault create`
  round-tripping an imported signing-key envelope in
  `test/unit/Amaru/Treasury/Vault/WitnessSpec.hs`.
- [x] T006 [P] Add RED CLI parser tests for `vault create
  --signing-key-paste`, `--signing-key-stdin`,
  `--signing-key-file`, `--label`, `--description`, `--out`,
  `--vault-passphrase-fd`, `--vault-work-factor`, and `--force` in
  `test/unit/Amaru/Treasury/Cli/VaultSpec.hs`.
- [x] T007 [P] Update RED CLI parser tests for `witness --vault
  --vault-passphrase-fd --identity --expected-key-hash
  --allow-unlisted-key --out --force` in
  `test/unit/Amaru/Treasury/Cli/WitnessSpec.hs`.

## Phase 3: Age Vault Boundary

**Goal**: encrypt and decrypt age vault bytes in Haskell memory.

**Independent Test**: an encrypted fixture payload decrypts only with
the matching passphrase and wrong passphrases produce redacted errors.

- [x] T008 [US1] Implement `Amaru.Treasury.Vault.Age` with scrypt
  passphrase age encryption/decryption and stable redacted errors.
- [x] T009 [US1] Add shared passphrase intake helpers for no-echo
  `/dev/tty` prompts and inherited file descriptors in
  `Amaru.Treasury.Cli.Passphrase`.

## Phase 4: Vault Creation

**Goal**: create an encrypted vault without cleartext vault files.

**Independent Test**: `vault create` imports a fixture signing key,
writes an age file, and the decrypted payload resolves the expected
identity and key hash.

- [x] T010 [US1] Add schema encoding helpers for v1 witness vaults in
  `lib/Amaru/Treasury/Vault/Witness.hs`.
- [x] T011 [US1] Expose signing-key envelope validation/key-hash
  derivation for vault import in `lib/Amaru/Treasury/Tx/Witness.hs`.
- [x] T012 [US1] Implement `Amaru.Treasury.Cli.Vault` and register
  `vault create` in `lib/Amaru/Treasury/Cli.hs`,
  `app/amaru-treasury-tx/Main.hs`, and Cabal.
- [x] T013 [US1] Ensure `vault create` writes atomically and refuses to
  overwrite existing output without `--force`.

## Phase 5: Witness From Age Vault

**Goal**: produce one detached witness artifact from an age vault
identity.

**Independent Test**: fixture vault plus unsigned tx produces a witness
that decodes and attaches to the original transaction.

- [x] T014 [US2] Replace the SOPS boundary in
  `lib/Amaru/Treasury/Cli/Witness.hs` with native age decryption using
  the shared passphrase intake.
- [x] T015 [US2] Preserve transaction fact extraction, selected-key
  validation, and imported `cardano-cli-skey` signing behavior.
- [x] T016 [US2] Ensure witness output is raw CBOR hex and decodes
  through existing `decodeVKeyWitnessHex`.

## Phase 6: Failure Semantics

**Goal**: fail before writing output and never leak secrets.

**Independent Test**: wrong key/network/passphrase/vault fixtures fail
with stable diagnostics and no output file.

- [x] T017 [P] [US3] Add or update wrong-key, wrong-network,
  unsupported-era, no-required-signers, and wrong-passphrase tests.
- [x] T018 [US3] Ensure diagnostics do not contain passphrases,
  signing-key CBOR, decrypted vault JSON, or seed text.
- [x] T019 [US3] Ensure output files are created atomically only after
  validation and signing succeeds.

## Phase 7: Docs, Smoke, And Gates

- [x] T020 [P] [US5] Update fixture-source notes to describe the new
  encrypted-vault lifecycle.
- [x] T021 [US5] Rewrite `scripts/smoke/vault-witness` around
  `vault create` plus `witness`, removing the fake SOPS shim.
- [x] T022 [US5] Update PR metadata to remove SOPS and describe the age
  vault lifecycle.
- [x] T023 Run `nix develop --quiet -c just format`.
- [x] T024 Run focused witness/vault/CLI unit tests.
- [x] T025 Run `nix develop --quiet -c just ci`.
- [x] T026 Run `bash specs/118-vault-witness/gate.sh`.

## Dependencies

- T001-T003 block implementation.
- T004-T007 provide the RED tests before production code.
- T008-T009 block vault creation and witness decryption.
- T010-T013 block the full vault lifecycle smoke.
- T014-T019 block final docs and PR metadata.

## Implementation Strategy

1. Land the spec/research correction first.
2. Add RED tests around the new age and vault-create behavior.
3. Implement the age boundary and passphrase intake.
4. Implement `vault create`, then update `witness` to consume the age
   vault.
5. Refresh smoke/docs and run the full local gate before pushing.
