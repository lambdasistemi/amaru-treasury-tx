# Data Model: vault-backed transaction witness command

## SigningKeyEnvelope

Cardano payment signing-key JSON imported by `vault create`.

Fields:

- `type`: must be `PaymentSigningKeyShelley_ed25519`
- `description`: optional Cardano CLI description
- `cborHex`: CBOR-encoded Ed25519 signing key payload

Validation rules:

- the signing key must decode as an Ed25519 payment signing key.
- the derived verification-key hash becomes vault metadata.
- human operators paste the envelope with hidden input; automation
  streams it from a non-terminal secret source. File import is retained
  only for compatibility/testing, and `witness` does not accept a
  plaintext signing-key file.

## VaultPassphrase

Secret passphrase used for age scrypt encryption/decryption.

Sources:

- no-echo `/dev/tty` prompt for humans
- inherited file descriptor for automation

Validation rules:

- passphrases must not be accepted as argv values.
- `vault create` prompts twice when using `/dev/tty`.
- diagnostics must never include the passphrase.

## Vault

Binary age-encrypted file on disk. Decrypting it in memory yields the
versioned cleartext JSON payload:

- `amaruTreasuryWitnessVault.version`: integer, initially `1`
- `amaruTreasuryWitnessVault.createdBy`: optional text
- `amaruTreasuryWitnessVault.identities`: map from stable label to
  `VaultIdentity`

Validation rules:

- age decryption must happen in process memory.
- decrypted cleartext must not be written to disk by `vault create` or
  `witness`.
- `version` must be supported.
- identity labels must be unique and must match the map key.
- identity key hashes must be unique unless the metadata is identical.
- secret-bearing fields must never be rendered in diagnostics.

## VaultIdentity

Represents one selectable signer.

Fields:

- `label`: stable operator-facing selector, for example
  `core_development`
- `network`: `mainnet`, `preprod`, `preview`, or `testnet:<magic>`
- `keyHash`: 28-byte payment key hash as lowercase hex
- `description`: optional non-secret operator note
- `source`: one `SigningSource`

Validation rules:

- `keyHash` must be lowercase hex and exactly 28 bytes.
- `network` must match the command/network context when present.
- `source` must be a supported v1 source kind.

## SigningSource

Describes how signing material is loaded after vault decryption.

Variants:

- `cardano-cli-skey`
  - `keyEnvelope`: Cardano signing-key JSON envelope stored inside the
    encrypted vault payload
- `cip1852-derived` (future extension; not accepted by v1 code)
  - `root`: encrypted root/account secret material
  - `path`: derivation path, for example
    `m/1852'/1815'/0'/0/0`
  - `kind`: payment key for v1

Validation rules:

- imported signing keys must derive to `VaultIdentity.keyHash`.
- derived keys, once implemented, must use supported Cardano derivation
  rules and derive to `VaultIdentity.keyHash`.
- unsupported source kinds fail before signing.

## VaultCreateRequest

Operator request to create one encrypted vault.

Fields:

- `signingKeyInput`: Cardano signing-key envelope source used for import
  (`paste`, non-terminal `stdin`, or compatibility/testing `file`)
- `label`: vault identity label
- `network`: command network selection
- `description`: optional non-secret note
- `passphraseInput`: prompt or file descriptor
- `workFactor`: age scrypt work factor, supported range 1-18
- `output`: encrypted vault output path
- `force`: whether an existing output path may be overwritten

Validation rules:

- output file must not exist unless `force` is true.
- exactly one signing-key input source must be selected.
- `stdin` signing-key input must not be terminal stdin; humans use the
  hidden paste mode instead.
- passphrase source must produce a non-empty passphrase.
- signing key hash is derived from the imported key, not supplied by the
  user.

## SigningRequest

Operator request to create one witness.

Fields:

- `txInput`: stdin or file path
- `vaultPath`: encrypted age vault path
- `passphraseInput`: prompt or file descriptor
- `identitySelector`: label or key hash
- `network`: command network selection
- `expectedKeyHash`: optional explicit key hash assertion
- `allowUnlistedKey`: explicit acknowledgement for transactions without
  declared required signer hashes
- `output`: stdout or file path
- `force`: whether an existing output path may be overwritten

Validation rules:

- `identitySelector` resolves to exactly one vault identity.
- output file must not exist unless `force` is true.
- `expectedKeyHash`, when supplied, must match the selected identity.

## TransactionSigningFacts

Facts extracted from the unsigned transaction before signing.

Fields:

- `era`: must be Conway
- `bodyHash`: transaction body hash that will be signed
- `requiredSignerHashes`: zero or more 28-byte key hashes
- `network`: optional network inferred from body addresses when
  available

Validation rules:

- non-Conway eras fail.
- if `requiredSignerHashes` is non-empty, selected key hash must be a
  member.
- if `requiredSignerHashes` is empty, require `expectedKeyHash` or
  `allowUnlistedKey`.

## WitnessArtifact

Detached witness output.

Fields:

- `kind`: vkey witness
- `keyHash`: selected identity key hash
- `bodyHash`: signed transaction body hash
- `cborHex`: raw detached witness CBOR hex

Validation rules:

- `cborHex` decodes through the existing witness decoder.
- attaching the witness must not modify the original transaction body.
