# amaru-treasury-tx

CLI for building unsigned Conway transactions against the Amaru
treasury contracts. The release-facing commands are:

- `swap-wizard` — typed questionnaire that produces an
  `intent.json`, verified end-to-end against a local cardano-node.
- `withdraw-wizard` — resolves treasury reward withdrawals into a
  unified `intent.json`; zero-rewards scopes exit cleanly without
  writing a stale intent.
- `disburse-wizard` — resolves ADA or USDM treasury disbursements
  into a unified `intent.json`; USDM is the default unit because that
  is the common operator path.
- `tx-build` — turns a unified `intent.json` into the unsigned
  Conway CBOR the user signs and submits. Swap, ADA/USDM disburse, and
  withdraw intents are wired; reorganize is parsed but still fails
  closed until its builder ships.

Haskell port of the bash recipes in
[`pragma-org/amaru-treasury/journal/2026/`](https://github.com/pragma-org/amaru-treasury/tree/main/journal/2026),
built on the
[`cardano-node-clients`](https://github.com/lambdasistemi/cardano-node-clients)
`TxBuild` DSL.

## Documentation

The full operator and developer documentation lives at
**<https://lambdasistemi.github.io/amaru-treasury-tx/>**:

- [**Quickstart**](https://lambdasistemi.github.io/amaru-treasury-tx/quickstart/) — wizard-to-`tx-build` pipelines end to end.
- [Architecture](https://lambdasistemi.github.io/amaru-treasury-tx/architecture/) — module layout and data flow.
- [Trust model](https://lambdasistemi.github.io/amaru-treasury-tx/trust-model/) — what the wizard verifies, what the operator must assert.
- [Swap recipe](https://lambdasistemi.github.io/amaru-treasury-tx/swap/) — building a swap from an existing `intent.json`.
- [Disburse](https://lambdasistemi.github.io/amaru-treasury-tx/disburse/) — resolving ADA or USDM disbursements with `disburse-wizard`, or building an existing disburse intent.
- [Withdraw](https://lambdasistemi.github.io/amaru-treasury-tx/withdraw/) — resolving rewards with `withdraw-wizard` or building an existing withdraw intent.
- [Parity report](https://lambdasistemi.github.io/amaru-treasury-tx/parity/) — byte-for-byte golden parity against bash/cardano-cli.

## Install

**macOS (Apple Silicon)**:

```bash
brew tap lambdasistemi/tap
brew install amaru-treasury-tx
```

**Linux (x86_64)** — AppImage / `.deb` / `.rpm` from the
[releases page](https://github.com/lambdasistemi/amaru-treasury-tx/releases/latest):

```bash
curl -L \
  https://github.com/lambdasistemi/amaru-treasury-tx/releases/latest/download/amaru-treasury-tx.AppImage \
  -o amaru-treasury-tx
chmod +x ./amaru-treasury-tx
```

Or run from the flake without installing:

```bash
nix run github:lambdasistemi/amaru-treasury-tx -- --help
```

## Develop

```bash
nix develop
just ci      # build + unit + golden + format + hlint + cabal-check
```

Smoke the release-facing signer path locally with:

```bash
nix develop --quiet -c just smoke
```

## License

Apache-2.0 — see [LICENSE](LICENSE).
