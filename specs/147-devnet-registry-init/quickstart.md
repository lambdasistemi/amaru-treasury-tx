# Quickstart: DevNet Registry Initiator

## Prerequisites

Run from the repository dev shell:

```bash
nix develop --quiet
```

The shell must provide the pinned `cardano-node-clients` DevNet support
and `cardano-node`.

## Run Registry Init

```bash
just devnet-smoke registry-init
```

Expected success output includes:

```text
devnet-smoke: run-dir runs/devnet/YYYYMMDDTHHMMSSZ
devnet-smoke: network devnet magic 42
devnet-smoke: phase registry-init passed
devnet-smoke: registry-init-summary runs/devnet/YYYYMMDDTHHMMSSZ/registry-init/summary.json
devnet-smoke: registry-init-registry runs/devnet/YYYYMMDDTHHMMSSZ/registry-init/registry.json
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
