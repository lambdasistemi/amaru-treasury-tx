# tasks — #522 CLI indexer UTxO source

- [ ] T1 — Unit specs: carrier round-trips, provider routing, server
      route, config precedence (INV-1..INV-5).
- [ ] T2 — `Backend.Indexer` module and `POST /v1/utxos` (REQ-1, REQ-2).
- [ ] T3 — `--indexer-url` / `indexerUrl` / env plumbing and
      `withCliBackend` at every CLI call site (REQ-3..REQ-6, INV-6).
- [ ] T4 — Operator docs mention the option.
- [ ] T5 — `nix develop --quiet -c just ci` green.
