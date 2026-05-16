# Local DevNet Smoke

The local DevNet smoke is an opt-in release check. It starts the
`cardano-node-clients` DevNet, verifies the node socket with network
magic `42`, can publish registry/reference-script bootstrap state, can
register the treasury reward account and emit the permissions
withdraw-zero reward account, and proves the shipped
`devnet governance-withdrawal-init` command on a patched short-epoch
genesis. The command proof records governance proposal/vote evidence,
reward funding, withdrawal build/submission, and the treasury UTxO that
materialized from the reward account. The swap readiness phase publishes
the public SundaeSwap V3 order validator as a local DevNet reference
script and writes handoff metadata for the later order-build slice.

This check is not part of `just ci`: it starts a real local
`cardano-node` and is meant as manual live evidence before a release.

## Prerequisites

Run it from the repository dev shell:

```bash
nix develop --quiet
```

The dev shell provides:

- `cardano-node` from the Cardano node flake input;
- `E2E_GENESIS_DIR`, pointing at the pinned
  `cardano-node-clients` DevNet genesis;
- the Cabal dependencies for `cardano-node-clients:devnet`.

## Node Boundary

```bash
just devnet-smoke node
```

Expected output:

```text
devnet-smoke: run-dir runs/devnet/YYYYMMDDTHHMMSSZ
devnet-smoke: network devnet magic 42
devnet-smoke: epoch-duration 50.0
devnet-smoke: socket /tmp/.../cardano-e2e/node.sock
devnet-smoke: phase node passed
```

The smoke writes:

```text
runs/devnet/YYYYMMDDTHHMMSSZ/
|-- node.log
|-- summary.json
|-- summary.log
`-- timing.json
```

`timing.json` records the pinned genesis values:

- `epochLength`: `500`
- `slotLengthSeconds`: `0.1`
- `epochDurationSeconds`: `50`
- `networkMagic`: `42`

## Registry Initiator Boundary

The shipped command for this boundary is:

```bash
amaru-treasury-tx --network devnet --node-socket "$CARDANO_NODE_SOCKET_PATH" \
  devnet registry-init \
  --funding-address "$DEVNET_FUNDING_ADDRESS" \
  --signing-key-file "$DEVNET_PAYMENT_SKEY" \
  --run-dir runs/devnet/manual-registry-init
```

The local smoke runs the same command runner against the
`cardano-node-clients` DevNet:

```bash
just devnet-smoke registry-init
```

Expected output:

```text
registry-init: run-dir runs/devnet/YYYYMMDDTHHMMSSZ
registry-init: network devnet magic 42
registry-init: phase registry-init passed
registry-init: seed-split-tx-id 82b1...
registry-init: registry-mint-tx-id 1f42...
registry-init: reference-scripts-tx-id 5c32...
registry-init: summary runs/devnet/YYYYMMDDTHHMMSSZ/registry-init/summary.json
registry-init: registry runs/devnet/YYYYMMDDTHHMMSSZ/registry-init/registry.json
```

The registry-init command invokes the production-backed registry
initiator, publishes local seed-derived scopes and registry NFTs,
publishes permissions and treasury reference scripts, then verifies the
expected registry/reference-script UTxOs through the local provider
before reporting success. The smoke layer owns DevNet setup and proof;
reusable registry transaction construction lives in production code.

The verified 2026-05-16 slice used run directory
`runs/devnet/20260516T193404Z`. It submitted seed split tx
`82b1f12f0ceeae86c50753a61528599c4d7b8ccef769a56accd3011c0e24084d`,
registry mint tx
`1f427e73979ee6150e69944fb384cbe0809148e64307a2a75221bacea8cb4ff9`,
and reference-script tx
`5c3227fe8511632669b5383246e7ff92ccc2add2988ee90ac1a24ecda6a10a44`.
It observed scopes
`1f427e73979ee6150e69944fb384cbe0809148e64307a2a75221bacea8cb4ff9#0`,
registry
`1f427e73979ee6150e69944fb384cbe0809148e64307a2a75221bacea8cb4ff9#1`,
permissions reference
`5c3227fe8511632669b5383246e7ff92ccc2add2988ee90ac1a24ecda6a10a44#0`,
and treasury reference
`5c3227fe8511632669b5383246e7ff92ccc2add2988ee90ac1a24ecda6a10a44#1`.

