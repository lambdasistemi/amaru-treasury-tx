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
| `swap-wizard` | Verify upstream `metadata.json` against the chain, resolve UTxOs + tip, emit `intent.json` (typed step trace via `WizardEvent`). |
| `swap`        | Turn an `intent.json` into unsigned Conway CBOR; re-evaluates every redeemer against a live `ChainContext` (typed step trace via `SwapEvent`). |

The library also exposes pure builders for the `disburse` and
`withdraw` recipes (`Amaru.Treasury.Tx.Disburse`,
`Amaru.Treasury.Tx.Withdraw`), but no CLI surface is wired today;
they live in the library for downstream consumers.

## Out of scope

- Signing the unsigned CBOR.
- Submitting the signed transaction.
- Registry / scopes NFT minting.
- Reference-script publishing.
- The Sundae `Fund` redeemer (Amaru disables it).

[recipes]: https://github.com/pragma-org/amaru-treasury/tree/main/journal/2026
[txbuild]: https://github.com/lambdasistemi/cardano-node-clients/blob/main/lib/Cardano/Node/Client/TxBuild.hs
