# Local DevNet Smoke

The local DevNet smoke is an opt-in release check. It starts the
`cardano-node-clients` DevNet, verifies the node socket with network
magic `42`, can run the governance funding setup on a patched
short-epoch genesis, records timing/action/reward evidence, and writes
artifacts under a fresh run directory.

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

## Governance Boundary

```bash
just devnet-smoke governance
```

Expected output:

```text
devnet-smoke: run-dir runs/devnet/YYYYMMDDTHHMMSSZ
devnet-smoke: network devnet magic 42
devnet-smoke: epoch-duration 5.0
devnet-smoke: socket /tmp/.../cardano-e2e/node.sock
devnet-smoke: phase governance passed
devnet-smoke: governance-tx-id TxId {...}
devnet-smoke: governance-action-id GovActionId {...}
devnet-smoke: reward-account 5fbb3e5295c211c7595ddd23db2e0a0833131e0681cc7ea800f85d34
devnet-smoke: governance-amount 2000000
devnet-smoke: governance-summary runs/devnet/YYYYMMDDTHHMMSSZ/governance/summary.json
```

The governance smoke copies the pinned DevNet genesis into the run
directory, patches it to a 5-second epoch for manual reward testing,
registers the Amaru treasury script stake credential with the
registration-plus-always-abstain certificate shape, submits a Conway
treasury-withdrawal governance action, votes it through, waits for the
next epoch, and observes the script reward account through
`Provider.queryRewardAccounts`.

The latest local evidence for this branch is
`runs/devnet/20260513T143827Z`, using `cardano-node-clients` main
commit `d6773e4cd8a2421617568c8dac0972b0f312a509`. It funded the script
reward account from `0` to `2000000` lovelace across epochs `2 -> 4`.

The governance phase writes:

```text
runs/devnet/YYYYMMDDTHHMMSSZ/
|-- node.log
|-- summary.json
|-- summary.log
|-- timing.json
`-- governance/
    |-- action.json
    |-- certificates.json
    |-- genesis/
    `-- summary.json
```

## DevNet Experiment Order

The experiment is split into six tickets:

- [#82](https://github.com/lambdasistemi/amaru-treasury-tx/issues/82):
  governance action slice. This prepares and submits the local Conway
  treasury-withdrawal governance action that funds an Amaru script
  reward account.
- [#83](https://github.com/lambdasistemi/amaru-treasury-tx/issues/83):
  withdrawal slice. This consumes the funded reward account with
  `withdraw-wizard` and `tx-build`.
- [#86](https://github.com/lambdasistemi/amaru-treasury-tx/issues/86):
  disburse slice. This exercises `disburse-wizard` and `tx-build`
  against live treasury UTxOs, with USDM as the common operator path
  and ADA as an explicit covered variant.
- [#84](https://github.com/lambdasistemi/amaru-treasury-tx/issues/84):
  SundaeSwap V3 order build/funding slice. This brings the current
  swap path up to live DevNet evidence against the open-source
  SundaeSwap V3 order interface.
- [#85](https://github.com/lambdasistemi/amaru-treasury-tx/issues/85):
  SundaeSwap V3 order spend slice. This consumes the funded order
  under the real V3 contract rules on local DevNet.
- [#87](https://github.com/lambdasistemi/amaru-treasury-tx/issues/87):
  reorganize slice. This consolidates live treasury UTxOs once the
  release-facing reorganize builder from #46 exists.

The implemented phases today are `node` and `governance`.

`node` proves only the local node boundary, network magic, and timing.
`governance` proves the local setup path that funds the Amaru treasury
script reward account. It is not proof that withdrawal, disburse,
SundaeSwap order-build, SundaeSwap order-spend, or reorganize
transactions have been built or observed on DevNet.

SundaeSwap V3 contract compatibility should use the public V3 Aiken
contracts and SDK/reference material:

- [SundaeSwap V3 contracts](https://github.com/SundaeSwap-finance/sundae-contracts)
- [SundaeSwap SDK](https://github.com/SundaeSwap-finance/sundae-sdk)

A local toy swap validator is acceptable only as an explicitly named
fixture boundary. It is not SundaeSwap compatibility evidence.

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

Required upstream library support was originally tracked in:

- [cardano-node-clients#130](https://github.com/lambdasistemi/cardano-node-clients/issues/130)
- [cardano-node-clients#131](https://github.com/lambdasistemi/cardano-node-clients/issues/131)

The downstream proof now consumes `cardano-node-clients` main after the
upstream PR stack merged:

- [cardano-node-clients#135](https://github.com/lambdasistemi/cardano-node-clients/pull/135)
- [cardano-node-clients#137](https://github.com/lambdasistemi/cardano-node-clients/pull/137)
- [cardano-node-clients#132](https://github.com/lambdasistemi/cardano-node-clients/pull/132)

The pinned upstream commit is
`d6773e4cd8a2421617568c8dac0972b0f312a509`.

## Failure Shape

The node phase fails before any treasury action if:

- `cardano-node` is not on `PATH`;
- `E2E_GENESIS_DIR` does not point at a
  `cardano-node-clients` genesis directory;
- the run directory already contains artifacts;
- the socket does not accept DevNet magic `42`;
- the effective epoch duration is not short enough for manual
  governance/reward testing.

The governance phase may still fail with a typed upstream or local
boundary if the pinned `cardano-node-clients` main commit moves, the
genesis patch no longer applies, funds are insufficient, the action is
not observed, or the reward account is not funded before the wait
budget expires.

Use the run directory's `node.log`, `summary.log`, `timing.json`, and
`governance/summary.json` when recording release evidence or
diagnosing failure.
