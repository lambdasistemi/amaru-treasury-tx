# Local DevNet Smoke

The local DevNet smoke is an opt-in release check. It starts the
`cardano-node-clients` DevNet, verifies the node socket with network
magic `42`, records short-epoch timing evidence, and writes artifacts
under a fresh run directory.

This check is not part of `just ci`: it starts a real local
`cardano-node` and is meant as manual live evidence before a release.

## Prerequisites

Run it from the repository dev shell:

```bash
nix develop --quiet
```

The dev shell provides:

- `cardano-node` from the Cardano node flake input;
- `E2E_GENESIS_DIR`, pointing at the pinned
  `cardano-node-clients` DevNet genesis;
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

## DevNet Experiment Order

The experiment is split into three tickets:

- [#82](https://github.com/lambdasistemi/amaru-treasury-tx/issues/82):
  governance action slice. This prepares and submits the local Conway
  treasury-withdrawal governance action that funds an Amaru script
  reward account.
- [#83](https://github.com/lambdasistemi/amaru-treasury-tx/issues/83):
  withdrawal slice. This consumes the funded reward account with
  `withdraw-wizard` and `tx-build`.
- [#84](https://github.com/lambdasistemi/amaru-treasury-tx/issues/84):
  swap slice. This brings the current swap path up to live DevNet
  evidence.

The implemented phase today is `node`. A successful node smoke proves
only the local node boundary, network magic, and timing. It is not yet
proof that governance, withdrawal, or swap transactions have been built
or observed on DevNet.

## Governance Funding Model

The withdrawal path needs funds in the treasury script reward account.
On a local Conway DevNet, that means the setup must use protocol
treasury state and a treasury-withdrawal governance action targeting
the Amaru script stake credential.

A delegated key reward account is not accepted as Amaru withdrawal
evidence because the production withdrawal transaction uses the script
credential as the `Rewarding` witness. The governance setup must also
match the original Amaru registration shape: registration plus
always-abstain vote delegation.

Required upstream library support is tracked in:

- [cardano-node-clients#130](https://github.com/lambdasistemi/cardano-node-clients/issues/130)
- [cardano-node-clients#131](https://github.com/lambdasistemi/cardano-node-clients/issues/131)

## Failure Shape

The node phase fails before any treasury action if:

- `cardano-node` is not on `PATH`;
- `E2E_GENESIS_DIR` does not point at a
  `cardano-node-clients` genesis directory;
- the run directory already contains artifacts;
- the socket does not accept DevNet magic `42`;
- the effective epoch duration is not short enough for manual
  governance/reward testing.

Use the run directory's `node.log`, `summary.log`, and `timing.json`
when recording release evidence or diagnosing failure.
