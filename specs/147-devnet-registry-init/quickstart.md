# Quickstart: DevNet Registry Initiator

## Prerequisites

Run from the repository dev shell:

```bash
nix develop --quiet
```

The shell must provide the pinned `cardano-node-clients` DevNet support
and `cardano-node`.

## Run Registry Init Command

Run the shipped command against a running local DevNet:

```bash
amaru-treasury-tx --network devnet --node-socket "$CARDANO_NODE_SOCKET_PATH" \
  devnet registry-init \
  --funding-address "$DEVNET_FUNDING_ADDRESS" \
  --signing-key-file "$DEVNET_PAYMENT_SKEY" \
  --run-dir runs/devnet/manual-registry-init
```

Expected success output includes:

```text
registry-init: run-dir runs/devnet/manual-registry-init
registry-init: network devnet magic 42
registry-init: phase registry-init passed
registry-init: seed-split-tx-id <tx-id>
registry-init: registry-mint-tx-id <tx-id>
registry-init: reference-scripts-tx-id <tx-id>
registry-init: summary runs/devnet/manual-registry-init/registry-init/summary.json
registry-init: registry runs/devnet/manual-registry-init/registry-init/registry.json
```

## Run Live Smoke Proof

```bash
just devnet-smoke registry-init
```

Expected success output includes:

```text
registry-init: run-dir runs/devnet/YYYYMMDDTHHMMSSZ
registry-init: network devnet magic 42
registry-init: phase registry-init passed
registry-init: seed-split-tx-id <tx-id>
registry-init: registry-mint-tx-id <tx-id>
registry-init: reference-scripts-tx-id <tx-id>
registry-init: summary runs/devnet/YYYYMMDDTHHMMSSZ/registry-init/summary.json
registry-init: registry runs/devnet/YYYYMMDDTHHMMSSZ/registry-init/registry.json
```

## Inspect Artifacts

```bash
jq . runs/devnet/YYYYMMDDTHHMMSSZ/registry-init/registry.json
jq . runs/devnet/YYYYMMDDTHHMMSSZ/registry-init/summary.json
```

Required paths on success:

```text
runs/devnet/YYYYMMDDTHHMMSSZ/
|-- node.log
|-- summary.json
|-- summary.log
|-- timing.json
`-- registry-init/
    |-- provenance.json
    |-- registry.json
    `-- summary.json
```

Failure paths:

```text
runs/devnet/YYYYMMDDTHHMMSSZ/
`-- registry-init/
    |-- failure.json
    `-- summary.json
```

## Gate

Baseline gate:

```bash
./llm/reviews/local-147-devnet-registry-init/gate.sh
```

Live proof before final handoff:

```bash
nix develop --quiet -c just devnet-smoke registry-init
```
