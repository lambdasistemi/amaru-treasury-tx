# Quickstart: DevNet Governance And Withdrawal Setup

## Live Proof Harness

Run the command proof on a fresh governance-enabled local DevNet:

```bash
nix develop --quiet -c just devnet-smoke governance-withdrawal-init
```

The smoke starts the local DevNet, prepares registry artifacts through
`devnet registry-init`, prepares stake/reward artifacts through
`devnet stake-reward-init`, and then invokes the shipped #149 command
runner. Successful output includes command-prefixed lines:

```text
governance-withdrawal-init: phase governance-withdrawal-init passed
governance-withdrawal-init: governance-proposal-tx-id <tx-id>
governance-withdrawal-init: governance-action-id <tx-id>#<ix>
governance-withdrawal-init: vote-tx-id <tx-id>
governance-withdrawal-init: reward-after-governance-lovelace 2000000
governance-withdrawal-init: withdraw-submitted-tx-id <tx-id>
governance-withdrawal-init: treasury-materialized-tx-in <tx-id>#<ix>
governance-withdrawal-init: treasury-materialized-ada 2000000
governance-withdrawal-init: summary runs/devnet/<timestamp>/governance-withdrawal-init/summary.json
```

Accepted live evidence for PR #154:

- run directory: `runs/devnet/20260516T231003Z`
- proposal tx: `baffa774b368b1da8c3ff80be399bcf6fa63b5cff658b6889fc00109da218e23`
- governance action: `baffa774b368b1da8c3ff80be399bcf6fa63b5cff658b6889fc00109da218e23#0`
- vote tx: `009801303fc5cc3c3dfe474c30cc4b7d31e99b5af29467cc317072ea6b728c45`
- treasury reward account: `b2b7201c62e43ae8e03b61c96931379ebbcdce61befc3f4e4b1f4be4`
- withdrawal tx: `4a87409b52b8104d51d41df7ee562196cf33621f64c4c40985b4aef5ff21e9bd`
- materialized TxIn: `4a87409b52b8104d51d41df7ee562196cf33621f64c4c40985b4aef5ff21e9bd#0`
- materialized ADA: `2000000`
- reward movement: `0 -> 2000000 -> 0`
- treasury ADA movement: `200000000 -> 202000000`

## Manual Command Shape

Against an already running governance-enabled local DevNet:

```bash
amaru-treasury-tx --network devnet --node-socket "$CARDANO_NODE_SOCKET_PATH" \
  devnet governance-withdrawal-init \
  --registry-file runs/devnet/manual-registry-init/registry-init/registry.json \
  --stake-reward-file runs/devnet/manual-stake-reward-init/stake-reward-init/accounts.json \
  --funding-address "$DEVNET_FUNDING_ADDRESS" \
  --signing-key-file "$DEVNET_PAYMENT_SKEY" \
  --run-dir runs/devnet/manual-governance-withdrawal-init
```

Optional controls:

```bash
  --amount-lovelace 2000000 \
  --reward-timeout-seconds 180
```

The command must fail before effects when invoked with any network other
than `--network devnet`.

## Expected Artifacts

```text
runs/devnet/<timestamp>/
|-- node.log
|-- registry-init/
|   |-- provenance.json
|   |-- registry.json
|   `-- summary.json
|-- stake-reward-init/
|   |-- accounts.json
|   |-- provenance.json
|   `-- summary.json
`-- governance-withdrawal-init/
    |-- failure.json                  # only on failure
    |-- governance.json
    |-- intent.json
    |-- materialized.json
    |-- provenance.json
    |-- report.json
    |-- report.md
    |-- signed-tx.cbor.hex
    |-- submit.log
    |-- summary.json
    |-- tx-body.cbor.hex
    |-- tx-build.log
    `-- withdrawal.json
```

The #150 disburse ticket consumes
`governance-withdrawal-init/materialized.json` to find the treasury
script address, materialized TxIn, and ADA value.

## Local Verification Before Ready

Run the branch gate:

```bash
./gate.sh
```

Run the live proof before marking the PR ready:

```bash
nix develop --quiet -c just devnet-smoke governance-withdrawal-init
```

`withdraw` is accepted as a compatibility phase and proves the same
command runner:

```bash
nix develop --quiet -c just devnet-smoke withdraw
```
