# Quickstart: age vault creation and witness signing

This workflow imports a Cardano payment signing key into an encrypted
age vault, then uses that vault to sign an unsigned Conway transaction.
The decrypted vault exists only in process memory.

## 1. Build Or Obtain An Unsigned Transaction

`witness` accepts raw Conway transaction CBOR hex or a `cardano-cli`
Conway transaction envelope.

```bash
unsigned_tx=tx.body.cborHex
```

## 2. Create The Encrypted Vault

Humans use `--signing-key-paste` to paste the Cardano signing-key JSON
with terminal echo disabled, then omit `--vault-passphrase-fd` to enter
the vault passphrase at the no-echo terminal prompt.

`vault create` is the import ceremony. The pasted signing-key JSON is
read once to create `treasury.vault.age`; normal signing uses the
encrypted vault plus the passphrase. After verifying and backing up the
encrypted vault, clear the clipboard or source buffer under the operator
custody policy.

Interactive ceremony:

```bash
amaru-treasury-tx --network preprod vault create \
  --signing-key-paste \
  --label core_development \
  --description "core development payment key" \
  --out treasury.vault.age

# Paste the full cardano-cli signing-key JSON when prompted.
# The pasted bytes are hidden; parsing stops once the JSON object closes.
```

Automation can stream the signing key through stdin and the passphrase
through an inherited file descriptor:

```bash
exec 9<<<"correct horse battery staple"

secret-manager-read core-development-payment-skey \
| amaru-treasury-tx --network preprod vault create \
    --signing-key-stdin \
    --label core_development \
    --description "core development payment key" \
    --out treasury.vault.age \
    --vault-passphrase-fd 9

exec 9<&-
```

`vault create` writes only `treasury.vault.age`. It does not create a
cleartext vault file.

## 3. Produce One Detached Witness

```bash
exec 9<<<"correct horse battery staple"

amaru-treasury-tx --network preprod witness \
  --tx "$unsigned_tx" \
  --vault treasury.vault.age \
  --vault-passphrase-fd 9 \
  --identity core_development \
  --out core_development.witness.hex

exec 9<&-
```

For pipe-oriented workflows, transaction input defaults to stdin and
witness output defaults to stdout:

```bash
exec 9<<<"correct horse battery staple"

amaru-treasury-tx --network preprod witness \
  --vault treasury.vault.age \
  --vault-passphrase-fd 9 \
  --identity core_development \
  < "$unsigned_tx" \
  > core_development.witness.hex

exec 9<&-
```

## 4. Assemble Witnesses

```bash
amaru-treasury-tx attach-witness \
  --tx "$unsigned_tx" \
  --witness "$(cat core_development.witness.hex)" \
  --out tx.signed.cborHex
```

For `cardano-cli` interop:

```bash
amaru-treasury-tx envelope-witness \
  < core_development.witness.hex \
  > core_development.witness.json
```

## 5. Expected Failures

Wrong passphrase:

```bash
exec 9<<<"wrong passphrase"
amaru-treasury-tx --network preprod witness \
  --tx "$unsigned_tx" \
  --vault treasury.vault.age \
  --vault-passphrase-fd 9 \
  --identity core_development
exec 9<&-
```

Wrong identity:

```bash
exec 9<<<"correct horse battery staple"
amaru-treasury-tx --network preprod witness \
  --tx "$unsigned_tx" \
  --vault treasury.vault.age \
  --vault-passphrase-fd 9 \
  --identity wrong_key
exec 9<&-
```

Missing required signer hashes:

```bash
exec 9<<<"correct horse battery staple"
amaru-treasury-tx --network preprod witness \
  --tx tx.without-required-signers.cborHex \
  --vault treasury.vault.age \
  --vault-passphrase-fd 9 \
  --identity core_development \
  --expected-key-hash "$(cat key.hash)" \
  --out core_development.witness.hex
exec 9<&-
```

All failures must leave stdout empty when stdout is the witness stream,
must not create the requested output path, and must not print
passphrases, decrypted vault JSON, signing-key CBOR, or seed phrases.

## 6. Repository Smoke

```bash
nix develop --quiet -c scripts/smoke/vault-witness
```

The smoke builds the executable, creates an encrypted fixture vault with
a low test-only scrypt work factor, invokes `witness` with passphrases
through file descriptors, checks file and stdout output, attaches the
produced witness, and verifies wrong-key, wrong-network,
wrong-passphrase, and output-overwrite failures.

The pseudo-terminal check is available separately:

```bash
nix develop --quiet -c scripts/smoke/vault-witness-tty
```

It verifies hidden signing-key paste and the `/dev/tty` no-echo
passphrase prompts without writing decrypted vaults or signing keys to
disk. The `Darwin vault TTY smoke` CI job runs the same script through
the `.#checks.aarch64-darwin.vault-tty-smoke` Nix check.
