# Local DevNet Smoke

The local DevNet smoke is an opt-in release check. It starts the
`cardano-node-clients` DevNet, verifies the node socket with network
magic `42`, can publish registry/reference-script bootstrap state,
can run the governance funding setup on a patched short-epoch genesis,
records timing/action/reward evidence, and writes artifacts under a
fresh run directory. The withdrawal phase proves the live
reward-to-materialized-ADA boundary by writing a withdrawal intent,
building unsigned CBOR, signing and submitting it inside the opt-in
DevNet harness, and recording the treasury UTxO that materialized from
the reward account. The swap readiness phase publishes the public
SundaeSwap V3 order validator as a local DevNet reference script and
writes handoff metadata for the later order-build slice.

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

## Governance Boundary

```bash
just devnet-smoke governance
```

Expected output:

```text
devnet-smoke: run-dir runs/devnet/YYYYMMDDTHHMMSSZ
devnet-smoke: network devnet magic 42
devnet-smoke: epoch-duration 5.0
devnet-smoke: socket /tmp/.../cardano-e2e/node.sock
devnet-smoke: phase governance passed
devnet-smoke: governance-tx-id TxId {...}
devnet-smoke: governance-action-id GovActionId {...}
devnet-smoke: reward-account 5fbb3e5295c211c7595ddd23db2e0a0833131e0681cc7ea800f85d34
devnet-smoke: governance-amount 2000000
devnet-smoke: governance-summary runs/devnet/YYYYMMDDTHHMMSSZ/governance/summary.json
```

The governance smoke copies the pinned DevNet genesis into the run
directory, patches it to a 5-second epoch for manual reward testing,
registers the Amaru treasury script stake credential with the
registration-plus-always-abstain certificate shape, submits a Conway
treasury-withdrawal governance action, votes it through, waits for the
next epoch, and observes the script reward account through
`Provider.queryRewardAccounts`.

The latest local evidence for this branch is
`runs/devnet/20260513T143827Z`, using `cardano-node-clients` main
commit `d6773e4cd8a2421617568c8dac0972b0f312a509`. It funded the script
reward account from `0` to `2000000` lovelace across epochs `2 -> 4`.

The governance phase writes:

```text
runs/devnet/YYYYMMDDTHHMMSSZ/
|-- node.log
|-- summary.json
|-- summary.log
|-- timing.json
`-- governance/
    |-- action.json
    |-- certificates.json
    |-- genesis/
    `-- summary.json
```

## Withdrawal Boundary

```bash
just devnet-smoke withdraw
```

Expected output:

```text
devnet-smoke: run-dir runs/devnet/YYYYMMDDTHHMMSSZ
devnet-smoke: phase withdraw intent-ready
devnet-smoke: reward-account 5da22e...
devnet-smoke: withdraw-rewards 2000000
devnet-smoke: withdraw-intent runs/devnet/YYYYMMDDTHHMMSSZ/withdraw/intent.json
devnet-smoke: phase withdraw passed
devnet-smoke: withdraw-tx-id 5fd2...
devnet-smoke: withdraw-fee 469749
devnet-smoke: withdraw-tx-body runs/devnet/YYYYMMDDTHHMMSSZ/withdraw/tx-body.cbor.hex
devnet-smoke: withdraw-report-json runs/devnet/YYYYMMDDTHHMMSSZ/withdraw/report.json
devnet-smoke: withdraw-report-md runs/devnet/YYYYMMDDTHHMMSSZ/withdraw/report.md
devnet-smoke: withdraw-signed-tx runs/devnet/YYYYMMDDTHHMMSSZ/withdraw/signed-tx.cbor.hex
devnet-smoke: withdraw-submitted-tx-id 5fd2...
devnet-smoke: withdraw-materialized-tx-in 5fd2...#0
devnet-smoke: withdraw-materialized-ada 2000000
devnet-smoke: withdraw-reward-after-submit 0
devnet-smoke: withdraw-materialization runs/devnet/YYYYMMDDTHHMMSSZ/withdraw/materialized.json
```

