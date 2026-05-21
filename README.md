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
- [Local devnet smoke](https://lambdasistemi.github.io/amaru-treasury-tx/local-devnet-smoke/) — opt-in `cardano-node-clients` devnet checks for live node boundary evidence. Includes the **CLI DevNet smoke** (`just devnet-cli-smoke --phase full`) — a human-runnable operator proof that drives the shipped CLI (registry-init-wizard / stake-reward-init-wizard / governance-withdrawal-init-wizard / disburse-wizard / tx-build / witness / attach-witness / submit) through registry, stake/reward, governance materialization, and disburse. The existing `just devnet-smoke ...` phases remain the library proof layer consumed by `SmokeSpec`.
- [Parity report](https://lambdasistemi.github.io/amaru-treasury-tx/parity/) — byte-for-byte golden parity against bash/cardano-cli.

## For LLM coding agents

This repo ships a vendor-neutral [Agent Skill](https://agentskills.io/home)
that walks you (a coding agent — Claude Code, OpenAI Codex,
Cursor, GitHub Copilot, Gemini CLI, OpenCode, Goose, …) through
the full operator pipeline:

- [`AGENTS.md`](AGENTS.md) — root entry point per [agents.md](https://agents.md).
- [`skills/amaru-treasury-tx-operator/`](skills/amaru-treasury-tx-operator/) —
  end-to-end workflow with a one-time first-run interview that
  caches operator-specific paths/identities to
  `~/.config/amaru-treasury-tx/operator.json`.
- [`skills/`](skills/) — index of all skills shipped with this repo.

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

Run the full shipped-CLI DevNet proof with:

```bash
nix develop --quiet -c just devnet-cli-smoke --phase full --timeout-seconds 900
```

### DevNet bootstrap via `tx-build --intent`

After [#157](https://github.com/lambdasistemi/amaru-treasury-tx/issues/157)
the `amaru-treasury-tx devnet <action>` supercommand is retired.
The seven bootstrap sub-transactions previously orchestrated in
process by `devnet {registry-init,stake-reward-init,
governance-withdrawal-init,disburse-submit}` are now reachable
through the same `wizard → tx-build → witness → submit` chain used
by `swap`, `withdraw`, and `disburse`. Each multi-tx flow is split
into per-sub-step intents at the JSON layer so each invocation of
`tx-build` produces one unsigned tx:

```text
registry-init-seed-split           # 3 txs for the registry-init flow
registry-init-mint
registry-init-reference-scripts
stake-reward-init-script-account   # 2 txs for the stake-reward flow
stake-reward-init-plain-account
governance-withdrawal-init-proposal          # 2 txs for the gov flow
governance-withdrawal-init-materialization
```

The operator path per sub-step is:

```bash
amaru-treasury-tx tx-build \
  --intent <bootstrap-intent.json> \
  --out tx.cbor.hex
amaru-treasury-tx witness --tx tx.cbor.hex …
amaru-treasury-tx submit  --tx tx.cbor.hex …
```

`bootstrap-intent.json` carries the same envelope as the existing
`intent.json` (`action`, `schemaVersion`, `network`, `payload`); the
`action` discriminator names one of the seven flat tags above. The
JSON schema is in `docs/assets/intent-schema.json`; per-sub-action
payload contracts are documented under
`specs/157-flatten-devnet-cli/contracts/`. The dispatcher rejects any
`network` other than `devnet` for these seven actions, before any
N2C connection (slice 4 of #157).

The wizards that produce `bootstrap-intent.json` files for the
registry-init flow ship as three subcommands of
`amaru-treasury-tx registry-init-wizard`, one per sub-action shipped
by #157. On a fresh DevNet, pass `--bootstrap` so the wizard does not
look for registry anchors that do not exist yet. After the three
submitted tx ids are known, run `write-artifacts` to materialize the
same `registry-init/` handoff shape that the library smoke writes:

```bash
COMMON=(--network devnet --node-socket "$CARDANO_NODE_SOCKET_PATH")
RUN_DIR=runs/devnet/$(date -u +%Y%m%dT%H%M%SZ)

# Step 1: seed-split (no inter-tx inputs).
amaru-treasury-tx "${COMMON[@]}" registry-init-wizard seed-split \
    --bootstrap \
    --wallet-addr <devnet-bech32> \
    --metadata <metadata.json> \
    --scope <scope-id> \
    --out seed-split.intent.json
amaru-treasury-tx "${COMMON[@]}" tx-build --intent seed-split.intent.json --out seed-split.tx.cbor.hex
amaru-treasury-tx witness ...
amaru-treasury-tx submit  ...
# Operator records seed-split's submitted txid as <seed-split-txid>.

# Step 2: mint (operator hand-carries seed TxIns + owner key hash).
amaru-treasury-tx "${COMMON[@]}" registry-init-wizard mint \
    --bootstrap \
    --wallet-addr <devnet-bech32> \
    --metadata <metadata.json> \
    --scope <scope-id> \
    --scopes-seed-txin   <seed-split-txid>#0 \
    --registry-seed-txin <seed-split-txid>#1 \
    --owner-key-hash     <hex28> \
    --out mint.intent.json
amaru-treasury-tx "${COMMON[@]}" tx-build --intent mint.intent.json --out mint.tx.cbor.hex
amaru-treasury-tx witness ...
amaru-treasury-tx submit  ...
# Operator records the mint txid as <registry-mint-txid>.

# Step 3: reference-scripts (operator hand-carries seed TxIns + funding seed).
amaru-treasury-tx "${COMMON[@]}" registry-init-wizard reference-scripts \
    --bootstrap \
    --wallet-addr <devnet-bech32> \
    --metadata <metadata.json> \
    --scope <scope-id> \
    --scopes-seed-txin   <seed-split-txid>#0 \
    --registry-seed-txin <seed-split-txid>#1 \
    --funding-seed-txin  <wallet-utxo>#N \
    --out reference-scripts.intent.json
amaru-treasury-tx "${COMMON[@]}" tx-build --intent reference-scripts.intent.json --out reference-scripts.tx.cbor.hex
amaru-treasury-tx witness ...
amaru-treasury-tx submit  ...
# Operator records the submitted txid as <reference-scripts-txid>.

# Step 4: write the registry-init handoff artifacts from real tx ids.
amaru-treasury-tx "${COMMON[@]}" registry-init-wizard write-artifacts \
    --run-dir "$RUN_DIR" \
    --seed-split-txid <seed-split-txid> \
    --registry-mint-txid <registry-mint-txid> \
    --reference-scripts-txid <reference-scripts-txid> \
    --scopes-seed-txin   <seed-split-txid>#0 \
    --registry-seed-txin <seed-split-txid>#1 \
    --owner-key-hash     <hex28>
```

**Explicit inter-tx unsafe** — the wizard does not simulate cross-step
tx bodies. The operator types every value that crosses a sub-step
boundary (submitted tx ids, seed TxIns, owner key hash, funding seed
UTxO). Mistyping any of them — swapping `#0` and `#1`, pasting a stale
txid, or using the wrong key hash — yields invalid intents that fail at
`tx-build` (best case), at on-chain validation (worst case), or in
`write-artifacts` validation for malformed values. This is deliberate;
the resumable client state that supersedes this manual carry is parked in
[#163](https://github.com/lambdasistemi/amaru-treasury-tx/issues/163).

The shipped CLI smoke in
[#161](https://github.com/lambdasistemi/amaru-treasury-tx/issues/161)
must hand-carry and persist: run directory, DevNet magic `42`,
`seed-split-txid`, `registry-mint-txid`, `reference-scripts-txid`,
`<seed-split-txid>#0`, `<seed-split-txid>#1`, the owner key hash, and
the funding seed UTxO used by `reference-scripts`. The artifact writer
uses the first seven values; the funding seed remains live-chain
submission evidence for the reference-scripts transaction.

The wizards that produce `bootstrap-intent.json` files for the
stake-reward-init flow ship in
[#159](https://github.com/lambdasistemi/amaru-treasury-tx/issues/159)
as two independent subcommands of
`amaru-treasury-tx stake-reward-init-wizard`, one per sub-action
shipped by #157. Both subcommands consume the `registry.json`
artifact produced by `registry-init-wizard reference-scripts` plus
an operator-typed funding seed:

```bash
# Pre-requisite: complete the registry-init bootstrap above; you
# now have registry.json on disk.

# Step 1: script-account (registers treasury reward account).
amaru-treasury-tx stake-reward-init-wizard script-account \
    --wallet-addr <devnet-bech32> \
    --registry <path/registry.json> \
    --funding-seed-txin <wallet-utxo-txid>#<ix> \
    --out script-account.intent.json
amaru-treasury-tx tx-build --intent script-account.intent.json --out script-account.tx.cbor.hex
amaru-treasury-tx witness ...
amaru-treasury-tx submit  ...

# Step 2: plain-account (registers permissions reward account;
#         independent of step 1 — order does not matter).
amaru-treasury-tx stake-reward-init-wizard plain-account \
    --wallet-addr <devnet-bech32> \
    --registry <path/registry.json> \
    --funding-seed-txin <wallet-utxo-txid>#<ix> \
    --out plain-account.intent.json
amaru-treasury-tx tx-build --intent plain-account.intent.json --out plain-account.tx.cbor.hex
amaru-treasury-tx witness ...
amaru-treasury-tx submit  ...
```

The two stake-reward sub-actions are **independent** at the wizard
layer — neither feeds into the other; the operator may invoke them
in either order. Common mistakes the wizard cannot detect: pointing
`--registry` at a stale or never-submitted bootstrap; reusing a
spent `--funding-seed-txin`; picking a registry from a different
devnet boot. These yield invalid intents that fail at `tx-build`
(best case) or at on-chain validation (worst case). The same
resumable client state parked in #163 will supersede this manual
carry.

The wizard that produces `bootstrap-intent.json` files for the
governance-withdrawal-init flow ships in
[#160](https://github.com/lambdasistemi/amaru-treasury-tx/issues/160)
as two independent subcommands of
`amaru-treasury-tx governance-withdrawal-init-wizard`. Both
subcommands consume the `registry.json` artifact produced by
[#158](https://github.com/lambdasistemi/amaru-treasury-tx/issues/158),
the `accounts.json` artifact produced by
[#159](https://github.com/lambdasistemi/amaru-treasury-tx/issues/159),
and an operator-typed funding seed:

```bash
# Pre-requisite: complete registry-init and stake-reward-init; you now
# have registry.json and accounts.json on disk. Your signing inventory
# contains the funding payment key, funding stake key, and voter/DRep key.

# Step 1: proposal (requests the treasury withdrawal, registers the
# funding stake credential, and self-votes through the DevNet DRep key).
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
amaru-treasury-tx witness ...   # funding stake (= --funding-stake-key-hash)
amaru-treasury-tx witness ...   # voter/DRep (= --voter-key-hash)
amaru-treasury-tx attach-witness ...
amaru-treasury-tx submit ...
# Wait for proposal enactment and observe the treasury reward balance.

# Step 2: materialization (withdraws the observed rewards into the
# treasury contract address).
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

The proposal transaction requires three key witnesses: funding payment,
funding stake (`--funding-stake-key-hash`), and voter/DRep
(`--voter-key-hash`). The materialization transaction requires one key
witness: funding payment. The materialization transaction also uses
treasury and registry reference scripts from `registry.json`; those are
script witnesses, not operator key witnesses.

The DRep behavior is DevNet-specific. The proposal transaction bundles
submit-and-self-vote because the closed DevNet bootstrap has no
third-party DRep to wait for. On mainnet and preprod that bundling is
not protocol-required, and the wizard refuses those networks. For this
DevNet command the operator is the DRep voting on their own withdrawal
proposal, so their vault must contain the key whose hash equals
`--voter-key-hash`.

The proposal resolver checks wallet shortfall before writing an intent:
the wallet must cover `govActionDeposit + stakeDeposit + drepDeposit`
plus the estimated fee. The 100k ADA governance-action deposit is a
mainnet orientation point; DevNet values come from that network's
protocol parameters. Materialization uses the smaller materialization
floor and does not include governance deposits.

**Explicit inter-tx unsafe** — the wizard does not simulate cross-step
tx bodies. The operator hand-carries the registry path, accounts path,
funding seed UTxO, declared key hashes, anchor URL/hash pair, observed
post-enactment reward balance, and the real-world ordering that
proposal enactment must precede materialization. Key-hash typos are not
checked against vault identities by the wizard; they fail later at
`witness` time. The resumable client state that supersedes this manual
carry is parked in
[#163](https://github.com/lambdasistemi/amaru-treasury-tx/issues/163).

The bash CLI smoke introduced by
[#161](https://github.com/lambdasistemi/amaru-treasury-tx/issues/161)
chains the full bootstrap + disburse flow against a real DevNet through
the shipped CLI:

```bash
nix develop --quiet -c just devnet-cli-smoke --phase full --timeout-seconds 900
```

Its final `summary.json` links registry/stake, governance, and disburse
phase summaries, the host chain-assertion transcripts, the run
directory, socket path, and every submitted tx id.

The end-to-end DevNet runners under
`lib/Amaru/Treasury/Devnet/{RegistryInit,StakeRewardInit,
GovernanceWithdrawalInit,DisburseSubmit}.hs` are no longer exposed
as a shipped CLI surface. They remain on disk as library functions
consumed by `Amaru.Treasury.Devnet.SmokeSpec` (via
`Amaru.Treasury.Devnet.Runner`), which keeps the library-level
DevNet proof gating CI through `nix build .#checks.*`.

#### Recent live-DevNet evidence (pre-#157 in-process runners)

The following runs were produced before the supercommand was
retired; the same CBOR is now built byte-for-byte from
`tx-build --intent` (proved by goldens
`test/golden/{RegistryInit,StakeRewardInit,GovernanceWithdrawalInit}IntentSpec.hs`).

- Registry init (`runs/devnet/20260516T193404Z`): seed split tx
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
  treasury reference
  `5c3227fe8511632669b5383246e7ff92ccc2add2988ee90ac1a24ecda6a10a44#1`.
- Stake-reward init (`runs/devnet/20260517T005034Z`): setup tx
  `527c1b08fdfd1c41fe1237d4d5f1bc3572dee98a81b76b62257c958e50dc9cc8`,
  treasury reward account
  `b2b7201c62e43ae8e03b61c96931379ebbcdce61befc3f4e4b1f4be4`,
  permissions reward account
  `f9dc1d931a3f52eaf83891f8621cbba5ba64f6faa5792f1b00c17333`,
  both registered on `Testnet`.
- Governance / withdrawal init
  (`runs/devnet/20260516T231003Z`): proposal tx
  `baffa774b368b1da8c3ff80be399bcf6fa63b5cff658b6889fc00109da218e23`,
  governance action
  `baffa774b368b1da8c3ff80be399bcf6fa63b5cff658b6889fc00109da218e23#0`,
  vote tx
  `009801303fc5cc3c3dfe474c30cc4b7d31e99b5af29467cc317072ea6b728c45`,
  treasury reward account
  `b2b7201c62e43ae8e03b61c96931379ebbcdce61befc3f4e4b1f4be4`, reward
  `0 → 2000000 → 0` lovelace, withdrawal tx
  `4a87409b52b8104d51d41df7ee562196cf33621f64c4c40985b4aef5ff21e9bd`,
  fee `456417` lovelace, materialized output
  `4a87409b52b8104d51d41df7ee562196cf33621f64c4c40985b4aef5ff21e9bd#0`,
  treasury ADA `200000000 → 202000000`.
- Disburse submit (`runs/devnet/20260517T005034Z`): submitted tx
  `0008ab902b2f835624f453af0467d826b02519d7139ec8e84a04c8a9c000011b`,
  beneficiary output
  `0008ab902b2f835624f453af0467d826b02519d7139ec8e84a04c8a9c000011b#1`
  with `1000000` lovelace, treasury input
  `309e28ed5b95de38258bcc130d6390800b0719f6410b0d5fe6f3c33cc1b70817#0`,
  treasury lovelace `2000000 → 1000000`.

The opt-in live-node smoke phases remain runnable as the library proof
layer
(`just devnet-smoke {registry-init,stake-reward-init,
governance-withdrawal-init,disburse-submit}` — these still drive the
library functions via `SmokeSpec`).

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
