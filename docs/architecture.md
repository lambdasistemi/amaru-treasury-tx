# Architecture

`amaru-treasury-tx` is a thin executable on top of the
[`cardano-node-clients`][cnc] `TxBuild` DSL. The
behavioural source of truth is the bash recipe set in
[`pragma-org/amaru-treasury/journal/2026/`][recipes].

## Layered design

```mermaid
flowchart TD
  CLI[app/amaru-treasury-tx/Main.hs<br/><i>impure</i>] --> N2C
  CLI --> Disburse
  CLI --> Reorganize
  CLI --> Withdraw
  Disburse[Tx.Disburse<br/><i>pure TxBuild q e ()</i>] --> Redeemer
  Reorganize[Tx.Reorganize<br/><i>pure</i>] --> Redeemer
  Withdraw[Tx.Withdraw<br/><i>pure</i>] --> Redeemer
  Disburse --> AuxData
  Reorganize --> AuxData
  Withdraw --> AuxData
  CLI --> Metadata
  CLI --> UtxoSelect
  CLI --> Validity
  CLI --> Summary
  N2C[Backend.N2C<br/><i>impure</i>] --> Provider
  Provider[Cardano.Node.Client.Provider<br/><i>record of functions</i>]
```

## Module layout

| Module                          | Role                                                       | Pure? |
| :------------------------------ | :--------------------------------------------------------- | :---: |
| `Amaru.Treasury.Scope`          | Scope identifiers + parsers                                | yes |
| `Amaru.Treasury.Constants`      | USDM policy/asset constants                                | yes |
| `Amaru.Treasury.Metadata`       | Parse `journal/2026/metadata.json`                         | yes |
| `Amaru.Treasury.Redeemer`       | `ToData` for Sundae and permissions redeemers              | yes |
| `Amaru.Treasury.UtxoSelect`     | UTxO selection with blacklist                              | yes |
| `Amaru.Treasury.AuxData`        | Treasury-instance metadata builder                         | yes |
| `Amaru.Treasury.Validity`       | Upper validity bound from wall-clock                       | yes |
| `Amaru.Treasury.Summary`        | Tx summary JSON encoder                                    | yes |
| `Amaru.Treasury.Tx.Disburse`    | `TxBuild q e ()` for `disburse`                            | yes |
| `Amaru.Treasury.Tx.Reorganize`  | `TxBuild q e ()` for `reorganize`                          | yes |
| `Amaru.Treasury.Tx.Withdraw`    | `TxBuild q e ()` for `withdraw`                            | yes |
| `Amaru.Treasury.Backend`        | Alias around `Cardano.Node.Client.Provider`                | yes |
| `Amaru.Treasury.Backend.N2C`    | N2C `Provider` constructor                                 | **no** |
| `app/amaru-treasury-tx/Main.hs` | Optparse parser, backend wiring, output                    | **no** |

[cnc]: https://github.com/lambdasistemi/cardano-node-clients
[recipes]: https://github.com/pragma-org/amaru-treasury/tree/main/journal/2026
