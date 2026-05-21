# Local DevNet Smoke

The local DevNet smoke is an opt-in release check. It starts the
`cardano-node-clients` DevNet, verifies the node socket with network
magic `42`, can publish registry/reference-script bootstrap state, can
register the treasury and permissions reward accounts, proves the
governance proposal / withdrawal materialization flow, and proves the
disburse submit flow on a patched short-epoch genesis. The command
proofs record governance proposal/vote evidence, reward funding,
withdrawal build/submission, the materialized treasury UTxO, disburse
submission, beneficiary receipt, and the reduced treasury output. The
swap readiness phase publishes the public SundaeSwap V3 order
validator as a local DevNet reference script and writes handoff
metadata for the later order-build slice.

This check is not part of `just ci`: it starts a real local
`cardano-node` and is meant as manual live evidence before a release.

> **Operator surface after #157**: the `amaru-treasury-tx devnet
> <action>` supercommand is retired. The new shipped operator path
> for the seven bootstrap sub-actions is
> `amaru-treasury-tx tx-build --intent <bootstrap-intent.json>`
> (see the bootstrap section in [README.md](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/README.md#devnet-bootstrap-via-tx-build---intent) for the
> per-sub-action tags). The library runners under
> `lib/Amaru/Treasury/Devnet/` remain on disk and are consumed by
> `Amaru.Treasury.Devnet.SmokeSpec` via `Amaru.Treasury.Devnet.Runner`
> — that is the **library proof** layer this document describes. The
> **CLI proof** layer (a bash `smoke.sh` that drives the shipped CLI
> chain end-to-end) ships in
> [#161](https://github.com/lambdasistemi/amaru-treasury-tx/issues/161).
> The wizards that produce the per-sub-action `bootstrap-intent.json`
> ship in
> [#158](https://github.com/lambdasistemi/amaru-treasury-tx/issues/158)
> /
> [#159](https://github.com/lambdasistemi/amaru-treasury-tx/issues/159)
> /
> [#160](https://github.com/lambdasistemi/amaru-treasury-tx/issues/160).
> Fresh-chain registry bootstrap additionally uses the explicit
> `--bootstrap` mode and `write-artifacts` command from
> [#175](https://github.com/lambdasistemi/amaru-treasury-tx/issues/175).
> The library proof examples below remain as the local SmokeSpec layer;
> the shipped CLI proof layer in
> [#161](https://github.com/lambdasistemi/amaru-treasury-tx/issues/161)
> should drive the documented wizard → tx-build → witness → submit →
> write-artifacts sequence.

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

## CLI DevNet Smoke (operator/CLI proof layer, #161)

This is the **CLI proof** layer: a small operator tutorial that uses
only the shipped `amaru-treasury-tx` CLI to drive the bootstrap and
stake/reward initialisation on a fresh DevNet. It exists to let a
human re-run the bootstrap on their workstation from a clean
checkout, capture a transcript, and verify the chain assertions
without reaching for the in-process library runners under
`lib/Amaru/Treasury/Devnet/` (those remain the library proof layer,
exercised by `Amaru.Treasury.Devnet.SmokeSpec`).

### Run the registry-stake phase from a clean checkout

```bash
nix develop --quiet
just devnet-cli-smoke \
  --phase registry-stake \
  --run-dir runs/devnet-cli/$(date -u +%Y%m%dT%H%M%SZ)
