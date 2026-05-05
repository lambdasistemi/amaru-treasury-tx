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

Recreate the existing mainnet swap golden (matches
`test/fixtures/swap/intent.json`):

```bash
amaru-treasury-tx \
    --node-socket /code/cardano-mainnet/ipc/node.socket \
    --network-magic 764824073 \
    swap-wizard \
    --wallet-addr addr1q802wxt6cg6aw0nl0vdzfxavu65rxu3yzhvgayw7chfxymduzkt66uw9t5kspx5jwjecx80dz4g33htknafhdhkvzd5st4f9xu \
    --registry test/fixtures/swap-wizard/registry.example.json \
    --scope core_development \
    --usdm 100000 \
    --chunk-usdm 3062.5 \
    --min-rate 0.245 \
    --validity-hours 6 \
    --description 'Swapping ADA for $100k at a rate of $0.245 per ADA' \
    --justification 'Required to pay Antithesis as vendor' \
    --destination-label "Network Compliance's treasury" \
    --signer f3ab64b0f97dcf0f91232754603283df5d75a1201337432c04d23e2e \
    --signer 8bd03209d227956aaf9670751e0aa2057b51c1537a43f155b24fb1c1 \
    --out intent.json \
    --verbose --yes
```

`--split N` is the alternative to `--chunk-usdm` if you'd rather
say "split the order into N equal chunks".

The wizard never builds a transaction. Hand the produced
`intent.json` to `amaru-treasury-tx swap` exactly as today.

Full walkthrough:
[specs/002-swap-wizard/quickstart.md](specs/002-swap-wizard/quickstart.md).
CLI contract:
[specs/002-swap-wizard/contracts/swap-wizard-cli.md](specs/002-swap-wizard/contracts/swap-wizard-cli.md).