The registry-init command writes:

```text
runs/devnet/YYYYMMDDTHHMMSSZ/
|-- node.log
|-- summary.json
|-- summary.log
|-- timing.json
`-- registry-init/
    |-- provenance.json
    |-- registry.json
    `-- summary.json
```

This is registry/reference-script publication evidence only. It does
not prove staking setup, reward-account funding, treasury withdrawal
materialization, disburse submission, swap execution, or reorganize.

## Stake/Reward Initiator Boundary

The shipped command for this boundary is:

```bash
amaru-treasury-tx --network devnet --node-socket "$CARDANO_NODE_SOCKET_PATH" \
  devnet stake-reward-init \
  --registry-file runs/devnet/manual-registry-init/registry-init/registry.json \
  --funding-address "$DEVNET_FUNDING_ADDRESS" \
  --signing-key-file "$DEVNET_PAYMENT_SKEY" \
  --run-dir runs/devnet/manual-stake-reward-init
```

The local smoke runs registry-init first in the same fresh run, then
invokes the same production command runner:

```bash
just devnet-smoke stake-reward-init
```

Expected output:

```text
stake-reward-init: run-dir runs/devnet/YYYYMMDDTHHMMSSZ
stake-reward-init: network devnet magic 42
stake-reward-init: phase stake-reward-init passed
stake-reward-init: setup-tx-id 8973...
stake-reward-init: treasury-reward-account b2b7...
stake-reward-init: permissions-reward-account f9dc...
stake-reward-init: summary runs/devnet/YYYYMMDDTHHMMSSZ/stake-reward-init/summary.json
stake-reward-init: accounts runs/devnet/YYYYMMDDTHHMMSSZ/stake-reward-init/accounts.json
```

The stake-reward-init command registers only the treasury script reward
account. The permissions script is not a certificate-purpose validator;
it is invoked later by disburse/swap transactions through the
withdraw-zero pattern. The command still emits the permissions reward
account because later transactions need that script hash as their
withdraw-zero target.

The verified 2026-05-16 slice used run directory
`runs/devnet/20260516T213258Z`. It submitted setup tx
`89737f7b4439008d5aeca01789addbbbfeb2876cb4a0fab224f1c545e4076598`,
reported treasury reward account
`b2b7201c62e43ae8e03b61c96931379ebbcdce61befc3f4e4b1f4be4` as
`registered: true`, and reported permissions reward account
`f9dc1d931a3f52eaf83891f8621cbba5ba64f6faa5792f1b00c17333` as
`registered: false`, both on ledger network `Testnet`.

The stake-reward-init command writes:

```text
runs/devnet/YYYYMMDDTHHMMSSZ/
|-- node.log
|-- summary.json
|-- summary.log
|-- timing.json
|-- registry-init/
|   |-- provenance.json
|   |-- registry.json
|   `-- summary.json
`-- stake-reward-init/
    |-- accounts.json
    |-- provenance.json
    `-- summary.json
```

This is stake/reward prerequisite evidence only. It does not submit
governance funding, treasury withdrawal materialization, disburse
submission, swap execution, or reorganize transactions.

## Governance Withdrawal Init Boundary

The shipped command for this boundary is:

```bash
amaru-treasury-tx --network devnet --node-socket "$CARDANO_NODE_SOCKET_PATH" \
  devnet governance-withdrawal-init \
  --registry-file runs/devnet/manual-registry-init/registry-init/registry.json \
  --stake-reward-file runs/devnet/manual-stake-reward-init/stake-reward-init/accounts.json \
  --funding-address "$DEVNET_FUNDING_ADDRESS" \
  --signing-key-file "$DEVNET_PAYMENT_SKEY" \
  --run-dir runs/devnet/manual-governance-withdrawal-init
