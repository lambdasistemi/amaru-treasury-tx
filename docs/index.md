# amaru-treasury-tx

CLI for building unsigned Conway transactions against the Amaru
treasury contracts, creating detached vault-backed witnesses, and
assembling/submitting signed transactions on top of the
[`cardano-node-clients` `TxBuild` DSL][txbuild].

Haskell port of the bash recipes in
[`pragma-org/amaru-treasury/journal/2026/`][recipes].

## Quick links

- [**Quickstart**](quickstart.md) — wizard-to-`tx-build` pipes, pre-signing report review, and vault-backed witness creation.
- [Architecture overview](architecture.md) — modules and data flow.
- [Trust model](trust-model.md) — what the wizard verifies, what the operator must assert.
- [Swap recipe](swap.md) — building an existing swap intent with `tx-build`.
- [Disburse](disburse.md) — resolving owned-scope ADA or USDM disbursements with `disburse-wizard`, emergency ADA top-ups from contingency with `emergency-top-up-wizard`, or building an existing disburse intent with `tx-build`.
- [Withdraw](withdraw.md) — resolving treasury rewards with `withdraw-wizard` or building an existing withdraw intent.
- [Local devnet smoke](local-devnet-smoke.md) — opt-in live `cardano-node-clients` devnet node check.
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
| `swap-cancel` | Verify an explicitly supplied pending SundaeSwap order and build unsigned cancellation CBOR that returns the order value to the selected treasury. |
| `withdraw-wizard` | Verify upstream `metadata.json` against the chain, resolve the treasury reward account + reward balance, emit a unified withdraw `intent.json`, or exit cleanly when rewards are zero. |
| `disburse-wizard` | Verify upstream `metadata.json` against the chain, resolve wallet and treasury UTxOs, emit a unified ADA or USDM disburse `intent.json`. USDM is the default unit. |
| `emergency-top-up-wizard` | Verify contingency and destination-scope registry state, move ADA from `contingency` to an owned treasury scope, and emit a unified disburse `intent.json`. |
| `tx-build` | Turn a unified `intent.json` into unsigned Conway CBOR; re-evaluates every redeemer against a live `ChainContext` (typed step trace via `BuildEvent`) and can write a deterministic pre-signing report with `--report PATH`. |
| `vault create` | Import one pasted or streamed Cardano payment signing-key envelope into an encrypted age witness vault. |
| `witness` | Create one detached Conway vkey witness from an encrypted age vault identity. |
| `attach-witness` | Merge detached vkey witness CBOR hex into an unsigned Conway transaction. |
| `submit` | Submit signed Conway CBOR hex through a local node socket. |

`tx-build` reads the action discriminator and the network from
the intent itself (single source of truth) and dispatches to the
matching builder.

| Intent action | Release status |
| :------------ | :------------- |
| `swap` | Built from wizard output or an existing intent. Pinned by a bash/cardano-cli golden. |
| `disburse` | ADA and USDM disburse intents build through `tx-build`. ADA remains pinned by a bash/cardano-cli golden; USDM has structural builder and resolver regression coverage. |
| `withdraw` | Built from wizard output or an existing intent. Pinned by a synthetic frozen-context golden until issue #17 records a live preprod oracle. |
| `reorganize` | Parsed, but build fails closed until #46 ships. |

## Out of scope

- Implicit signing during `tx-build`.
- Vault custody policy, recipient rotation, and key ceremony design.
- Registry / scopes NFT minting.
- Reference-script publishing.
- The Sundae `Fund` redeemer (Amaru disables it).

[recipes]: https://github.com/pragma-org/amaru-treasury/tree/main/journal/2026
[txbuild]: https://github.com/lambdasistemi/cardano-node-clients/blob/main/lib/Cardano/Node/Client/TxBuild.hs
