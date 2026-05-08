# amaru-treasury-tx

CLI for building unsigned Conway transactions against the Amaru
treasury contracts on top of the
[`cardano-node-clients` `TxBuild` DSL][txbuild].

Haskell port of the bash recipes in
[`pragma-org/amaru-treasury/journal/2026/`][recipes].

## Quick links

- [**Quickstart**](quickstart.md) — the `swap-wizard | tx-build` pipe in one go.
- [Architecture overview](architecture.md) — modules and data flow.
- [Trust model](trust-model.md) — what the wizard verifies, what the operator must assert.
- [Swap recipe](swap.md) — building an existing swap intent with `tx-build`.
- [ADA disburse](disburse.md) — building an existing disburse intent with `tx-build`.
- [Withdraw](withdraw.md) — resolving treasury rewards with `withdraw-wizard` or building an existing withdraw intent.
- [ChainContext](chain-context.md)
- [Freeze workflow](freeze-workflow.md) — pinning a `ChainContext` for offline parity tests.
- [Parity report](parity.md)
- [Release automation](release.md)
- [Spec / plan / tasks](https://github.com/lambdasistemi/amaru-treasury-tx/tree/main/specs)
- [Source](https://github.com/lambdasistemi/amaru-treasury-tx)

## Capabilities

| Command | Purpose |
| :------ | :------ |
| `swap-wizard` | Verify upstream `metadata.json` against the chain, resolve UTxOs + tip, emit a unified swap `intent.json` (typed step trace via `WizardEvent`). |
| `withdraw-wizard` | Verify upstream `metadata.json` against the chain, resolve the treasury reward account + reward balance, emit a unified withdraw `intent.json`, or exit cleanly when rewards are zero. |
| `tx-build` | Turn a unified `intent.json` into unsigned Conway CBOR; re-evaluates every redeemer against a live `ChainContext` (typed step trace via `BuildEvent`). |

`tx-build` reads the action discriminator and the network from
the intent itself (single source of truth) and dispatches to the
matching builder.

| Intent action | Release status |
| :------------ | :------------- |
| `swap` | Built from wizard output or an existing intent. Pinned by a bash/cardano-cli golden. |
| `disburse` | ADA disburse intents build through `tx-build`. Pinned by a bash/cardano-cli golden. |
| `withdraw` | Built from wizard output or an existing intent. Pinned by a synthetic frozen-context golden until issue #17 records a live preprod oracle. |
| `reorganize` | Parsed, but build fails closed until #46 ships. |

## Out of scope

- Signing the unsigned CBOR.
- Submitting the signed transaction.
- Registry / scopes NFT minting.
- Reference-script publishing.
- The Sundae `Fund` redeemer (Amaru disables it).

[recipes]: https://github.com/pragma-org/amaru-treasury/tree/main/journal/2026
[txbuild]: https://github.com/lambdasistemi/cardano-node-clients/blob/main/lib/Cardano/Node/Client/TxBuild.hs
