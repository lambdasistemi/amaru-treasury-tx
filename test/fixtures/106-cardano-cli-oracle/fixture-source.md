# cardano-cli envelope oracle fixture

This fixture pins the JSON text-envelope shape emitted by the official
`cardano-cli` binary from the `cardano-node` 10.7.0 Linux release asset.

Version:

```text
cardano-cli 10.15.1.0 - linux-x86_64 - ghc-9.6
git rev 1e6d8228693ab2aa4e1d7305e7bdcc57cdd278e4
```

The fixture was generated offline; no node socket or chain query is involved.
The transaction input is a dummy all-zero TxId because the envelope shape, not
ledger validity, is the contract under test.

```bash
cardano-cli conway address key-gen \
  --verification-key-file payment.vkey \
  --signing-key-file payment.skey

cardano-cli conway address build \
  --payment-verification-key-file payment.vkey \
  --testnet-magic 1 \
  --out-file payment.addr

addr="$(tr -d '\n' < payment.addr)"

cardano-cli conway transaction build-raw \
  --tx-in 0000000000000000000000000000000000000000000000000000000000000000#0 \
  --tx-out "${addr}+1000000" \
  --fee 200000 \
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

jq -r .cborHex tx.body.json | tr -d '\n' > tx.body.cborHex
jq -r .cborHex tx.witness.json | tr -d '\n' > tx.witness.cborHex
jq -r .cborHex tx.signed.json | tr -d '\n' > tx.signed.cborHex
```

The test signing key is intentionally not checked in. Refresh this directory
as a unit; refreshed witness and signed transaction bytes will differ if a new
key pair is generated.
