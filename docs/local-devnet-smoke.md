# Local Devnet Smoke

The local devnet smoke is an opt-in release check. It starts the
`cardano-node-clients` devnet, verifies the node socket with network
magic `42`, records the short-epoch timing evidence, and writes all
artifacts under a fresh run directory.

This check is not part of `just ci`: it starts a real local
`cardano-node` and is meant as manual live evidence before a release.

## Prerequisites

Run it from the repository dev shell:

```bash
nix develop --quiet
```

The dev shell provides:

- `cardano-node` from the Cardano node 10.7.0 flake input;
- `E2E_GENESIS_DIR`, pointing at the pinned
  `cardano-node-clients` devnet genesis;
- the Cabal dependencies for `cardano-node-clients:devnet`.

## Node Boundary

```bash
just devnet-smoke node
```

Expected output:

```text
devnet-smoke: run-dir runs/devnet/YYYYMMDDTHHMMSSZ
devnet-smoke: network devnet magic 42
devnet-smoke: epoch-duration 50.0
devnet-smoke: socket /tmp/.../cardano-e2e/node.sock
devnet-smoke: phase node passed
```

The smoke writes:

```text
runs/devnet/YYYYMMDDTHHMMSSZ/
|-- node.log
|-- summary.json
|-- summary.log
`-- timing.json
```

`timing.json` records the pinned genesis values:

- `epochLength`: `500`
- `slotLengthSeconds`: `0.1`
- `epochDurationSeconds`: `50`
- `networkMagic`: `42`

## Current Scope

The implemented phase is `node`. It proves that the local devnet
starts, the socket accepts magic `42`, and the epoch is short enough
for the planned withdrawal smoke.

The `withdraw`, `disburse`, and `all` phases are planned but not yet
implemented. They require local reward-source and treasury/registry
state preparation. Until those phases land, successful node smoke is
only node-boundary evidence, not proof that a withdrawal or disburse
transaction was built on the local chain.

## Failure Shape

The node phase fails before any treasury action if:

- `cardano-node` is not on `PATH`;
- `E2E_GENESIS_DIR` does not point at a
  `cardano-node-clients` genesis directory;
- the run directory already contains artifacts;
- the socket does not accept devnet magic `42`;
- the effective epoch duration is not short enough for manual reward
  testing.

Use the run directory's `node.log`, `summary.log`, and `timing.json`
when recording release evidence or diagnosing failure.
