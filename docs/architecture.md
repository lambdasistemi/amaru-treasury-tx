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
    WithdrawWizard[Tx.WithdrawWizard<br/><i>pure</i>]
    TreasuryBuild[TreasuryBuild<br/><i>dispatcher</i>]
    Intent[IntentJSON<br/><i>unified schema</i>]
    Disburse[Tx.Disburse<br/><i>pure TxBuild q e ()</i>]
    Withdraw[Tx.Withdraw<br/><i>pure</i>]
    Verify[Registry.Verify<br/><i>pure + Provider IO</i>]
    Trace1[Tx.SwapWizard.Trace<br/><i>pure</i>]
    TraceWithdraw[Tx.WithdrawWizard.Trace<br/><i>pure</i>]
    Trace2[TreasuryBuild.Trace<br/><i>pure</i>]
    Swap[Tx.Swap<br/><i>SwapIntent + program</i>]
    Redeemer[Redeemer]
    AuxData[AuxData]
    ChainContext[ChainContext<br/><i>live/frozen</i>]
    N2C[Backend.N2C<br/><i>impure</i>]
    Provider[Cardano.Node.Client.Provider<br/><i>record of functions</i>]

    CLI --> Wizard
    CLI --> WithdrawWizard
    CLI --> TreasuryBuild
    CLI --> Trace1
    CLI --> TraceWithdraw
    CLI --> Trace2
    Wizard --> Verify
    Wizard --> Intent
    WithdrawWizard --> Verify
    WithdrawWizard --> Intent
    TreasuryBuild --> Intent
    TreasuryBuild --> ChainContext
    TreasuryBuild --> Swap
    TreasuryBuild --> Disburse
    TreasuryBuild --> Withdraw
    Swap --> Redeemer
    Swap --> AuxData
    Disburse --> Redeemer
    Disburse --> AuxData
    Withdraw --> Redeemer
    Withdraw --> AuxData
    CLI --> N2C
    N2C --> ChainContext
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
| `Amaru.Treasury.ChainContext`           | Live/frozen `ChainContext` envelope                             | yes |
| `Amaru.Treasury.ChainContext.Fixture`   | Frozen-context test fixture loader                              | yes |
| `Amaru.Treasury.IntentJSON`             | Unified intent schema, parser, encoder, action translation      | yes |
| `Amaru.Treasury.IntentJSON.Schema`      | Machine-readable JSON Schema generator                          | yes |
| `Amaru.Treasury.Registry.Constants`     | Build-time-pinned seeds + Plutus blob digests                   | yes |
| `Amaru.Treasury.Registry.Derive`        | Re-derive script hashes from the pinned blobs                   | yes |
| `Amaru.Treasury.Registry.Metadata`      | Parse upstream `metadata.json`                                  | yes |
| `Amaru.Treasury.Registry.Verify`        | Walk the registry NFT, verify metadata against chain anchors    | **no** (Provider IO) |
| `Amaru.Treasury.TreasuryBuild`          | Unified `tx-build` dispatcher and action runners                | **no** (`ChainContext` evaluator) |
| `Amaru.Treasury.TreasuryBuild.Trace`    | Typed `tx-build` trace ADT + renderer                           | yes |
| `Amaru.Treasury.Tx.Disburse`            | `TxBuild q e ()` for `disburse`                                 | yes |
| `Amaru.Treasury.Tx.DisburseWizard`      | Pure disburse questionnaire translation helpers                 | yes |
| `Amaru.Treasury.Tx.Withdraw`            | `TxBuild q e ()` for `withdraw`                                 | yes |
| `Amaru.Treasury.Tx.WithdrawWizard`      | Pure withdraw questionnaire translation + resolver               | yes |
| `Amaru.Treasury.Tx.WithdrawWizard.Trace` | Typed withdraw wizard event ADT + renderer                      | yes |
| `Amaru.Treasury.Tx.Swap`                | `SwapIntent` + `swapProgram :: TxBuild q e ()`                  | yes |
| `Amaru.Treasury.Tx.SwapWizard`          | Pure questionnaire-to-unified-intent translation + resolver     | yes |
| `Amaru.Treasury.Tx.SwapWizard.Trace`    | Typed `WizardEvent` ADT + renderer                              | yes |
| `Amaru.Treasury.Backend`                | Alias around `Cardano.Node.Client.Provider`                     | yes |
| `Amaru.Treasury.Backend.N2C`            | N2C `Provider` constructor                                      | **no** |
| `app/amaru-treasury-tx/Main.hs`         | Optparse parser, `Tracer` setup, backend wiring, output         | **no** |

## Subcommand → module map

| Subcommand    | Drives                                                                   |
| :------------ | :----------------------------------------------------------------------- |
| `swap-wizard` | `Registry.Verify` -> `Tx.SwapWizard` -> unified `IntentJSON` (encode)    |
| `withdraw-wizard` | `Registry.Verify` -> `Tx.WithdrawWizard` -> unified `IntentJSON` (encode) |
| `tx-build`    | unified `IntentJSON` (decode/translate) -> `TreasuryBuild` -> action program |

Both commands route every value-affecting step through a typed
`Tracer` — `WizardEvent` and `BuildEvent` respectively. See the
[Trust model](trust-model.md) page for the full account of what
flows through each event and what the operator must assert vs. what
the verifier rejects.

[cnc]: https://github.com/lambdasistemi/cardano-node-clients
[recipes]: https://github.com/pragma-org/amaru-treasury/tree/main/journal/2026
