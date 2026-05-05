# amaru-treasury-tx

Build Amaru treasury transactions (disburse, reorganize, withdraw)
using the [`cardano-node-clients`](https://github.com/lambdasistemi/cardano-node-clients)
TxBuild DSL.

Haskell port of the bash recipes in
[`pragma-org/amaru-treasury/journal/2026/`](https://github.com/pragma-org/amaru-treasury/tree/main/journal/2026).

## Install

**macOS (Apple Silicon)**:

```bash
brew tap lambdasistemi/tap
brew install amaru-treasury-tx
```

**Linux (x86_64)** — AppImage from the
[releases page](https://github.com/lambdasistemi/amaru-treasury-tx/releases/latest):

```bash
curl -L \
  https://github.com/lambdasistemi/amaru-treasury-tx/releases/latest/download/amaru-treasury-tx.AppImage \
  -o amaru-treasury-tx
chmod +x ./amaru-treasury-tx
```

`.deb` and `.rpm` packages are attached to the same release.

See the [quickstart](docs/quickstart.md) for usage.

## swap-wizard

A typed questionnaire that produces an `intent.json` for the
existing `swap` subcommand. Resolves treasury / wallet UTxOs and the
current chain tip via a local cardano-node `Provider`; loads
registry refs (deployed-at UTxOs, owner key hashes, scope treasury
addresses) from a JSON file.

```bash
amaru-treasury-tx swap-wizard \
    --node-socket /path/to/node.socket \
    --network-magic 1 \
    --network preprod \
    --wallet-addr addr_test1q... \
    --registry test/fixtures/swap-wizard/registry.example.json \
    --scope core_development \
    --amount-ada 408163265306 \
    --chunk-ada 12500000000 \
    --rate-num 245 --rate-den 1000 \
    --validity-hours 6 \
    --description 'Swapping ADA for USDM' \
    --justification 'Required to pay vendor X' \
    --destination-label 'Network Compliance treasury' \
    --signers f3ab64b0f97dcf0f91232754603283df5d75a1201337432c04d23e2e,8bd03209d227956aaf9670751e0aa2057b51c1537a43f155b24fb1c1 \
    --out intent.json \
    --verbose --yes
```

The wizard never builds a transaction. Hand the produced
`intent.json` to `amaru-treasury-tx swap` exactly as today.

Full walkthrough:
[specs/002-swap-wizard/quickstart.md](specs/002-swap-wizard/quickstart.md).
CLI contract:
[specs/002-swap-wizard/contracts/swap-wizard-cli.md](specs/002-swap-wizard/contracts/swap-wizard-cli.md).
