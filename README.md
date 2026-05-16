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

Run the shipped DevNet registry/reference-script initiator command
against a running local DevNet with:

```bash
amaru-treasury-tx --network devnet --node-socket "$CARDANO_NODE_SOCKET_PATH" \
  devnet registry-init \
  --funding-address "$DEVNET_FUNDING_ADDRESS" \
  --signing-key-file "$DEVNET_PAYMENT_SKEY" \
  --run-dir runs/devnet/manual-registry-init
```

Run the matching live proof harness with:

```bash
nix develop --quiet -c just devnet-smoke registry-init
```

The registry-init command publishes local seed-derived scopes and
registry NFTs plus permissions and treasury reference scripts through
production-backed code, then verifies the expected UTxOs on the local
DevNet and writes `registry-init/summary.json`,
`registry-init/registry.json`, and `registry-init/provenance.json`. The
latest local evidence for this branch is
`runs/devnet/20260516T193404Z`: seed split tx
`82b1f12f0ceeae86c50753a61528599c4d7b8ccef769a56accd3011c0e24084d`,
registry mint tx
`1f427e73979ee6150e69944fb384cbe0809148e64307a2a75221bacea8cb4ff9`,
reference-script tx
`5c3227fe8511632669b5383246e7ff92ccc2add2988ee90ac1a24ecda6a10a44`,
scopes anchor
`1f427e73979ee6150e69944fb384cbe0809148e64307a2a75221bacea8cb4ff9#0`,
registry anchor
`1f427e73979ee6150e69944fb384cbe0809148e64307a2a75221bacea8cb4ff9#1`,
permissions reference
`5c3227fe8511632669b5383246e7ff92ccc2add2988ee90ac1a24ecda6a10a44#0`,
and treasury reference
`5c3227fe8511632669b5383246e7ff92ccc2add2988ee90ac1a24ecda6a10a44#1`.
This is registry/reference-script publication evidence only; staking,
reward setup, governance funding, treasury withdrawal setup, and
disburse submission remain separate recovery slices.

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

The DevNet release experiment is tracked in slices. The current
bootstrap initiator recovery is orchestrated by
[#151](https://github.com/lambdasistemi/amaru-treasury-tx/issues/151):
registry/reference-script publication
[#147](https://github.com/lambdasistemi/amaru-treasury-tx/issues/147),
staking and reward-account setup
[#148](https://github.com/lambdasistemi/amaru-treasury-tx/issues/148),
governance funding and treasury withdrawal setup
[#149](https://github.com/lambdasistemi/amaru-treasury-tx/issues/149),
and disburse action/beneficiary receipt
[#150](https://github.com/lambdasistemi/amaru-treasury-tx/issues/150).
Older evidence slices remain tracked as governance action
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
