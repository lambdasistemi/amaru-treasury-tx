# vault witness fixture

These files are test-only fixtures for issue #128. The signing keys in
`payment.skey`, `wrong-payment.skey`, and `payment.addr_xsk` are
generated throwaway keys with no value outside this repository's tests.

Generated with the Nix-provided `cardano-cli`:

```bash
cardano-cli conway address key-gen \
  --verification-key-file payment.vkey \
  --signing-key-file payment.skey

key_hash="$(cardano-cli conway address key-hash \
  --payment-verification-key-file payment.vkey)"

cardano-cli conway address build \
  --payment-verification-key-file payment.vkey \
  --testnet-magic 1 \
  --out-file payment.addr

cardano-cli conway transaction build-raw \
  --tx-in 1111111111111111111111111111111111111111111111111111111111111111#0 \
  --tx-out "$(cat payment.addr)+1000000" \
  --fee 200000 \
  --required-signer-hash "$key_hash" \
  --out-file tx.body.json

cardano-cli conway transaction witness \
  --tx-body-file tx.body.json \
  --signing-key-file payment.skey \
  --testnet-magic 1 \
  --out-file tx.witness.json

cardano-cli conway transaction assemble \
  --tx-body-file tx.body.json \
  --witness-file tx.witness.json \
  --out-file tx.signed.json
```

`payment.skey` is retained only as a test fixture. The smoke streams it
through `vault create --signing-key-stdin` instead of recommending a
plaintext key path for operators. `vault.clear.json` and
`vault.wrong-key.clear.json` are test-only cleartext payloads for pure
schema and signing tests; they are not example operator vault files.

The smoke creates binary age vaults in a temporary directory using a
low test-only scrypt work factor, passes the passphrase through file
descriptor 9, and verifies that `witness` signs from the encrypted vault
without a plaintext signing-key argument. `scripts/smoke/vault-witness-tty`
adds a pseudo-terminal check for hidden signing-key paste and the
no-echo passphrase prompt.

`payment.addr_xsk` is a deterministic cardano-addresses address
extended signing key fixture in the 96-byte `addr_xsk1...` wire format.
It covers the operator-facing import format and is unrelated to the
`payment.skey` required-signer fixture.
