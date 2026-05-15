# CLI Contract: vault lifecycle and witness creation

## Command: `vault create`

```text
amaru-treasury-tx [GLOBAL_OPTS] vault create [OPTIONS]
```

### Options

```text
--signing-key-paste
    Prompt for pasted Cardano payment signing-key material with terminal
    echo disabled. Accepts either a cardano-cli .skey JSON envelope or
    a cardano-addresses addr_xsk address extended signing key.
    Recommended for human import ceremonies.

--signing-key-stdin
    Read Cardano payment signing-key material from stdin. Intended for
    non-terminal streams from secret managers or fixtures; terminal
    stdin is rejected to avoid echoing pasted key material.

--signing-key-file PATH
    Read Cardano payment signing-key material from a file.
    Compatibility/testing path, not the recommended custody ceremony;
    normal operator documentation uses paste or non-terminal stdin.

--label LABEL
    Stable vault identity label. Required.

--description TEXT
    Optional non-secret operator note.

--out PATH, -o PATH
    Encrypted age vault output path. Required.

--vault-passphrase-fd FD
    Read one passphrase line from an inherited file descriptor. Intended
    for automation. If omitted, prompt on /dev/tty with echo disabled and
    require confirmation.

--vault-work-factor INT
    age scrypt work factor. Supported range is 1-18; default is 18.
    Tests may use a lower value for speed.

--force
    Permit replacing an existing vault path.
```

Exactly one signing-key input option is required. The global network
option supplies the vault identity network metadata. The command derives
the imported key hash from the signing key material.

### Input

All signing-key input modes accept either a Cardano payment signing-key
JSON envelope:

```json
{
  "type": "PaymentSigningKeyShelley_ed25519",
  "description": "Payment Signing Key",
  "cborHex": "..."
}
```

or one `cardano-addresses` address extended signing key line:

```text
addr_xsk1...
```

### Output

Success writes a binary age-encrypted vault file. It does not write the
cleartext vault JSON to stdout or to a sidecar file.

The decrypted v1 cleartext schema is:

```json
{
  "amaruTreasuryWitnessVault": {
    "version": 1,
    "identities": {
      "core_development": {
        "label": "core_development",
        "network": "mainnet",
        "keyHash": "00000000000000000000000000000000000000000000000000000000",
        "description": "optional non-secret note",
        "source": {
          "kind": "cardano-cli-skey",
          "keyEnvelope": {
            "type": "PaymentSigningKeyShelley_ed25519",
            "description": "...",
            "cborHex": "..."
          }
        }
      }
    }
  }
}
```

An `addr_xsk` import stores the same identity fields, with this source:

```json
{
  "kind": "cardano-addresses-addr-xsk",
  "bech32": "addr_xsk1..."
}
```

## Command: `witness`

```text
amaru-treasury-tx [GLOBAL_OPTS] witness [OPTIONS]
```

### Options

```text
--tx PATH
    Path to unsigned Conway transaction CBOR hex or cardano-cli Conway
    transaction envelope. Defaults to stdin.

--vault PATH
    Path to the encrypted age witness vault. Required.

--vault-passphrase-fd FD
    Read one passphrase line from an inherited file descriptor. If
    omitted, prompt on /dev/tty with echo disabled.

--identity LABEL_OR_KEY_HASH
    Vault identity selector. Required.

--expected-key-hash HASH
    Assert that the selected identity has this key hash. Also authorizes
    signing transactions that do not declare required signer hashes.

--allow-unlisted-key
    Explicitly allow signing a transaction whose body does not declare
    required signer hashes. Mutually exclusive with relying on automatic
    signer-set validation.

--out PATH, -o PATH
    Output witness CBOR hex path. Defaults to stdout.

--force
    Permit replacing an existing output path.
```

Global network options keep their existing meaning. The command uses
the selected network to validate vault identity metadata and transaction
facts when those are available.

### Input

Transaction input accepts either:

- raw Conway transaction CBOR hex
- a `cardano-cli` JSON envelope whose `type` is Conway-compatible and
  whose `cborHex` contains the transaction bytes

Vault input is a binary age file created by `vault create`. `witness`
decrypts it in memory using the supplied passphrase and then parses the
v1 cleartext schema.

### Output

Success writes raw detached vkey witness CBOR hex and a trailing newline
when writing to stdout. File output writes raw hex bytes without a
trailing newline and without requiring a JSON envelope.

Operators that need a `cardano-cli` witness envelope use:

```bash
amaru-treasury-tx witness ... | amaru-treasury-tx envelope-witness
```

## Exit Codes

- `0`: vault created or witness created
- `1`: input, vault, validation, passphrase, or signing failure

## Error Diagnostics

Errors are one line on stderr, prefixed with the command name. They must
not include passphrases, decrypted vault payloads, signing-key CBOR, or
seed phrases.

Required error cases:

- malformed signing-key material
- passphrase prompt or descriptor failure
- passphrase confirmation mismatch
- age encryption or decryption failure
- malformed transaction
- unsupported transaction era
- transaction/network mismatch
- unsupported vault version
- missing identity
- malformed signing source
- selected key hash absent from required signer hashes
- transaction has no required signer hashes and no explicit
  unlisted-key authorization
- output exists without `--force`
