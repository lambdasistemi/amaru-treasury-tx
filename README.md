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