```

The live proof harness runs the prerequisite commands and then invokes
the same production command runner:

```bash
just devnet-smoke governance-withdrawal-init
```

Expected command-prefixed output:

```text
governance-withdrawal-init: run-dir runs/devnet/YYYYMMDDTHHMMSSZ
governance-withdrawal-init: network devnet magic 42
governance-withdrawal-init: phase governance-withdrawal-init passed
governance-withdrawal-init: governance-proposal-tx-id <tx-id>
governance-withdrawal-init: governance-action-id <tx-id>#0
governance-withdrawal-init: vote-tx-id <tx-id>
governance-withdrawal-init: treasury-reward-account <script-hash>
governance-withdrawal-init: reward-before-lovelace 0
governance-withdrawal-init: reward-after-governance-lovelace 2000000
governance-withdrawal-init: withdraw-tx-id <tx-id>
governance-withdrawal-init: withdraw-submitted-tx-id <tx-id>
governance-withdrawal-init: treasury-materialized-tx-in <tx-id>#0
governance-withdrawal-init: treasury-materialized-ada 2000000
governance-withdrawal-init: summary runs/devnet/YYYYMMDDTHHMMSSZ/governance-withdrawal-init/summary.json
governance-withdrawal-init: materialization runs/devnet/YYYYMMDDTHHMMSSZ/governance-withdrawal-init/materialized.json
```

The proof copies and patches the DevNet genesis to a short epoch, runs
`devnet registry-init`, runs `devnet stake-reward-init`, then calls
`devnet governance-withdrawal-init`. Production code owns the Conway
treasury-withdrawal proposal, vote, reward wait, withdrawal intent,
tx-build, signing, submission, and materialization verification. The
smoke layer only prepares the local node/prerequisites and asserts the
observed artifacts and chain effects.

The verified 2026-05-16 slice used run directory
`runs/devnet/20260516T231003Z`. It submitted proposal tx
`baffa774b368b1da8c3ff80be399bcf6fa63b5cff658b6889fc00109da218e23`
with action id
`baffa774b368b1da8c3ff80be399bcf6fa63b5cff658b6889fc00109da218e23#0`,
vote tx
`009801303fc5cc3c3dfe474c30cc4b7d31e99b5af29467cc317072ea6b728c45`,
reward account
`b2b7201c62e43ae8e03b61c96931379ebbcdce61befc3f4e4b1f4be4`, and
withdrawal tx
`4a87409b52b8104d51d41df7ee562196cf33621f64c4c40985b4aef5ff21e9bd`
with fee `456417` lovelace. The materialized output was
`4a87409b52b8104d51d41df7ee562196cf33621f64c4c40985b4aef5ff21e9bd#0`
with `2000000` lovelace at
`addr_test1xzetwgquvtjr468q8dsuj6f3x70thnwwvxl0c06wfv05he9jkuspcchy8t5wqwmpe95nzdu7h0xuucd7lsl5ujclf0jqnpvejf`.
The reward account moved `0 -> 2000000 -> 0`, and treasury ADA moved
`200000000 -> 202000000`.

The command proof writes:

```text
runs/devnet/YYYYMMDDTHHMMSSZ/
|-- node.log
|-- summary.log
|-- timing.json
|-- registry-init/
|   |-- provenance.json
|   |-- registry.json
|   `-- summary.json
|-- stake-reward-init/
|   |-- accounts.json
|   |-- provenance.json
|   `-- summary.json
`-- governance-withdrawal-init/
    |-- governance.json
    |-- intent.json
    |-- materialized.json
    |-- provenance.json
    |-- report.json
    |-- report.md
    |-- signed-tx.cbor.hex
    |-- submit.log
    |-- summary.json
    |-- tx-body.cbor.hex
    |-- tx-build.log
    `-- withdrawal.json
```

`just devnet-smoke withdraw` remains accepted as a compatibility alias
for this same production command proof. It is not a separate
smoke-owned withdrawal implementation.

## Swap Readiness Boundary

```bash
just devnet-smoke swap-ready
```

Expected output:

```text
devnet-smoke: run-dir runs/devnet/YYYYMMDDTHHMMSSZ
devnet-smoke: phase swap-ready passed
devnet-smoke: swap-ready-order-script-hash 02eee6c4d128c9700c178922163645f1fdb381bbdce071acbbd49465
devnet-smoke: swap-ready-order-script-ref 490b...#0
devnet-smoke: swap-ready-order-address addr_test1...
devnet-smoke: swap-ready-registry runs/devnet/YYYYMMDDTHHMMSSZ/swap-ready/registry.json
```

