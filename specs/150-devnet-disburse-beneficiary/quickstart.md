# Quickstart: DevNet Disburse Submit

## Live Proof Harness

```bash
nix develop --quiet -c just devnet-smoke disburse-submit
```

The smoke starts a fresh DevNet, runs `registry-init`,
`stake-reward-init`, `governance-withdrawal-init`, then invokes the
shipped `devnet disburse-submit` command.

## Manual Command Shape

Against an already running DevNet whose #147 and #149 artifacts exist:

```bash
amaru-treasury-tx --network devnet --node-socket "$CARDANO_NODE_SOCKET_PATH" \
  devnet disburse-submit \
  --registry-file runs/devnet/manual/registry-init/registry.json \
  --materialized-file runs/devnet/manual/governance-withdrawal-init/materialized.json \
  --funding-address "$DEVNET_FUNDING_ADDRESS" \
  --signing-key-file "$DEVNET_PAYMENT_SKEY" \
  --beneficiary-address "$DEVNET_BENEFICIARY_ADDRESS" \
  --run-dir runs/devnet/manual-disburse-submit \
  --amount-lovelace 1000000
```

## Expected Artifacts

```text
runs/devnet/<timestamp>/
|-- registry-init/
|-- stake-reward-init/
|-- governance-withdrawal-init/
`-- disburse-submit/
    |-- beneficiary.json
    |-- disburse.json
    |-- failure.json                  # only on failure
    |-- intent.json
    |-- provenance.json
    |-- report.json
    |-- report.md
    |-- signed-tx.cbor.hex
    |-- submit.log
    |-- summary.json
    |-- treasury.json
    `-- tx-body.cbor.hex
```

## Local Verification Before Ready

```bash
./gate.sh
nix develop --quiet -c just devnet-smoke disburse-submit
```
