# Research: vault-backed transaction witness command

## Decision: use native age passphrase encryption for vault files

Use the age v1 file format with an scrypt passphrase recipient as the
first vault backend. `amaru-treasury-tx` encrypts vault cleartext during
`vault create` and decrypts vault ciphertext during `witness` with the
Haskell `age` package, keeping decrypted bytes in process memory only.
The runtime path does not invoke SOPS, the `age` CLI, or another
external decryption program.

**Rationale**:

- age is an established encrypted-file format with a small, auditable
  design and a passphrase mode that fits the desired operator ceremony.
- The user requirement is to store the private signing key encrypted on
  disk once, pass a decryption passphrase safely to the computer, unlock
  in memory, sign, and avoid cleartext vault files on disk.
- A native Haskell boundary makes the no-cleartext-on-disk rule
  enforceable by this CLI instead of depending on shell practices around
  SOPS temporary files or editor integrations.
- The pinned Hackage index contains `age-0.0.1.0`, which exposes
  buffered scrypt encryption and decryption APIs.

**Risks**:

- The Haskell `age` package is marked experimental and warns that its
  API may change. The implementation should isolate it behind a small
  vault encryption module and keep fixture coverage around encrypt,
  decrypt, wrong-passphrase, and malformed-file behavior.
- The first implementation uses binary age files produced by this CLI.
  ASCII-armored age files and X25519 recipient identity files can be
  added later without changing the cleartext vault schema.

**Alternatives considered**:

- SOPS JSON: rejected for v1 because it would make `witness` depend on
  an external decryptor and made the passphrase/in-memory ceremony too
  indirect for this ticket.
- Raw plaintext Cardano `*.skey`: compatible but fails the issue's
  critical requirement because plaintext signing keys remain the
  default operator path.
- age X25519 identity files: useful for multi-recipient and unattended
  operations, but it introduces another private key file. The confirmed
  v1 custody model is passphrase-first.
- Project-owned crypto container: rejected because adopting age gives a
  reviewed file format and KDF/encryption construction.
- Cardano wallet database formats: implementation-specific and not a
  stable interchange format for this CLI.

References:

- age file-format background: https://age-encryption.org/v1
- Haskell package: https://hackage.haskell.org/package/age

## Decision: add `vault create` as the supported vault creation ceremony

Add a CLI command that imports one Cardano payment signing-key envelope,
derives its key hash, wraps it in the v1 vault cleartext schema, and
writes an age-encrypted vault file. The command prompts for a passphrase
twice on `/dev/tty` by default and accepts a passphrase file descriptor
for automation.

**Rationale**:

- Operators should not need to hand-author vault JSON or run a separate
  encryption tool correctly to satisfy this issue.
- Deriving the key hash during import prevents stale or mismatched
  metadata from becoming trusted vault content.
- Reading passphrases from a no-echo terminal or inherited file
  descriptor avoids argv, shell history, and process-list exposure.
- Keeping creation and signing as separate commands makes the lifecycle
  explicit: import once, then sign many transactions.

**Alternatives considered**:

- Document a manual JSON-plus-age workflow only. Rejected because the
  user would still have to manage cleartext intermediate files safely.
- Let `witness` create a vault implicitly when no vault exists. Rejected
  because signing should not perform hidden key import or vault
  mutation.
- Accept `--passphrase TEXT`. Rejected because argv is a common leak
  path.

## Decision: cleartext vault schema is project-owned and versioned

The decrypted vault payload uses a top-level
`amaruTreasuryWitnessVault` object with `version: 1` and an
`identities` map. Each identity includes non-secret metadata (`label`,
`network`, `keyHash`, optional `description`) and one signing source.

Supported source kinds for the first v1 implementation:

- `cardano-cli-skey`: a Cardano payment signing-key JSON envelope
  imported by `vault create`.

Deferred source kinds:

- `cip1852-derived`: a root or account secret plus a CIP-1852
  derivation path. This remains a planned extension rather than part of
  the first implementation because the repository does not yet carry a
  reviewed HD derivation dependency or ceremony.

**Rationale**:

- A project-owned schema lets the CLI produce precise diagnostics and
  validate labels, network metadata, and key hashes before signing.
- Supporting imported `cardano-cli` keys gives operators a short
  migration path away from plaintext `*.skey` files.
- Human imports should use hidden paste input rather than a plaintext
  file path; automated imports should stream the signing-key JSON from a
  secret manager or fixture through non-terminal stdin.
- Documenting CIP-1852-derived entries as a future extension aligns the
  long-term format with Cardano wallet derivation standards without
  inventing or shipping an unreviewed treasury derivation convention in
  the first PR.

**Alternatives considered**:

- Encrypt arbitrary user JSON and discover keys by convention. Rejected
  because diagnostics and migration would be weak.
- Ship CIP-1852 derivation immediately. Deferred because the initial
  value comes from removing loose plaintext `*.skey` files from the
  operator path, while HD derivation needs a separate dependency and
  ceremony review.

References:

- CIP-1852: https://cips.cardano.org/cip/CIP-1852
- CIP-3: https://cips.cardano.org/cip/CIP-3

## Decision: default artifact remains raw witness CBOR hex

The native `witness` output is raw detached vkey witness CBOR hex
because `attach-witness` already consumes that shape. Operators who need
`cardano-cli` witness JSON can pipe through the existing
`envelope-witness` command.

**Rationale**:

- Keeps `witness` aligned with the existing raw-hex pipeline.
- Avoids duplicating envelope output flags in every signing command.
- Preserves byte-level tests around `decodeVKeyWitnessHex` and
  `attach-witness`.

**Alternatives considered**:

- Make `witness` write cardano-cli envelopes by default. Rejected
  because this would make the local pipeline less direct and duplicate
  the envelope feature.

## Decision: validation fails closed unless the transaction proves or the user declares the key

When the transaction body contains required signer hashes, the selected
vault identity hash must be present. When it does not, the command
requires either `--expected-key-hash HASH` or `--allow-unlisted-key`.

**Rationale**:

- A Cardano transaction input alone does not necessarily reveal the
  payment key hash that can spend it. Without ledger context, a generic
  offline witness command cannot prove every wrong-key case.
- Required signer hashes are explicit and can be validated.
- Requiring an explicit acknowledgement for unlisted-key signing makes
  the limitation visible instead of pretending the command can infer
  more than the transaction body contains.

**Alternatives considered**:

- Always sign even if no required signer hash exists. Rejected because
  it makes wrong-key ceremonies easy.
- Require live UTxO lookup for every transaction input. Rejected because
  the feature is intended to work for arbitrary unsigned transactions
  and offline signing workflows.