The readiness phase uses the checked-in public
`SundaeSwap-finance/sundae-contracts@be33466b7dbe0f8e6c0e0f46ff23737897f45835`
`order.spend` artifact. It hashes the artifact locally, publishes it as
a reference script on the local DevNet, waits for the reference UTxO,
and verifies that the observed reference script hash matches the pinned
artifact hash. It does not build, fund, submit, or spend a swap order.

The verified 2026-05-15 slice used run directory
`runs/devnet/20260515T124545Z`. It published order reference
`490b9bc8a80e8a55434b895bea6ca47fc612105c0cf71b781a61e99cd2be46af#0`
with script hash
`02eee6c4d128c9700c178922163645f1fdb381bbdce071acbbd49465` at local
DevNet order address
`addr_test1xqpwaeky6y5vjuqvz7yjy93kghclmvuph0wwqudvh02fgegzamnvf5fge9cqc9ufygtrv303lkecrw7uupc6ew75j3jsdhyjpu`.

The swap readiness phase writes:

```text
runs/devnet/YYYYMMDDTHHMMSSZ/
|-- node.log
|-- summary.json
|-- summary.log
|-- timing.json
`-- swap-ready/
    |-- provenance.json
    |-- registry.json
    `-- summary.json
```

## DevNet Experiment Order

