# Implementation Plan: vault-backed transaction witness command

**Branch**: `118-vault-witness` | **Date**: 2026-05-15 |
**Spec**: [spec.md](./spec.md)

## Status

**Completed**: issue #128 reviewed again after PR feedback; SOPS design
rejected; user confirmed passphrase-first age vaults decrypted in memory
and requested a supported vault creation command.
**Current**: replacing research/design/tasks and implementation with a
native age `vault create` + `witness` workflow.
**Blockers**: none known.

## Summary

Add a `vault create` command that imports one Cardano payment signing
key into an age-encrypted witness vault, and update `witness` so it
decrypts that vault in Haskell memory before producing one detached
Conway vkey witness. The runtime path does not use SOPS or an external
age executable. Passphrases are read from `/dev/tty` with echo disabled
or from an inherited file descriptor for automation.

## Technical Context

**Language/Version**: Haskell, current repo GHC via Nix dev shell.
**Primary Dependencies**: existing Cardano ledger Conway types,
`cardano-crypto-class` / ledger key types, existing envelope and
attach-witness modules, Haskell `age` package for age file
encryption/decryption, `unix` for POSIX terminal/file-descriptor
passphrase intake.
**Storage**: binary age-encrypted local vault plus fixture files.
**Testing**: Hspec unit tests, golden/oracle fixture tests, smoke
scripts for CLI pipe, vault lifecycle, and pseudo-terminal no-echo
behavior.
**Target Platform**: CLI on Linux and macOS.
**Project Type**: Single Haskell library plus CLI executable.
**Performance Goals**: one vault create or witness operation completes
in interactive CLI time; no long-running network lookup required.
**Constraints**: no implicit signing in builders; no plaintext key-file
default for vault import or witness; no decrypted vaults or passphrases
in logs; build commands remain unchanged; generic offline signing cannot
infer input-owner key hashes unless the transaction declares required
signers.
**Scale/Scope**: one imported payment signing key per `vault create`
invocation; one witness per `witness` invocation; Conway vkey witnesses
only for v1.

## Constitution Check

*GATE: Must pass before implementation and re-check after design.*

- **I. Faithful port of bash recipes.** Documented extension. The
  original constitution says signing is out of scope for builders. This
  feature adds separate vault and witness commands after the explicit
  issue request; `tx-build` remains unsigned-only.
- **II. Pure builders, impure shell.** Pass. Vault encryption,
  passphrase intake, and file I/O live in CLI/boundary code, while
  transaction/witness codecs remain pure library functions.
- **III. Pluggable data source, local-node default.** Pass. No live data
  source is required for v1.
- **IV. Build, never sign or submit.** Requires amendment-by-plan. The
  project now has an explicit signing subcommand, but transaction build
  commands still never sign or submit. Command names and docs keep this
  boundary clear.
- **V. Test-first with golden CBOR fixtures.** Pass. Tasks require RED
  tests for age vault encryption/decryption, vault creation, witness
  creation, wrong-key failure, vault failure, and attach round-trip
  before production code.
- **VI. Hackage-ready Haskell.** Pass. New modules need explicit export
  lists, Haddock, formatting, lint, and `cabal check` compatibility.

## Project Structure

### Documentation

```text
specs/118-vault-witness/
+-- spec.md
+-- plan.md
+-- research.md
+-- data-model.md
+-- quickstart.md
+-- contracts/
|   +-- cli.md
+-- checklists/
|   +-- requirements.md
+-- tasks.md
+-- gate.sh
```

### Source Code

```text
lib/Amaru/Treasury/
+-- Tx/Witness.hs              # pure tx facts, key validation, witness encoding
+-- Vault/Age.hs               # age encrypt/decrypt boundary
+-- Vault/Witness.hs           # decrypted vault schema and validation
+-- Cli/Passphrase.hs          # tty/fd passphrase intake
+-- Cli/Vault.hs               # vault create parser and runner
+-- Cli/Witness.hs             # witness parser and runner
+-- Cli.hs                     # command registration

app/amaru-treasury-tx/
+-- Main.hs                    # dispatch vault create and witness

test/unit/Amaru/Treasury/
+-- Vault/AgeSpec.hs
+-- Vault/WitnessSpec.hs
+-- Tx/WitnessSpec.hs
+-- Cli/VaultSpec.hs
+-- Cli/WitnessSpec.hs

test/fixtures/118-vault-witness/
+-- unsigned.cbor.hex
+-- signed.expected.cbor.hex
+-- vault.clear.json              # test-only decrypted payload
+-- vault.wrong-key.clear.json
+-- witness.expected.hex
```

## Phase 0: Research Output

See [research.md](./research.md). Key decisions:

- Native Haskell age passphrase encryption is the first encrypted vault
  backend.
- `vault create` is required so users do not hand-author cleartext vault
  files.
- The cleartext vault schema is project-owned and versioned.
- First implementation supports imported `cardano-cli-skey`;
  CIP-1852 derivation is documented as a future source kind.
- Raw detached witness CBOR hex remains the native artifact.
- Missing required signer hashes require explicit operator
  acknowledgement before signing.

## Phase 1: Design Output

See:

- [data-model.md](./data-model.md)
- [contracts/cli.md](./contracts/cli.md)
- [quickstart.md](./quickstart.md)

## Implementation Slices

### Slice 1 - Age vault boundary and passphrase intake

Add a small age encryption/decryption module plus shared passphrase
intake helpers. Tests prove encrypt/decrypt, wrong passphrase failure,
and no secret-bearing diagnostics.

### Slice 2 - Vault schema and `vault create`

Keep the v1 cleartext schema parser, add schema encoding for imported
signing keys, derive key hashes during import, and register `vault
create`.

### Slice 3 - Transaction facts and witness creation

Decode unsigned Conway transactions/envelopes, extract body hash,
required signer hashes, and network facts where possible, then create
one detached vkey witness from the selected vault identity.

### Slice 4 - CLI/docs/smoke

Update `witness` to unlock age vaults, add help/docs, fixture
quickstart, and smoke tests for the complete create -> witness ->
attach workflow.

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| Separate signing command despite "Build, never sign or submit" | Issue #128 explicitly asks for an in-tool witness command, and separating it from `tx-build` preserves the builder boundary. | Continuing to require external plaintext `*.skey` signing workflows leaves the issue unresolved. |
| Native crypto dependency | The confirmed custody model needs in-process age decrypt/encrypt with no decrypted file on disk. | SOPS or external `age` would push the core safety property into shell-level behavior. |
