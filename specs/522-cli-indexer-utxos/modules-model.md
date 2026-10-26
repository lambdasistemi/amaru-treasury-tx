# modules model — #522

| ID | Module | Change |
|---|---|---|
| M1 | `Amaru.Treasury.Backend.Indexer` (new) | D1–D4, F1–F4. |
| M2 | `Amaru.Treasury.Api.Server` | `POST /v1/utxos` route and `hUtxos` handler field. |
| M3 | `app/amaru-treasury-tx-api/Main.hs` | `hUtxos` over the indexer-backed read provider. |
| M4 | `Amaru.Treasury.Config.*`, `Amaru.Treasury.Cli.Config`, `Amaru.Treasury.Cli.Common` | D5 plumbing, `--indexer-url`, F5. |
| M5 | CLI command modules | `withLocalNodeBackend (goNetworkMagic g) socket (goMinimumSeverity g)` → `withCliBackend g socket`. |

Dependency direction: `Cli.Common` → `Backend.Indexer` → `Backend`;
`Api.Server` → `Backend.Indexer`.