The original DevNet release experiment is now being recovered through
the bootstrap initiator parent ticket
[#151](https://github.com/lambdasistemi/amaru-treasury-tx/issues/151).
The recovery child tickets run in this order:

- [#147](https://github.com/lambdasistemi/amaru-treasury-tx/issues/147):
  registry/reference-script publication from production-backed code.
- [#148](https://github.com/lambdasistemi/amaru-treasury-tx/issues/148):
  required staking and reward-account setup.
- [#149](https://github.com/lambdasistemi/amaru-treasury-tx/issues/149):
  governance funding and treasury withdrawal setup.
- [#150](https://github.com/lambdasistemi/amaru-treasury-tx/issues/150):
  disburse action submission and beneficiary receipt verification.

The prior experiment is split into seven tickets:

- [#82](https://github.com/lambdasistemi/amaru-treasury-tx/issues/82):
  governance action slice. This prepares and submits the local Conway
  treasury-withdrawal governance action that funds an Amaru script
  reward account.
- [#83](https://github.com/lambdasistemi/amaru-treasury-tx/issues/83):
  withdrawal slice. This consumes the funded reward account with
  `withdraw-wizard` and `tx-build`.
- [#86](https://github.com/lambdasistemi/amaru-treasury-tx/issues/86):
  disburse slice. This exercises `disburse-wizard` and `tx-build`
  against live treasury UTxOs, with USDM as the common operator path
  and ADA as an explicit covered variant.
- [#132](https://github.com/lambdasistemi/amaru-treasury-tx/issues/132):
  SundaeSwap V3 contract readiness slice. This publishes the public
  V3 `order.spend` validator as a local DevNet reference script and
  writes the readiness registry consumed by #84.
- [#84](https://github.com/lambdasistemi/amaru-treasury-tx/issues/84):
  SundaeSwap V3 order build/funding slice. This brings the current
  swap path up to live DevNet evidence against the readiness registry
  and the open-source SundaeSwap V3 order interface.
- [#85](https://github.com/lambdasistemi/amaru-treasury-tx/issues/85):
  SundaeSwap V3 order spend slice. This consumes the funded order
  under the real V3 contract rules on local DevNet.
- [#87](https://github.com/lambdasistemi/amaru-treasury-tx/issues/87):
  reorganize slice. This consolidates live treasury UTxOs once the
  release-facing reorganize builder from #46 exists.

The passing phases today are `node`, `registry-init`,
`stake-reward-init`, `governance`, `governance-withdrawal-init`,
`withdraw`, and `swap-ready`. `just devnet-smoke all` runs `node`,
`governance`, and `governance-withdrawal-init` into separate
subdirectories under one timestamped run directory.

`node` proves only the local node boundary, network magic, and timing.
`registry-init` proves only production-backed registry/reference-script
publication and artifact handoff.
`stake-reward-init` proves only treasury reward-account registration
and permissions withdraw-zero account handoff.
`governance` remains a governance-only boundary for the local funding
mechanics. `governance-withdrawal-init` is the #149 command proof: it
consumes registry-init and stake-reward-init artifacts, runs the shipped
production command runner, and observes ADA materialized at the treasury
script address. `withdraw` is a compatibility alias for
`governance-withdrawal-init`. It is not proof that disburse, SundaeSwap
order-build, SundaeSwap order-spend, or reorganize transactions have
been built or observed on DevNet.
`swap-ready` proves only that the public V3 order-validator reference is
available on the local DevNet and recorded in machine-readable metadata
for #84.

SundaeSwap V3 contract compatibility should use the public V3 Aiken
contracts and SDK/reference material:

- [SundaeSwap V3 contracts](https://github.com/SundaeSwap-finance/sundae-contracts)
- [SundaeSwap SDK](https://github.com/SundaeSwap-finance/sundae-sdk)

A local toy swap validator is acceptable only as an explicitly named
fixture boundary. It is not SundaeSwap compatibility evidence.

## Governance Funding Model

The withdrawal path needs funds in the treasury script reward account.
On a local Conway DevNet, that means the setup must use protocol
treasury state and a treasury-withdrawal governance action targeting
the Amaru script stake credential.

A delegated key reward account is not accepted as Amaru withdrawal
evidence because the production withdrawal transaction uses the script
credential as the `Rewarding` witness. The governance setup must also
match the original Amaru registration shape: registration plus
always-abstain vote delegation.

Required upstream library support was originally tracked in:

- [cardano-node-clients#130](https://github.com/lambdasistemi/cardano-node-clients/issues/130)
- [cardano-node-clients#131](https://github.com/lambdasistemi/cardano-node-clients/issues/131)

The downstream proof now consumes `cardano-node-clients` main after the
upstream PR stack merged:

- [cardano-node-clients#135](https://github.com/lambdasistemi/cardano-node-clients/pull/135)
- [cardano-node-clients#137](https://github.com/lambdasistemi/cardano-node-clients/pull/137)
- [cardano-node-clients#132](https://github.com/lambdasistemi/cardano-node-clients/pull/132)

The pinned upstream commit is
`d6773e4cd8a2421617568c8dac0972b0f312a509`.

## Failure Shape

The node phase fails before any treasury action if:

- `cardano-node` is not on `PATH`;
- `E2E_GENESIS_DIR` does not point at a
  `cardano-node-clients` genesis directory;
- the run directory already contains artifacts;
- the socket does not accept DevNet magic `42`;
- the effective epoch duration is not short enough for manual
  governance/reward testing.

The governance-only phase may still fail with a typed upstream or local
boundary if the pinned `cardano-node-clients` main commit moves, the
genesis patch no longer applies, funds are insufficient, the action is
not observed, or the reward account is not funded before the wait
budget expires.

The governance-withdrawal-init phase may fail during prerequisite
setup, governance proposal/vote, reward wait, withdrawal intent
creation, `tx-build`, submission, or materialization. When diagnosing
`tx-build`, inspect
`governance-withdrawal-init/tx-build.log`,
`governance-withdrawal-init/report.json`, and the run directory's node
log together. When diagnosing submission or materialization, inspect
`governance-withdrawal-init/signed-tx.cbor.hex`,
`governance-withdrawal-init/submit.log`,
`governance-withdrawal-init/materialized.json`, and the node log.

The swap readiness phase may fail during artifact hashing, reference
script publication, reference UTxO lookup, or observed reference-script
hash verification. Inspect `swap-ready/registry.json`,
`swap-ready/summary.json`, `swap-ready/provenance.json`, `summary.log`,
and the node log together.

Use the run directory's `node.log`, `summary.log`, `timing.json`, and
`governance/summary.json` when recording legacy governance-only
evidence. Use `registry-init/registry.json`,
`stake-reward-init/accounts.json`,
`governance-withdrawal-init/governance.json`,
`governance-withdrawal-init/withdrawal.json`, and
`governance-withdrawal-init/materialized.json` when recording #149
command evidence. Use `swap-ready/registry.json`,
`swap-ready/summary.json`, and `swap-ready/provenance.json` when
recording swap readiness evidence.
