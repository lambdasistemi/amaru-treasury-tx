# amaru-treasury-tx

CLI for building unsigned Conway transactions against the Amaru
treasury contracts on top of the
[`cardano-node-clients` `TxBuild` DSL][txbuild].

Haskell port of the bash recipes in
[`pragma-org/amaru-treasury/journal/2026/`][recipes].

## Quick links

- [**Quickstart**](quickstart.md) — the `swap-wizard | swap` pipe in one go.
- [Architecture overview](architecture.md) — modules and data flow.
- [Trust model](trust-model.md) — what the wizard verifies, what the operator must assert.
- [Swap recipe](swap.md) — the `swap` subcommand on its own.
- [ChainContext](chain-context.md)
- [Freeze workflow](freeze-workflow.md) — pinning a `ChainContext` for offline parity tests.
- [Parity report](parity.md)
- [Release automation](release.md)
- [Spec / plan / tasks](https://github.com/lambdasistemi/amaru-treasury-tx/tree/main/specs)
- [Source](https://github.com/lambdasistemi/amaru-treasury-tx)

## Capabilities

| Subcommand    | Purpose                                                                                          |
| :------------ | :----------------------------------------------------------------------------------------------- |
| `swap-wizard` | Verify upstream `metadata.json` against the chain, resolve UTxOs + tip, emit a unified `intent.json` (typed step trace via `WizardEvent`). |
| `tx-build`    | Turn any unified `intent.json` into unsigned Conway CBOR; re-evaluates every redeemer against a live `ChainContext` (typed step trace via `BuildEvent`). |

`tx-build` reads the action discriminator and the network from
the intent itself (single source of truth) and dispatches to the
matching pure builder. Today only the `swap` action is wired;
`disburse` / `withdraw` / `reorganize` light up as they ship.

The library also exposes pure builders for `disburse` and
`withdraw` (`Amaru.Treasury.Tx.Disburse`,
`Amaru.Treasury.Tx.Withdraw`); the `tx-build` dispatcher will
call them once the corresponding intent payloads ship.

## Out of scope

- Signing the unsigned CBOR.
- Submitting the signed transaction.
- Registry / scopes NFT minting.
- Reference-script publishing.
- The Sundae `Fund` redeemer (Amaru disables it).

[recipes]: https://github.com/pragma-org/amaru-treasury/tree/main/journal/2026
[txbuild]: https://github.com/lambdasistemi/cardano-node-clients/blob/main/lib/Cardano/Node/Client/TxBuild.hs
