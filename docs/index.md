# amaru-treasury-tx

Build unsigned Conway transactions for the Amaru
treasury contracts: `disburse`, `reorganize`, `withdraw`.

This is a Haskell port of the bash recipes in
[`pragma-org/amaru-treasury/journal/2026/`][recipes],
built on top of the [`cardano-node-clients` `TxBuild`
DSL][txbuild].

## Quick links

- [Architecture overview](architecture.md)
- [Quickstart](quickstart.md)
- [Spec / plan / tasks](https://github.com/lambdasistemi/amaru-treasury-tx/tree/main/specs/001-treasury-tx-cli)
- [Source](https://github.com/lambdasistemi/amaru-treasury-tx)

## Capabilities

| Subcommand   | Purpose                                                |
| :----------- | :----------------------------------------------------- |
| `disburse`   | Pay a vendor in ADA or USDM from a scope's treasury.   |
| `reorganize` | Merge fragmented treasury UTxOs into a single output.  |
| `withdraw`   | Pull rewards from the treasury reward account.         |

## Out of scope

- Signing the unsigned CBOR.
- Submitting the signed transaction.
- Registry/scopes NFT minting.
- Reference-script publishing.
- The Sundae `Fund` redeemer (Amaru disables it).

[recipes]: https://github.com/pragma-org/amaru-treasury/tree/main/journal/2026
[txbuild]: https://github.com/lambdasistemi/cardano-node-clients/blob/main/lib/Cardano/Node/Client/TxBuild.hs
