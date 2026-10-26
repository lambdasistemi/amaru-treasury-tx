# tasks — #522 CLI indexer UTxO source

- [x] T1 — Unit specs: carrier round-trips, provider routing, server
      route, config precedence (INV-1..INV-5).
- [x] T2 — `Backend.Indexer` module and `POST /v1/utxos` (REQ-1, REQ-2).
- [x] T3 — `--indexer-url` / `indexerUrl` / env plumbing and
      `withCliBackend` at every CLI call site (REQ-3..REQ-6, INV-6).
- [x] T4 — Operator docs mention the option.
- [x] T5 — `nix develop --quiet -c just ci` green.