```

What this does, every step through the shipped CLI:

1. `devnet-cli-smoke-host` brings up a real `cardano-node` on the
   pinned DevNet genesis (patched short-epoch, committee single-key,
   governance deposit knobs).
2. The host emits deterministic DevNet funding/voter signing-key
   envelopes under `<run-dir>/keys/` and exports their bech32 address
   and key-hash hex via env vars.
3. `scripts/smoke/smoke.sh --inside-devnet` resolves the branch-built
   executable via `cabal list-bin exe:amaru-treasury-tx -O0`. It must
   never call a PATH-resolved `amaru-treasury-tx` because that can
   point at a stale binary (notably
   `/home/paolino/bin/amaru-treasury-tx` on Paolo's box predates the
   `registry-init-wizard --bootstrap` flag).
4. The shell smoke creates an age-encrypted vault from the DevNet
   funding key, then drives — in order — five bootstrap transactions
   through the shipped CLI:
   - `registry-init-wizard seed-split --bootstrap`
   - `registry-init-wizard mint --bootstrap`
   - `registry-init-wizard reference-scripts --bootstrap`
   - `stake-reward-init-wizard script-account`
   - `stake-reward-init-wizard plain-account`

   Each transaction goes through the unified pipeline
   `tx-build → witness → attach-witness → submit`. The shared
   `build_sign_submit` shell function verifies that the pre-submission
   `txId` reported by `tx-build` matches the post-submission `txId`
   returned by `submit`.
5. `registry-init-wizard write-artifacts` materialises the registry
   handoff to `<run-dir>/registry-init/registry.json`. The smoke then
   derives `<run-dir>/stake-reward-init/accounts.json` from that
   registry plus the two submitted stake-reward tx ids.
6. After the shell smoke exits successfully, the host re-acquires the
   live DevNet via the Amaru-owned N2C surface
   (`withLocalNodeBackend` + `Backend.singleShotWithAcquired`) and
   verifies the four registry anchors are still unspent on chain, and
   queries the two reward-account balances. The anchor check is the
   hard gate; the reward-account observation is recorded as a
   diagnostic alongside the authoritative
   `stake-reward-script-account` / `stake-reward-plain-account` tx
   ids captured in `<run-dir>/phases/registry-stake/summary.json`.

### Record a transcript

The slice ships `scripts/smoke/record-cli-devnet-smoke` as a small
wrapper that prefers `asciinema` and falls back to `script(1)` when
asciinema is not installed. Run it before the smoke command to
capture a real local artifact:

```bash
nix develop --quiet
scripts/smoke/record-cli-devnet-smoke runs/devnet-cli-tutorial
```

The wrapper:

- prints which recorder it chose (`asciinema rec` or `script -c`);
- writes the cast/transcript next to the run-dir, e.g.
  `runs/devnet-cli-tutorial.cast` or `runs/devnet-cli-tutorial.script`;
- exits with the smoke's exit code so failures propagate.

Do not commit fabricated casts. If no recorder is available, the
wrapper exits non-zero with a precise diagnostic naming the missing
tools so the operator can install one.

### Expected artifacts

Inside the run-dir after a successful `--phase registry-stake`:

```text
runs/devnet-cli/.../
|-- chain/
|   |-- assertions.json
|   |-- assertions.log
|   `-- assertions.request.json
|-- diagnostics/
|   |-- {seed-split,mint,reference-scripts}.{build.log,report.json}
|   `-- stake-reward-{script,plain}-account.{build.log,report.json}
|-- intents/                         # (not currently emitted -- intents
|                                    # live under phases/registry-stake)
|-- keys/{funding,voter}.skey
|-- phases/registry-stake/
|   |-- diagnostics/*.intent.log
|   |-- funding.passphrase
|   |-- funding.vault.age
|   |-- intents/{seed-split,mint,reference-scripts,
|   |             stake-reward-script-account,
|   |             stake-reward-plain-account}.intent.json
|   `-- summary.json
|-- registry-init/{registry,summary,provenance}.json
|-- signed/                          # signed CBOR hex per tx
|-- stake-reward-init/accounts.json
|-- submits/                         # tx ids + outcome lines per tx
|-- unsigned/                        # unsigned CBOR hex per tx
|-- witnesses/                       # per-tx detached witness hex
`-- genesis/                         # smoke-local genesis copy
```

### Hard contract

- No external `cardano-cli` anywhere on the smoke path.
- No in-process DevNet runners (`runDevnet*`,
  `Amaru.Treasury.Devnet.Runner`, `RegistryInit`, `StakeRewardInit`,
  …) reachable from the host or the shell script.
- The host may start DevNet, patch genesis, emit deterministic key
  fixtures, and perform chain queries via the Amaru-owned
  `Backend.QueryHandle`; it does not build/sign/submit transactions.

### Scope of this slice

`--phase registry-stake` is the only live phase wired in this slice.
`--phase governance` and `--phase disburse` remain unimplemented and
will be delivered in later #161 slices (T017-T025). Run-dir summaries
for those phases do **not** exist yet, and the CLI smoke will fail
loudly if you point it at them.

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

After #175 the shipped operator path for a fresh DevNet registry
boundary is the three-subcommand `registry-init-wizard` bootstrap flow
plus a post-submit artifact writer. Each bootstrap subcommand produces
one intent JSON consumed by `amaru-treasury-tx tx-build --intent` (see
the bootstrap section in [README.md](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/README.md#devnet-bootstrap-via-tx-build---intent)).
The wizard is **explicitly inter-tx unsafe**: the operator types every
value that crosses a sub-step boundary (submitted tx ids, seed TxIns
from `seed-split`, the owner key hash, and the funding seed UTxO). The
resumable client state that will supersede this manual carry is parked in
[#163](https://github.com/lambdasistemi/amaru-treasury-tx/issues/163).
The bash smoke that drives the full chain through the shipped CLI on
a real DevNet lands in
[#161](https://github.com/lambdasistemi/amaru-treasury-tx/issues/161);
until #161 merges, the local smoke below keeps driving the library
function directly via `SmokeSpec`, which calls into
`Amaru.Treasury.Devnet.Runner.runDevnetRegistryInit`:

```bash
COMMON=(--network devnet --node-socket "$CARDANO_NODE_SOCKET_PATH")
RUN_DIR=runs/devnet/$(date -u +%Y%m%dT%H%M%SZ)

amaru-treasury-tx "${COMMON[@]}" registry-init-wizard seed-split \
  --bootstrap \
  --wallet-addr <devnet-bech32> \
  --metadata <metadata.json> \
  --scope <scope-id> \
  --out seed-split.intent.json
amaru-treasury-tx "${COMMON[@]}" tx-build --intent seed-split.intent.json --out seed-split.tx.cbor.hex
amaru-treasury-tx witness ...
amaru-treasury-tx submit  ...
# record <seed-split-txid>

amaru-treasury-tx "${COMMON[@]}" registry-init-wizard mint \
  --bootstrap \
  --wallet-addr <devnet-bech32> \
  --metadata <metadata.json> \
  --scope <scope-id> \
  --scopes-seed-txin <seed-split-txid>#0 \
  --registry-seed-txin <seed-split-txid>#1 \
  --owner-key-hash <hex28> \
  --out mint.intent.json
amaru-treasury-tx "${COMMON[@]}" tx-build --intent mint.intent.json --out mint.tx.cbor.hex
amaru-treasury-tx witness ...
amaru-treasury-tx submit  ...
# record <registry-mint-txid>

amaru-treasury-tx "${COMMON[@]}" registry-init-wizard reference-scripts \
  --bootstrap \
  --wallet-addr <devnet-bech32> \
  --metadata <metadata.json> \
  --scope <scope-id> \
  --scopes-seed-txin <seed-split-txid>#0 \
  --registry-seed-txin <seed-split-txid>#1 \
  --funding-seed-txin <wallet-utxo>#N \
  --out reference-scripts.intent.json
amaru-treasury-tx "${COMMON[@]}" tx-build --intent reference-scripts.intent.json --out reference-scripts.tx.cbor.hex
amaru-treasury-tx witness ...
amaru-treasury-tx submit  ...
# record <reference-scripts-txid>

amaru-treasury-tx "${COMMON[@]}" registry-init-wizard write-artifacts \
  --run-dir "$RUN_DIR" \
  --seed-split-txid <seed-split-txid> \
  --registry-mint-txid <registry-mint-txid> \
  --reference-scripts-txid <reference-scripts-txid> \
  --scopes-seed-txin <seed-split-txid>#0 \
  --registry-seed-txin <seed-split-txid>#1 \
  --owner-key-hash <hex28>
```

#161 must persist the handoff fields that make this sequence auditable:
run directory, DevNet magic `42`, `seed-split-txid`,
`registry-mint-txid`, `reference-scripts-txid`,
`<seed-split-txid>#0`, `<seed-split-txid>#1`, owner key hash, and the
funding seed UTxO used by `reference-scripts`. The artifact writer uses
the submitted tx ids, seed refs, and owner key hash to write
`registry-init/summary.json`, `registry-init/registry.json`,
`registry-init/provenance.json`, and the top-level summary files.

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

After #157 and #159 the shipped operator path for this boundary is
the two-subcommand `amaru-treasury-tx stake-reward-init-wizard
{script-account | plain-account}` flow, each producing one intent
JSON consumed by `amaru-treasury-tx tx-build --intent` (see the
bootstrap section in [README.md](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/README.md#devnet-bootstrap-via-tx-build---intent)).
The wizard is **explicitly inter-tx unsafe**: the operator hand-carries
the `registry.json` artifact path (produced by `registry-init-wizard
reference-scripts`) and a funding seed TxIn into each invocation; the
wizard does no chain re-verification of the registry contents and no
cross-step simulation. The two subcommands are independent — neither
feeds into the other; ordering is the operator's choice. The
resumable client state that will supersede this manual carry is
parked in
[#163](https://github.com/lambdasistemi/amaru-treasury-tx/issues/163).
The bash smoke that drives the full chain through the shipped CLI on
a real DevNet lands in
[#161](https://github.com/lambdasistemi/amaru-treasury-tx/issues/161);
until #161 merges, the local smoke below keeps driving the library
function directly via `SmokeSpec`, which calls into
`Amaru.Treasury.Devnet.Runner.runDevnetStakeRewardInit`.

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

The stake-reward-init command registers the treasury script reward
account and the permissions reward account. The permissions script is
still invoked later by disburse/swap transactions through the
withdraw-zero pattern, not as a certificate-purpose validator.

The verified 2026-05-17 slice used run directory
`runs/devnet/20260517T005034Z`. It submitted setup tx
`527c1b08fdfd1c41fe1237d4d5f1bc3572dee98a81b76b62257c958e50dc9cc8`,
reported treasury reward account
`b2b7201c62e43ae8e03b61c96931379ebbcdce61befc3f4e4b1f4be4` as
`registered: true`, and reported permissions reward account
`f9dc1d931a3f52eaf83891f8621cbba5ba64f6faa5792f1b00c17333` as
`registered: true`, both on ledger network `Testnet`.

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

After #157 and #160 the shipped operator path for this boundary is the
two-subcommand `amaru-treasury-tx governance-withdrawal-init-wizard
{proposal | materialization}` flow (see the bootstrap section in
[README.md](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/README.md#devnet-bootstrap-via-tx-build---intent)).
Both subcommands consume the `registry.json` artifact produced by
[#158](https://github.com/lambdasistemi/amaru-treasury-tx/issues/158),
the `accounts.json` artifact produced by
[#159](https://github.com/lambdasistemi/amaru-treasury-tx/issues/159),
and an operator-typed funding seed. The proposal subcommand additionally
takes the funding stake key hash, voter/DRep key hash, withdrawal
amount, CIP-1694 anchor URL, and anchor content hash; materialization
takes the operator-observed `--rewards-lovelace` after proposal
enactment.

The proposal command writes an intent that is then built with
`tx-build --intent`, witnessed three times (funding payment, funding
stake, voter/DRep), attached, and submitted. The materialization command
writes an intent that is built the same way but needs one key witness:
funding payment. The DRep behavior is a DevNet-bootstrap convenience:
the operator is the DRep voting on their own withdrawal proposal, and
mainnet/preprod remain fail-closed. Proposal shortfall errors are
deposit-aware (`govActionDeposit + stakeDeposit + drepDeposit + fee`);
materialization does not include governance deposits.

```bash
amaru-treasury-tx governance-withdrawal-init-wizard proposal \
    --wallet-addr <devnet-bech32> \
    --registry <path/registry.json> \
    --stake-reward-accounts <path/accounts.json> \
    --funding-seed-txin <wallet-utxo-txid>#<ix> \
    --funding-stake-key-hash <56-hex-char-funding-stake-vkey-hash> \
    --voter-key-hash <56-hex-char-voter-vkey-hash> \
    --withdrawal-amount-lovelace <N> \
    --anchor-url <https://...> \
    --anchor-hash <64-hex-char-anchor-content-hash> \
    --validity-hours <hours> \
    --log proposal.wizard.log \
    --force \
    --out proposal.intent.json
amaru-treasury-tx tx-build --intent proposal.intent.json --out proposal.tx.cbor.hex
amaru-treasury-tx witness ...   # funding payment
amaru-treasury-tx witness ...   # funding stake
amaru-treasury-tx witness ...   # voter/DRep
amaru-treasury-tx attach-witness ...
amaru-treasury-tx submit ...

# After proposal enactment, observe the treasury reward balance.
amaru-treasury-tx governance-withdrawal-init-wizard materialization \
    --wallet-addr <devnet-bech32> \
    --registry <path/registry.json> \
    --stake-reward-accounts <path/accounts.json> \
    --funding-seed-txin <wallet-utxo-txid>#<ix> \
    --rewards-lovelace <observed-balance> \
    --validity-hours <hours> \
    --log materialization.wizard.log \
    --force \
    --out materialization.intent.json
amaru-treasury-tx tx-build --intent materialization.intent.json --out materialization.tx.cbor.hex
amaru-treasury-tx witness ...   # funding payment
amaru-treasury-tx attach-witness ...
amaru-treasury-tx submit ...
```

This boundary is explicitly inter-tx unsafe. The wizard does not
simulate the two transaction bodies together or check key hashes against
vault identities. The operator hand-carries the registry path, accounts
path, funding seed UTxO, key hashes, anchor URL/hash pair, observed
post-enactment reward balance, and the real-world ordering that proposal
enactment must precede materialization. The resumable client state that
will supersede this manual carry is parked in
[#163](https://github.com/lambdasistemi/amaru-treasury-tx/issues/163).
The bash smoke that drives this shipped CLI path end to end on a real
DevNet lands in
[#161](https://github.com/lambdasistemi/amaru-treasury-tx/issues/161).

The local smoke keeps driving the library function directly via
`SmokeSpec`, which calls into
`Amaru.Treasury.Devnet.Runner.runDevnetGovernanceWithdrawalInit`.

The live proof harness runs the prerequisite library entries and
then invokes the same production runner:

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

The proof copies and patches the DevNet genesis to a short epoch,
runs `runDevnetRegistryInit`, runs `runDevnetStakeRewardInit`, then
calls `runDevnetGovernanceWithdrawalInit` (all reached via
`Amaru.Treasury.Devnet.Runner` from `SmokeSpec`). Production code
owns the Conway treasury-withdrawal proposal, vote, reward wait,
withdrawal intent, tx-build, signing, submission, and materialization
verification. The smoke layer only prepares the local node /
prerequisites and asserts the observed artifacts and chain effects.

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

## Disburse Submit Boundary

After #157 the shipped operator path for disburse is the existing
`amaru-treasury-tx disburse-wizard` → `tx-build --intent` →
`witness` → `submit` chain (unchanged by #157; disburse already had
its intent encoding). The local smoke keeps driving the library
function directly via `SmokeSpec`, which calls into
`Amaru.Treasury.Devnet.Runner.runDevnetDisburseSubmit`. The bash
CLI smoke that chains the full bootstrap + disburse flow against a
real DevNet through the shipped CLI lands in
[#161](https://github.com/lambdasistemi/amaru-treasury-tx/issues/161).

The live proof harness runs the prerequisite library entries and
then invokes the same production runner:

```bash
just devnet-smoke disburse-submit
```

Expected command-prefixed output:

```text
disburse-submit: run-dir runs/devnet/YYYYMMDDTHHMMSSZ
disburse-submit: network devnet magic 42
disburse-submit: phase disburse-submit passed
disburse-submit: submitted-tx-id <tx-id>
disburse-submit: beneficiary-address <addr_test...>
disburse-submit: beneficiary-tx-in <tx-id>#1
disburse-submit: beneficiary-lovelace 1000000
disburse-submit: treasury-input <tx-id>#0
disburse-submit: treasury-lovelace-before 2000000
disburse-submit: treasury-lovelace-after 1000000
disburse-submit: signed-tx runs/devnet/YYYYMMDDTHHMMSSZ/disburse-submit/signed-tx.cbor.hex
disburse-submit: submit-log runs/devnet/YYYYMMDDTHHMMSSZ/disburse-submit/submit.log
disburse-submit: summary runs/devnet/YYYYMMDDTHHMMSSZ/disburse-submit/summary.json
```

The proof starts a fresh DevNet, runs `runDevnetRegistryInit`, runs
`runDevnetStakeRewardInit`, runs `runDevnetGovernanceWithdrawalInit`,
then calls `runDevnetDisburseSubmit` (all reached via
`Amaru.Treasury.Devnet.Runner` from `SmokeSpec`). Production code
owns disburse intent construction, tx-build, signing, submission,
beneficiary receipt verification, and treasury-output verification.
The smoke layer only prepares the local node / prerequisites and
asserts the observed artifacts and chain effects.

The verified 2026-05-17 slice used run directory
`runs/devnet/20260517T005034Z`. It submitted disburse tx
`0008ab902b2f835624f453af0467d826b02519d7139ec8e84a04c8a9c000011b`,
observed beneficiary output
`0008ab902b2f835624f453af0467d826b02519d7139ec8e84a04c8a9c000011b#1`
with `1000000` lovelace, consumed treasury input
`309e28ed5b95de38258bcc130d6390800b0719f6410b0d5fe6f3c33cc1b70817#0`,
and reduced treasury lovelace from `2000000` to `1000000`.

The command proof writes:

```text
runs/devnet/YYYYMMDDTHHMMSSZ/
|-- registry-init/
|-- stake-reward-init/
|-- governance-withdrawal-init/
`-- disburse-submit/
    |-- beneficiary.json
    |-- disburse.json
    |-- intent.json
    |-- provenance.json
    |-- report.json
    |-- report.md
    |-- signed-tx.cbor.hex
    |-- submit.log
    |-- summary.json
    |-- treasury.json
    `-- tx-body.cbor.hex
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

The passing phases today are `node`, `registry-init`,
`stake-reward-init`, `governance`, `governance-withdrawal-init`,
`disburse-submit`, `withdraw`, and `swap-ready`. `just devnet-smoke all`
runs `node`, `governance`, `governance-withdrawal-init`, and
`disburse-submit` into separate
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
`governance-withdrawal-init`. `disburse-submit` is the #150 command
proof: it consumes the #149 materialized treasury UTxO, runs the
shipped production command runner, and observes beneficiary receipt plus
the reduced treasury output. It is not proof that SundaeSwap
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

The disburse-submit phase may fail during prerequisite setup, disburse
intent creation, `tx-build`, signing, submission, beneficiary lookup, or
treasury-output verification. Inspect `disburse-submit/intent.json`,
`disburse-submit/report.json`, `disburse-submit/signed-tx.cbor.hex`,
`disburse-submit/submit.log`, `disburse-submit/beneficiary.json`,
`disburse-submit/treasury.json`, and the node log together.

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
command evidence. Use `disburse-submit/disburse.json`,
`disburse-submit/beneficiary.json`, `disburse-submit/treasury.json`,
and `disburse-submit/summary.json` when recording #150 command
evidence. Use `swap-ready/registry.json`,
`swap-ready/summary.json`, and `swap-ready/provenance.json` when
recording swap readiness evidence.
