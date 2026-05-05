# Architecture

`amaru-treasury-tx` is a thin executable on top of the
[`cardano-node-clients`][cnc] `TxBuild` DSL. The behavioural
source of truth is the bash recipe set in
[`pragma-org/amaru-treasury/journal/2026/`][recipes].

## Layered design

```mermaid
flowchart TD
    CLI[app/amaru-treasury-tx/Main.hs<br/><i>impure</i>]
    Wizard[Tx.SwapWizard<br/><i>pure</i>]
    SwapBuild[Tx.SwapBuild<br/><i>pure</i>]
    Disburse[Tx.Disburse<br/><i>pure TxBuild q e ()</i>]
    Withdraw[Tx.Withdraw<br/><i>pure</i>]
    Verify[Registry.Verify<br/><i>pure + Provider IO</i>]
    Trace1[Tx.SwapWizard.Trace<br/><i>pure</i>]
    Trace2[Tx.Swap.Trace<br/><i>pure</i>]
    Intent[Tx.SwapIntentJSON<br/><i>encode / decode / translate</i>]
    Swap[Tx.Swap<br/><i>SwapIntent + program</i>]
    Redeemer[Redeemer]
    AuxData[AuxData]
    N2C[Backend.N2C<br/><i>impure</i>]
    Provider[Cardano.Node.Client.Provider<br/><i>record of functions</i>]

    CLI --> Wizard
    CLI --> SwapBuild
    CLI --> Disburse
    CLI --> Withdraw
    CLI --> Trace1
    CLI --> Trace2
    Wizard --> Verify
    Wizard --> Intent
    SwapBuild --> Swap
    SwapBuild --> Intent
    Swap --> Redeemer
    Swap --> AuxData
    Disburse --> Redeemer
    Disburse --> AuxData
    Withdraw --> Redeemer
    Withdraw --> AuxData
    CLI --> N2C
    Verify --> Provider
    N2C --> Provider
```

## Module layout

| Module                                  | Role                                                            | Pure? |
| :-------------------------------------- | :-------------------------------------------------------------- | :---: |
| `Amaru.Treasury.Scope`                  | Scope identifiers + parsers                                     | yes |
| `Amaru.Treasury.Constants`              | USDM policy/asset constants                                     | yes |
| `Amaru.Treasury.Metadata`               | Parse `journal/2026/metadata.json`                              | yes |
| `Amaru.Treasury.LedgerParse`            | Address / hash / TxIn parsers                                   | yes |
| `Amaru.Treasury.Redeemer`               | `ToData` for Sundae and permissions redeemers                   | yes |
| `Amaru.Treasury.UtxoSelect`             | UTxO selection with blacklist                                   | yes |
| `Amaru.Treasury.AuxData`                | Treasury-instance metadata builder                              | yes |
| `Amaru.Treasury.Validity`               | Upper validity bound from wall-clock                            | yes |
| `Amaru.Treasury.PParams`                | pparams snapshot loader                                         | yes |
| `Amaru.Treasury.Summary`                | Tx summary JSON encoder                                         | yes |
| `Amaru.Treasury.ChainContext`           | Frozen `ChainContext` envelope                                  | yes |
| `Amaru.Treasury.ChainContext.Fixture`   | Frozen-context test fixture loader                              | yes |
| `Amaru.Treasury.Registry.Constants`     | Build-time-pinned seeds + Plutus blob digests                   | yes |
| `Amaru.Treasury.Registry.Derive`        | Re-derive script hashes from the pinned blobs                   | yes |
| `Amaru.Treasury.Registry.Metadata`      | Parse upstream `metadata.json`                                  | yes |
| `Amaru.Treasury.Registry.Verify`        | Walk the registry NFT, verify metadata against chain anchors    | **no** (Provider IO) |
| `Amaru.Treasury.Tx.Disburse`            | `TxBuild q e ()` for `disburse`                                 | yes |
| `Amaru.Treasury.Tx.Withdraw`            | `TxBuild q e ()` for `withdraw`                                 | yes |
| `Amaru.Treasury.Tx.Swap`                | `SwapIntent` + `swapProgram :: TxBuild q e ()`                  | yes |
| `Amaru.Treasury.Tx.SwapBuild`           | `runSwapBuild` against a `ChainContext`                         | yes |
| `Amaru.Treasury.Tx.SwapIntentJSON`      | `intent.json` schema, decode + translate                        | yes |
| `Amaru.Treasury.Tx.SwapWizard`          | Pure questionnaire-to-`SwapIntentJSON` translation + resolver   | yes |
| `Amaru.Treasury.Tx.SwapWizard.Trace`    | Typed `WizardEvent` ADT + renderer                              | yes |
| `Amaru.Treasury.Tx.Swap.Trace`          | Typed `SwapEvent` ADT + renderer                                | yes |
| `Amaru.Treasury.Backend`                | Alias around `Cardano.Node.Client.Provider`                     | yes |
| `Amaru.Treasury.Backend.N2C`            | N2C `Provider` constructor                                      | **no** |
| `app/amaru-treasury-tx/Main.hs`         | Optparse parser, `Tracer` setup, backend wiring, output         | **no** |

## Subcommand → module map

| Subcommand    | Drives                                                                   |
| :------------ | :----------------------------------------------------------------------- |
| `swap-wizard` | `Registry.Verify` → `Tx.SwapWizard` → `Tx.SwapIntentJSON` (encode)       |
| `swap`        | `Tx.SwapIntentJSON` (decode) → `Tx.SwapBuild` → `Tx.Swap`                |
| `disburse`    | `Tx.Disburse`                                                            |
| `withdraw`    | `Tx.Withdraw`                                                            |

Both `swap-wizard` and `swap` route every value-affecting step
through a typed `Tracer` — `WizardEvent` and `SwapEvent`
respectively. See the [Trust model](trust-model.md) page for the
full account of what flows through each event and what the operator
must assert vs. what the verifier rejects.

[cnc]: https://github.com/lambdasistemi/cardano-node-clients
[recipes]: https://github.com/pragma-org/amaru-treasury/tree/main/journal/2026