The smoke copies and patches the DevNet genesis to a short epoch,
deploys local seed-derived scopes and registry policy scripts, publishes local
permissions and treasury reference scripts, funds the local treasury
script reward account through a Conway treasury-withdrawal governance
action, observes the reward through the provider, and writes the
schema-v1 withdrawal intent. It then runs the release-facing
`tx-build` path against the live node, using a short DevNet validity
horizon so script evaluation stays inside the hard-fork forecast
window. After the build evidence is written, the smoke signs the
withdrawal transaction with the local DevNet wallet key, submits it via
`cardano-node-clients`, waits for output `#0` to appear at the treasury
script address, and verifies that the reward account has drained to
zero and the treasury UTxO ADA total increased by the withdrawn amount.

The verified 2026-05-15 slice used run directory
`runs/devnet/20260515T091231Z`. It wrote `withdraw/intent.json` with
reward account
`ffbb1bb8f19e6ee2357b899043b7337525c072f968a68c8aaf01b2af` and
`rewardsLovelace = 2000000`, built tx id
`ff78a866216fbe1b3cb2bf356f3a01cc088ab13260d50fd0b7b4b019b4a3b52d`
with fee `457683` lovelace and validity upper bound slot `222`, signed
and submitted the same tx id, observed materialized output
`ff78a866216fbe1b3cb2bf356f3a01cc088ab13260d50fd0b7b4b019b4a3b52d#0`
with `2000000` lovelace at the treasury script address, and confirmed
the reward account moved from `2000000` to `0` lovelace after submit
while treasury ADA moved from `200000000` to `202000000`.

The withdrawal phase writes:

```text
runs/devnet/YYYYMMDDTHHMMSSZ/
|-- node.log
|-- summary.json
|-- summary.log
|-- timing.json
|-- governance/
|   |-- action.json
|   |-- certificates.json
|   |-- genesis/
|   `-- summary.json
`-- withdraw/
    |-- governance-prerequisite.json
    |-- intent.json
    |-- registry.json
    |-- report.json
    |-- report.md
    |-- signed-tx.cbor.hex
    |-- submit.log
    |-- materialized.json
    |-- tx-body.cbor.hex
    |-- tx-build.log
    `-- summary.json
```

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

The passing phases today are `node`, `registry-init`, `governance`,
`withdraw`, and `swap-ready`. `just devnet-smoke all` still runs only `node`,
`governance`, and `withdraw` into separate
subdirectories under one timestamped run directory.

`node` proves only the local node boundary, network magic, and timing.
`registry-init` proves only production-backed registry/reference-script
publication and artifact handoff.
`governance` proves the local setup path that funds the Amaru treasury
script reward account. `withdraw` proves that the funded script reward
account can be resolved into a schema-v1 intent, built into unsigned
CBOR plus review reports, signed and submitted by the DevNet harness,
and observed as ADA materialized at the treasury script address. It is
not proof that disburse, SundaeSwap order-build, SundaeSwap order-spend,
or reorganize transactions have been built or observed on DevNet.
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

The governance phase may still fail with a typed upstream or local
boundary if the pinned `cardano-node-clients` main commit moves, the
genesis patch no longer applies, funds are insufficient, the action is
not observed, or the reward account is not funded before the wait
budget expires.

The withdrawal phase may fail during setup, reward observation, intent
resolution, `tx-build`, submission, or materialization. When diagnosing
`tx-build`, inspect `withdraw/tx-build.log`, `withdraw/report.json`,
and the run directory's node log together. When diagnosing submission
or materialization, inspect `withdraw/signed-tx.cbor.hex`,
`withdraw/submit.log`, `withdraw/materialized.json`, and the node log.

The swap readiness phase may fail during artifact hashing, reference
script publication, reference UTxO lookup, or observed reference-script
hash verification. Inspect `swap-ready/registry.json`,
`swap-ready/summary.json`, `swap-ready/provenance.json`, `summary.log`,
and the node log together.

Use the run directory's `node.log`, `summary.log`, `timing.json`, and
`governance/summary.json` when recording governance evidence. Use
`withdraw/intent.json`, `withdraw/registry.json`,
`withdraw/report.json`, `withdraw/signed-tx.cbor.hex`,
`withdraw/submit.log`, and `withdraw/materialized.json` when recording
withdrawal evidence. Use `swap-ready/registry.json`,
`swap-ready/summary.json`, and `swap-ready/provenance.json` when
recording swap readiness evidence.
