# Feature Specification: vault-backed transaction witness command

**Feature Branch**: `118-vault-witness`
**Created**: 2026-05-15
**Status**: Scope reset for PR review
**Issue**: [#128](https://github.com/lambdasistemi/amaru-treasury-tx/issues/128)
**Input**: "Add vault-backed transaction witness command"

## Background

`amaru-treasury-tx` already builds unsigned Conway transactions and can
merge detached witnesses with `attach-witness`. Operators still need a
signing step that normally exposes a plaintext `*.skey` file. This
feature adds two explicit ceremonies:

- create an encrypted local witness vault from imported Cardano
  signing-key material
- unlock that vault in memory to create one detached transaction witness

The command boundaries must stay clear. `tx-build` builds only,
`vault create` creates or replaces an encrypted vault file, `witness`
signs only, `attach-witness` assembles witnesses only, and `submit`
submits only.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Create An Encrypted Signing Vault (Priority: P1)

An operator has Cardano payment signing-key material and wants to store
it once in an encrypted vault, then stop passing that plaintext key
material to signing commands.

**Why this priority**: A witness command is not safe enough if users
must hand-build the encrypted vault or keep using loose plaintext keys.

**Independent Test**: Stream fixture signing-key material into
`amaru-treasury-tx --network preprod vault create --signing-key-stdin
--label core_development --out treasury.vault.age` using a passphrase
supplied through a file descriptor. Separately run the interactive
pseudo-terminal smoke for `--signing-key-paste` and the no-echo
passphrase prompt. The command writes an age-encrypted vault, does not
write a cleartext vault beside it, and the vault can later be unlocked
by `witness`.

**Acceptance Scenarios**:

1. **Given** valid Cardano payment signing-key material, **When** the
   operator runs `vault create`, **Then** the command writes one
   encrypted vault file and exits with code 0.
2. **Given** signing-key material, **When** the command creates the
   vault, **Then** it derives and stores non-secret metadata including
   label, network, and payment key hash.
3. **Given** a human import ceremony, **When** the operator runs
   `vault create --signing-key-paste`, **Then** the signing-key
   material is read with terminal echo disabled.
4. **Given** no automation file descriptor, **When** a human creates a
   vault, **Then** the passphrase is read from a no-echo terminal prompt
   and confirmation is required.
5. **Given** automation, **When** the caller passes a passphrase file
   descriptor, **Then** the passphrase is read from that descriptor and
   is never accepted as an argv value.

---

### User Story 2 - Create A Detached Witness From A Vault (Priority: P1)

An operator has an unsigned Conway transaction from `tx-build` or
another tool and needs one detached witness from a configured encrypted
vault identity, without passing a plaintext signing key file on the
command line.

**Why this priority**: This closes the current gap between `tx-build`
and `attach-witness` while avoiding the plaintext-key default.

**Independent Test**: Create a fixture vault, then run
`amaru-treasury-tx witness --tx unsigned.cbor.hex --vault
treasury.vault.age --identity core_development --out
core_development.witness` with the vault passphrase supplied through a
file descriptor. The witness decodes as a vkey witness and can be
attached with `attach-witness`.

**Acceptance Scenarios**:

1. **Given** a valid unsigned Conway transaction and a vault containing
   the selected signing identity, **When** the operator runs `witness`,
   **Then** the command writes exactly one detached witness artifact and
   exits with code 0.
2. **Given** the witness produced by the command, **When** the operator
   runs `attach-witness --witness "$(cat witness.hex)"`, **Then** the
   assembled transaction preserves the original transaction body and
   contains the new vkey witness.
3. **Given** a transaction built outside `amaru-treasury-tx` but encoded
   as a Conway unsigned transaction body or transaction envelope,
   **When** the operator signs it with a matching vault identity,
   **Then** the witness artifact is usable by the normal Cardano
   witness assembly flow.

---

### User Story 3 - Fail Clearly For The Wrong Identity Or Network (Priority: P1)

An operator accidentally chooses a vault identity that does not match
the transaction's required signer set, declared network, or supported
era. The command must fail before writing a misleading witness artifact.

**Why this priority**: Signing with the wrong key is operationally
dangerous because it can look like a successful ceremony until assembly
or submission fails later.

**Independent Test**: Run `witness` with a fixture transaction whose
required signer hash does not include the selected identity. The command
exits non-zero, writes nothing to the requested output path, and stderr
names the selected key hash and the required signer hashes.

**Acceptance Scenarios**:

1. **Given** a transaction with `required_signers` and a selected vault
   identity whose key hash is absent, **When** the operator runs
   `witness`, **Then** the command exits with code 1 and explains that
   the selected key cannot satisfy the transaction's required signer
   set.
2. **Given** a mainnet-only vault identity and a testnet transaction, or
   the reverse, **When** the operator runs `witness`, **Then** the
   command exits with code 1 and names the network mismatch.
3. **Given** a non-Conway or malformed transaction input, **When** the
   operator runs `witness`, **Then** the command exits with code 1 and
   names the unsupported era or decode failure.

---

### User Story 4 - Diagnose Vault Problems Without Leaking Secrets (Priority: P1)

An operator uses the wrong vault passphrase, a malformed vault file, or
a vault that does not contain the requested identity. The command must
explain the problem without printing decrypted key material.

**Why this priority**: Vault-backed signing is only safer if failure
paths do not train users to copy secrets into logs or ad hoc files.

**Independent Test**: Use malformed, undecryptable, and
missing-identity fixture vaults. Each failure exits non-zero, writes no
witness, and stderr contains the vault path plus a typed reason but no
signing key payload.

**Acceptance Scenarios**:

1. **Given** an encrypted vault that cannot be decrypted with the
   supplied passphrase, **When** the operator runs `witness`, **Then**
   the command fails and reports a vault decryption failure without
   dumping decrypted bytes.
2. **Given** a decrypted vault whose schema version is unsupported,
   **When** the operator runs `witness`, **Then** the command fails and
   names the unsupported vault version.
3. **Given** a valid vault that lacks the requested identity, **When**
   the operator runs `witness`, **Then** the command fails and lists the
   available non-secret identity labels.

---

### User Story 5 - Understand And Reproduce The Vault Workflow (Priority: P2)

An operator or reviewer needs documentation that explains vault
creation, passphrase intake, signing, witness assembly, and the
relationship with `cardano-cli` without requiring source-code
archaeology.

**Why this priority**: A signing command handles sensitive operational
material; the UX must be documented before mainnet use.

**Independent Test**: Follow the documented fixture workflow from
`vault create` through `witness`, `attach-witness`, and optional
envelope conversion on a clean checkout.

**Acceptance Scenarios**:

1. **Given** the quickstart documentation, **When** a reviewer follows
   the commands against checked-in fixtures, **Then** they can create a
   vault, produce a witness, attach it, and inspect the resulting signed
   transaction.
2. **Given** CLI help output, **When** an operator runs
   `amaru-treasury-tx vault create --help` and `amaru-treasury-tx
   witness --help`, **Then** the help names the vault path, identity,
   transaction input, passphrase descriptor, output, and overwrite
   policy options. Network selection remains part of the global CLI
   options.

### Edge Cases

- Vault creation must not leave a cleartext vault or copied signing-key
  file on disk.
- Passphrases must never be accepted as command-line arguments, printed
  in diagnostics, or echoed by the interactive prompt.
- Transaction input may be raw CBOR hex or a `cardano-cli` Conway tx
  JSON envelope. Envelope handling must compose with existing
  `de-envelope` / `envelope-witness` filters.
- A transaction with no required signer hashes cannot prove wrong-key
  selection from the body alone. The command must either require an
  explicit expected key hash or an explicit `--allow-unlisted-key`
  acknowledgement before signing.
- Duplicate identities in a vault are invalid if they share a label or
  key hash with different metadata.
- Output paths are not overwritten unless the user passes an explicit
  force flag.
- On every failure path, the command writes no partial witness artifact
  or partial vault artifact.
- Vault cleartext, passphrases, signing keys, and seed phrases must
  never be printed to stdout/stderr.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST add a standalone `vault create` command
  that imports one Cardano payment signing-key material item into an
  encrypted local witness vault.
- **FR-002**: `vault create` MUST encrypt the vault with an established
  age passphrase file format and MUST NOT persist a cleartext vault
  file.
- **FR-003**: `vault create` MUST read passphrases from a no-echo
  terminal prompt by default and from a file descriptor for automation.
  It MUST NOT accept passphrases as argv values.
- **FR-003a**: `vault create` MUST support hidden pasted signing-key
  material for human import ceremonies and non-terminal stdin for
  automated secret streams. It MUST accept both `cardano-cli` `.skey`
  JSON envelopes and `cardano-addresses` `addr_xsk` address extended
  signing keys. It MUST reject terminal stdin for signing-key material
  to avoid echoing pasted key material. The compatibility file input
  MUST remain outside the recommended operator path.
- **FR-004**: `vault create` MUST derive the imported signing key's
  payment key hash and store that key hash as non-secret vault metadata.
- **FR-005**: The system MUST add a standalone `witness` command that
  reads an unsigned Conway transaction and writes one detached vkey
  witness artifact.
- **FR-006**: `witness` MUST be independent from `tx-build`;
  transaction construction MUST NOT implicitly create signatures or
  witnesses.
- **FR-007**: `witness` MUST accept arbitrary unsigned Conway
  transactions, not only transactions built from treasury intents.
- **FR-008**: `witness` MUST select a signing identity by a stable vault
  label or key hash.
- **FR-009**: `witness` MUST decrypt the age vault in process memory and
  MUST NOT invoke SOPS, `age`, or another external decryption program in
  the primary runtime path.
- **FR-010**: The vault format MUST be documented before
  implementation, including encryption backend, cleartext schema,
  identity selectors, passphrase handling, and migration/versioning
  rules.
- **FR-011**: The command MUST validate that the input transaction is
  Conway-era and report unsupported eras clearly.
- **FR-012**: The command MUST validate network compatibility between
  the transaction, command-line network selection, and selected vault
  identity metadata when that information is present.
- **FR-013**: If a transaction declares required signer key hashes, the
  command MUST fail when the selected identity key hash is not included.
- **FR-014**: If a transaction does not declare required signer hashes,
  the command MUST require either `--expected-key-hash` or
  `--allow-unlisted-key` before signing.
- **FR-015**: The command MUST emit diagnostics for wrong key,
  malformed transaction, unsupported vault version, decryption failure,
  missing identity, malformed key material, and passphrase input
  failure.
- **FR-016**: `witness` MUST support a pipe-friendly default contract:
  transaction input defaults to stdin and witness output defaults to
  stdout, with file flags available for both.
- **FR-017**: The produced witness MUST round-trip through the existing
  `decodeVKeyWitnessHex` / `attach-witness` path.
- **FR-018**: The implementation MUST include tests for successful vault
  creation, successful witness creation, wrong-key failure, malformed or
  unsupported vault failure, wrong-passphrase failure, and witness
  assembly into a complete signed transaction fixture.
- **FR-019**: CLI help and user-facing docs MUST show how to create a
  vault, create a witness for an existing unsigned transaction, and
  attach or envelope that witness afterward.

### Key Entities

- **Signing Key Material**: A Cardano payment signing key imported once
  by `vault create`, either as a `cardano-cli` `.skey` JSON envelope or
  as a `cardano-addresses` `addr_xsk` address extended signing key.
- **Vault**: An age-encrypted local file containing non-secret identity
  metadata plus encrypted signing material.
- **Vault Identity**: A named signing identity with key hash, network
  scope, source kind, and signing material.
- **Passphrase Input**: A no-echo terminal prompt or inherited file
  descriptor that supplies the age passphrase without argv exposure.
- **Unsigned Transaction**: A Conway transaction body or transaction
  envelope that must remain byte-stable while one or more detached
  witnesses are produced.
- **Witness Artifact**: A detached vkey witness in raw CBOR hex by
  default, optionally wrapped by the existing `envelope-witness` flow.
- **Signing Request**: The operator's selected transaction, network,
  vault, identity, output path, and validation policy.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A checked-in fixture workflow can create an encrypted age
  vault from signing-key material and later produce a detached witness
  from that vault with no plaintext signing-key file passed to
  `witness`.
- **SC-002**: Wrong-key, wrong-network, wrong-passphrase,
  unsupported-era, malformed-vault, and missing-identity tests all fail
  before output creation and include one-line operator diagnostics.
- **SC-003**: The command signs a non-treasury Conway fixture as long as
  the selected key is accepted by the validation policy.
- **SC-004**: `vault create --help`, `witness --help`, and docs contain
  a complete command sequence from signing-key import to vault to
  witness to assembled transaction.
- **SC-005**: Existing `tx-build`, `attach-witness`, envelope, and
  submit behavior remains unchanged on their existing tests.

## Assumptions

- Operators can paste or stream an initial Cardano payment signing-key
  envelope during vault creation, then clear the clipboard/source buffer
  under their custody policy.
- The signing host is controlled by the operator. Vault encryption
  reduces accidental plaintext-key exposure; it does not replace
  air-gap, hardware-wallet, or custody policies.
- The first implementation targets one imported payment/key witness in
  Conway era. Script witnesses, bootstrap witnesses, Byron-era
  transactions, CIP-1852 derivation from HD secrets, vault editing, and
  multi-party signing coordination are out of scope.
- Raw witness hex remains the native pipeline artifact because
  `attach-witness` already consumes that shape. Operators can wrap it
  with `envelope-witness` for `cardano-cli` interop.

## Out Of Scope

- Changing `tx-build` to sign transactions.
- Submitting transactions from the `witness` command.
- Managing cloud KMS/HSM policies directly.
- Hardware-wallet interactive signing.
- Persisting decrypted vault contents or generated plaintext signing
  keys outside process memory.
