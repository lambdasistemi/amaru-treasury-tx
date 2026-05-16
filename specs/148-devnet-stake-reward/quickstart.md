# Quickstart: DevNet Stake And Reward Setup

## Prerequisites

Run from the repository dev shell:

```bash
nix develop --quiet
```

Registry artifacts from #147 must exist for the same local DevNet run.

## Run Stake/Reward Setup Command

Run the shipped command against a running local DevNet:

```bash
amaru-treasury-tx --network devnet --node-socket "$CARDANO_NODE_SOCKET_PATH" \
  devnet stake-reward-init \
  --registry-file runs/devnet/manual-registry-init/registry-init/registry.json \
  --funding-address "$DEVNET_FUNDING_ADDRESS" \
  --signing-key-file "$DEVNET_PAYMENT_SKEY" \
  --run-dir runs/devnet/manual-stake-reward-init
```

Expected success output includes:

```text
stake-reward-init: run-dir runs/devnet/manual-stake-reward-init
stake-reward-init: network devnet magic 42
stake-reward-init: phase stake-reward-init passed
stake-reward-init: setup-tx-id <tx-id>
stake-reward-init: treasury-reward-account <28-byte-hex>
stake-reward-init: permissions-reward-account <28-byte-hex>
stake-reward-init: summary runs/devnet/manual-stake-reward-init/stake-reward-init/summary.json
stake-reward-init: accounts runs/devnet/manual-stake-reward-init/stake-reward-init/accounts.json
```

## Run Live Smoke Proof

```bash
just devnet-smoke stake-reward-init
```

Expected success output includes:

```text
stake-reward-init: run-dir runs/devnet/YYYYMMDDTHHMMSSZ
stake-reward-init: network devnet magic 42
stake-reward-init: phase stake-reward-init passed
stake-reward-init: setup-tx-id <tx-id>
stake-reward-init: treasury-reward-account <28-byte-hex>
stake-reward-init: permissions-reward-account <28-byte-hex>
stake-reward-init: summary runs/devnet/YYYYMMDDTHHMMSSZ/stake-reward-init/summary.json
stake-reward-init: accounts runs/devnet/YYYYMMDDTHHMMSSZ/stake-reward-init/accounts.json
```

## Inspect Artifacts

```bash
jq . runs/devnet/YYYYMMDDTHHMMSSZ/stake-reward-init/accounts.json
jq . runs/devnet/YYYYMMDDTHHMMSSZ/stake-reward-init/summary.json
```

Required paths on success:

```text
runs/devnet/YYYYMMDDTHHMMSSZ/
|-- registry-init/
|   `-- registry.json
`-- stake-reward-init/
    |-- accounts.json
    |-- provenance.json
    `-- summary.json
```

In `accounts.json`, `treasury.registered` is expected to be `true` and
`permissions.registered` is expected to be `false`. The permissions
reward account is still emitted because later disburse/swap transactions
use it as the withdraw-zero target; registration through a certificate
is not part of this command.

Latest accepted live proof:

```text
run-dir: runs/devnet/20260516T213258Z
setup-tx-id: 89737f7b4439008d5aeca01789addbbbfeb2876cb4a0fab224f1c545e4076598
treasury.rewardAccount: b2b7201c62e43ae8e03b61c96931379ebbcdce61befc3f4e4b1f4be4
treasury.registered: true
permissions.rewardAccount: f9dc1d931a3f52eaf83891f8621cbba5ba64f6faa5792f1b00c17333
permissions.registered: false
```

Failure paths:

```text
runs/devnet/YYYYMMDDTHHMMSSZ/
`-- stake-reward-init/
    `-- failure.json
```

## Gate

Baseline branch gate:

```bash
./gate.sh
```

Live proof before final handoff:

```bash
nix develop --quiet -c just devnet-smoke stake-reward-init
```
