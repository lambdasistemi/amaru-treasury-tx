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
  withdraw intents are wired; final unsigned transactions are
  phase-1 preflighted against the sampled chain context before CBOR is
  written. Reorganize is parsed but still fails closed until its
  builder ships.
- `swap-cancel` — verifies one explicitly supplied pending SundaeSwap
  V3 order and builds unsigned cancellation CBOR that returns the order
  value to the selected treasury.

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
- [Local devnet smoke](https://lambdasistemi.github.io/amaru-treasury-tx/local-devnet-smoke/) — opt-in `cardano-node-clients` devnet check for live node boundary evidence.
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

Run the opt-in local devnet node smoke with:

```bash
nix develop --quiet -c just devnet-smoke node
```

Run the governance slice boundary check with:

```bash
nix develop --quiet -c just devnet-smoke governance
```

With the current pinned `cardano-node-clients` main commit
`d6773e4cd8a2421617568c8dac0972b0f312a509`, that phase submits the
local treasury-withdrawal governance action, votes it through, and
observes the Amaru treasury script reward account funded. The latest
local evidence for this branch is `runs/devnet/20260513T143827Z`:
reward account `5fbb3e5295c211c7595ddd23db2e0a0833131e0681cc7ea800f85d34`
changed from `0` to `2000000` lovelace. Re-run the smoke before a
release and record the new run directory.

Run the withdrawal slice boundary check with:

```bash
nix develop --quiet -c just devnet-smoke withdraw
```

The withdrawal phase creates fresh local governance prerequisite
evidence, resolves the funded treasury script reward account through
`withdraw-wizard`, builds unsigned withdrawal CBOR and JSON/Markdown
reports through the release-facing `tx-build` path, then signs and
submits the built transaction inside the opt-in DevNet harness to prove
the withdrawn ADA materializes at the treasury script address. The
latest local evidence for this branch is
`runs/devnet/20260515T091231Z`: reward account
`ffbb1bb8f19e6ee2357b899043b7337525c072f968a68c8aaf01b2af`, reward
`2000000` lovelace, tx id
`ff78a866216fbe1b3cb2bf356f3a01cc088ab13260d50fd0b7b4b019b4a3b52d`,
fee `457683` lovelace, validity upper bound slot `222`, submitted tx id
matching the build id, materialized output
`ff78a866216fbe1b3cb2bf356f3a01cc088ab13260d50fd0b7b4b019b4a3b52d#0`,
reward balance `2000000 -> 0` after submit, and treasury ADA
`200000000 -> 202000000`.

Run the disburse slice boundary check with:

```bash
nix develop --quiet -c just devnet-smoke disburse
```

The disburse phase creates fresh governance and withdrawal prerequisite
evidence, resolves live treasury and wallet UTxOs through
`disburse-wizard`, and builds unsigned ADA disburse CBOR plus
JSON/Markdown reports through `tx-build`. Latest local evidence for
this branch is `runs/devnet/20260516T170631Z`: treasury input
`ef153060e68a338350648a04b1e94306b03a02501512e05178b1c9d5cc7e8a46#0`,
unit `ada`, amount `1000000` lovelace, tx id
`75718d7fd814e9067e2715cfc557fde02aa78a30fac3dea382d6f106693b7748`,
fee `632588` lovelace, validity upper bound slot `231`, and
`disburse/usdm-boundary.json` code `missing-usdm-setup`. This is
disburse evidence only; it does not build, fund, submit, or spend a
SundaeSwap order.

Run the swap readiness boundary check with:

```bash
nix develop --quiet -c just devnet-smoke swap-ready
```

The swap readiness phase uses the checked-in public
`SundaeSwap-finance/sundae-contracts@be33466b7dbe0f8e6c0e0f46ff23737897f45835`
`order.spend` artifact, publishes it as a local DevNet reference
script, and writes `swap-ready/registry.json` for the later #84
order-build slice. Latest local evidence for this branch is
`runs/devnet/20260515T124545Z`: script hash
`02eee6c4d128c9700c178922163645f1fdb381bbdce071acbbd49465`,
reference UTxO
`490b9bc8a80e8a55434b895bea6ca47fc612105c0cf71b781a61e99cd2be46af#0`,
and local order address
`addr_test1xqpwaeky6y5vjuqvz7yjy93kghclmvuph0wwqudvh02fgegzamnvf5fge9cqc9ufygtrv303lkecrw7uupc6ew75j3jsdhyjpu`.
This is readiness evidence only; it does not build, fund, submit, or
spend a swap order.

The DevNet release experiment is tracked in slices: governance action
[#82](https://github.com/lambdasistemi/amaru-treasury-tx/issues/82),
withdrawal [#83](https://github.com/lambdasistemi/amaru-treasury-tx/issues/83),
disburse [#86](https://github.com/lambdasistemi/amaru-treasury-tx/issues/86),
SundaeSwap V3 contract readiness
[#132](https://github.com/lambdasistemi/amaru-treasury-tx/issues/132),
SundaeSwap V3 order build/funding
[#84](https://github.com/lambdasistemi/amaru-treasury-tx/issues/84),
and SundaeSwap V3 order spend
[#85](https://github.com/lambdasistemi/amaru-treasury-tx/issues/85),
then reorganize
[#87](https://github.com/lambdasistemi/amaru-treasury-tx/issues/87).

## License

Apache-2.0 — see [LICENSE](LICENSE).
