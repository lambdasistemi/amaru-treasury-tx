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
This is registry/reference-script publication evidence only; staking
and reward setup, governance funding, treasury withdrawal setup, and
disburse submission remain separate recovery slices.

Run the shipped DevNet stake/reward setup command against a running
local DevNet after registry-init with:

```bash
amaru-treasury-tx --network devnet --node-socket "$CARDANO_NODE_SOCKET_PATH" \
  devnet stake-reward-init \
  --registry-file runs/devnet/manual-registry-init/registry-init/registry.json \
  --funding-address "$DEVNET_FUNDING_ADDRESS" \
  --signing-key-file "$DEVNET_PAYMENT_SKEY" \
  --run-dir runs/devnet/manual-stake-reward-init
```

Run the matching live proof harness with:

```bash
nix develop --quiet -c just devnet-smoke stake-reward-init
```

The stake-reward-init command registers the DevNet treasury script
reward account, verifies the registry handoff, and registers the
permissions reward account so later withdraw-zero permission checks are
accepted by the ledger. The permissions validator is still invoked by
later disburse/swap transactions through the withdraw-zero pattern, not
as a certificate-purpose validator. It writes
`stake-reward-init/summary.json`, `stake-reward-init/accounts.json`,
and `stake-reward-init/provenance.json`. The latest local evidence for
this branch is `runs/devnet/20260517T005034Z`: setup tx
`527c1b08fdfd1c41fe1237d4d5f1bc3572dee98a81b76b62257c958e50dc9cc8`,
treasury reward account
`b2b7201c62e43ae8e03b61c96931379ebbcdce61befc3f4e4b1f4be4`
registered on `Testnet`, and permissions reward account
`f9dc1d931a3f52eaf83891f8621cbba5ba64f6faa5792f1b00c17333`
registered on `Testnet` for later withdraw-zero witnesses. This slice
does not submit governance funding, treasury withdrawal
materialization, or disburse transactions; those are recorded by the
#149 and #150 command-proof slices.

Run the shipped DevNet governance/withdrawal setup command after
registry-init and stake-reward-init with:

```bash
amaru-treasury-tx --network devnet --node-socket "$CARDANO_NODE_SOCKET_PATH" \
  devnet governance-withdrawal-init \
  --registry-file runs/devnet/manual-registry-init/registry-init/registry.json \
  --stake-reward-file runs/devnet/manual-stake-reward-init/stake-reward-init/accounts.json \
  --funding-address "$DEVNET_FUNDING_ADDRESS" \
  --signing-key-file "$DEVNET_PAYMENT_SKEY" \
  --run-dir runs/devnet/manual-governance-withdrawal-init
```

Run the matching live proof harness with:

```bash
nix develop --quiet -c just devnet-smoke governance-withdrawal-init
```

The command consumes #147 registry artifacts and #148 stake/reward
artifacts, submits and votes through the Conway treasury-withdrawal
governance action, waits for the treasury reward account to fund, builds
the withdrawal through the production withdraw/tx-build path, signs and
submits it, and writes
`governance-withdrawal-init/materialized.json` for the #150 handoff. The
latest local evidence for this branch is
`runs/devnet/20260516T231003Z`: proposal tx
`baffa774b368b1da8c3ff80be399bcf6fa63b5cff658b6889fc00109da218e23`,
governance action
`baffa774b368b1da8c3ff80be399bcf6fa63b5cff658b6889fc00109da218e23#0`,
vote tx
`009801303fc5cc3c3dfe474c30cc4b7d31e99b5af29467cc317072ea6b728c45`,
treasury reward account
`b2b7201c62e43ae8e03b61c96931379ebbcdce61befc3f4e4b1f4be4`, reward
`0 -> 2000000 -> 0` lovelace, withdrawal tx
`4a87409b52b8104d51d41df7ee562196cf33621f64c4c40985b4aef5ff21e9bd`,
fee `456417` lovelace, materialized output
`4a87409b52b8104d51d41df7ee562196cf33621f64c4c40985b4aef5ff21e9bd#0`,
and treasury ADA `200000000 -> 202000000`. The legacy
`just devnet-smoke withdraw` phase is a compatibility alias for the same
production command proof.

Run the shipped DevNet disburse submit command after registry-init and
governance-withdrawal-init with:

```bash
amaru-treasury-tx --network devnet --node-socket "$CARDANO_NODE_SOCKET_PATH" \
  devnet disburse-submit \
  --registry-file runs/devnet/manual-registry-init/registry-init/registry.json \
  --materialized-file runs/devnet/manual-governance-withdrawal-init/governance-withdrawal-init/materialized.json \
  --funding-address "$DEVNET_FUNDING_ADDRESS" \
  --signing-key-file "$DEVNET_PAYMENT_SKEY" \
  --beneficiary-address "$DEVNET_BENEFICIARY_ADDRESS" \
  --run-dir runs/devnet/manual-disburse-submit \
  --amount-lovelace 1000000
```

Run the matching live proof harness with:

```bash
nix develop --quiet -c just devnet-smoke disburse-submit
```

The command consumes #147 registry artifacts and the #149 materialized
treasury UTxO handoff, builds through the production disburse/tx-build
path, signs and submits the transaction, then verifies beneficiary
receipt and the reduced treasury output. The latest local evidence for
this branch is `runs/devnet/20260517T005034Z`: submitted disburse tx
`0008ab902b2f835624f453af0467d826b02519d7139ec8e84a04c8a9c000011b`,
beneficiary output
`0008ab902b2f835624f453af0467d826b02519d7139ec8e84a04c8a9c000011b#1`
with `1000000` lovelace, treasury input
`309e28ed5b95de38258bcc130d6390800b0719f6410b0d5fe6f3c33cc1b70817#0`,
and treasury lovelace `2000000 -> 1000000`.

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
