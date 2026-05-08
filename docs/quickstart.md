# Quickstart

Build a transaction end-to-end in one pipe. The **swap wizard** and
**withdraw wizard** answer chain-anchored fields for you; the
**tx-build** subcommand turns each unified `intent.json` into unsigned
Conway CBOR.

## 1. Install

### macOS (Apple Silicon)

```bash
brew tap lambdasistemi/tap
brew install amaru-treasury-tx
```

### Linux (x86_64)

Grab the AppImage from the
[releases page](https://github.com/lambdasistemi/amaru-treasury-tx/releases/latest):

```bash
curl -L \
  https://github.com/lambdasistemi/amaru-treasury-tx/releases/latest/download/amaru-treasury-tx.AppImage \
  -o amaru-treasury-tx
chmod +x ./amaru-treasury-tx
./amaru-treasury-tx --help
```

Or use the `.deb` / `.rpm` packages from the same release.

### From source (any platform)

```bash
git clone git@github.com:lambdasistemi/amaru-treasury-tx.git
cd amaru-treasury-tx
nix develop
just build
```

### Run from the published flake (no install)

```bash
EXE='nix run github:lambdasistemi/amaru-treasury-tx#amaru-treasury-tx --'
```

(Use this `EXE` everywhere `amaru-treasury-tx` appears below.)

## 2. Point at a mainnet node

```bash
export CARDANO_NODE_SOCKET_PATH=/path/to/cardano-node.socket
```

(Or pass `--node-socket PATH` to the CLI.)

## 3. Fetch the upstream metadata

```bash
curl -fsSL https://raw.githubusercontent.com/pragma-org/amaru-treasury/main/journal/2026/metadata.json \
    -o metadata-mainnet.json
```

The wizard treats this file as an untrusted hint and verifies
every consumed field against the on-chain registry NFT and
build-time pinned Plutus blobs before producing an intent.

## 4. The famous swap, end to end

```bash
amaru-treasury-tx \
    --node-socket "$CARDANO_NODE_SOCKET_PATH" --network mainnet \
    swap-wizard \
        --wallet-addr addr1q802wxt6cg6aw0nl0vdzfxavu65rxu3yzhvgayw7chfxymduzkt66uw9t5kspx5jwjecx80dz4g33htknafhdhkvzd5st4f9xu \
        --metadata metadata-mainnet.json \
        --scope network_compliance \
        --usdm 100000 \
        --split 33 \
        --min-rate 0.245 \
        --validity-hours 28 \
        --description "Swapping ADA for \$100k at a rate of \$0.245 per ADA" \
        --justification "Required to pay Antithesis as vendor" \
        --destination-label "Network Compliance's treasury" \
        --extra-signer core_development \
        --log wizard.log \
  | amaru-treasury-tx \
        --node-socket "$CARDANO_NODE_SOCKET_PATH" \
        tx-build \
            --log build.log \
            --out swap.cbor.hex
```

What the flags mean:

| Flag | What it controls |
|---|---|
| `--wallet-addr` | Wallet bech32 address. Wizard picks its largest pure-ADA UTxO as fuel + collateral. |
| `--metadata`   | Local `metadata.json` (untrusted hint; verified against chain). |
| `--scope`      | One of `core_development`, `ops_and_use_cases`, `network_compliance`, `middleware`. |
| `--usdm`       | Total USDM the swap should buy. ADA spend is derived as `usdm / min-rate`. |
| `--split N`    | Slice the order into N equal chunks. Use `--chunk-usdm X` instead to pin per-chunk size. |
| `--min-rate`   | Sundae limit price (USDM per ADA). |
| `--validity-hours` | Validity window from current tip; 1..48. |
| `--description` / `--justification` / `--destination-label` | Free-form rationale fields, pinned into the on-chain audit trail. |
| `--extra-signer SCOPE\|HEX` | Repeated for each witness owner beyond the selected scope owner. Scope names and 28-byte key hashes are accepted; `--signer` remains as an alias. |
| `--log PATH`   | Redirect the typed step trace to a file (default = stderr). |
| `--out PATH`   | Wizard side: write `intent.json` here (default = stdout, which is what the pipe reads). `tx-build` side: write hex CBOR here (default = stdout). |

## 5. What lands where

| Stream | Contents |
|---|---|
| `wizard.log` | `swap-wizard:` step trace, one event per value-affecting step (verifier acceptance, on-chain owners, UTxO selection, validity slot, chunk shape, …). |
| pipe | `intent.json` payload — wizard stdout → `tx-build` stdin. |
| `build.log`   | `tx-build:` step trace (intent source, parse, network check, connect, build summary, redeemer re-eval, validation result). |
| `swap.cbor.hex` | The unsigned Conway transaction as hex. |

Drop `--log` from either subcommand to send the trace to stderr.
Drop `--out` from the wizard to write `intent.json` to stdout
(this is what the pipe relies on). Drop `--intent` from `tx-build`
to read the intent from stdin (also what the pipe relies on).

## 6. Reading the trace as the audit gate

The wizard never asks for confirmation. The trace IS the audit
trail. A successful run looks like this:

```text
swap-wizard: network mainnet (magic 764824073)
swap-wizard: metadata = metadata-mainnet.json
swap-wizard: VERIFIED scope=network_compliance treasury=addr1xyezq8w… treasuryScriptHash=32201dc1… registryPolicyId=38c627d4… permissionsRewardAccount=a64d1b9e…
swap-wizard: owners core=7095faf3… ops=f3ab64b0… network_compliance=8bd03209… middleware=97e0f6d6…
swap-wizard: wallet utxos: 3
swap-wizard: treasury utxos: 1 (total 1450000000000 lovelace)
swap-wizard: tip slot 186446659
swap-wizard: NetworkConstants swapOrder=addr1x8ax5k9m… usdmPolicy=c48cbb3d… usdmToken=0014df105553444d sundaeFee=1280000
swap-wizard: wallet utxo selected 42e4c279…#0
swap-wizard: treasury utxos selected 64f27254…#0 leftover=1041836734694
swap-wizard: validity tip=186446659 upperBound=186547459 (+100800 slots)
swap-wizard: chunks total=408163265306 chunkSize=12368583797 full=33 remainder=5
swap-wizard: intent.json -> stdout

tx-build: intent <- stdin
tx-build: parsed action=Swap network=mainnet
tx-build: connecting to /path/to/cardano-node.socket
tx-build: required utxos: 6
tx-build: handshake ok (magic 764824073 matches intent network=mainnet)
tx-build: built 14954 bytes  fee=1039703  total_collateral=1559555
tx-build: re-evaluated 2 redeemers, 0 failed
tx-build: cbor -> swap.cbor.hex
tx-build: VALIDATION OK
```

The `VERIFIED scope=…` line and the `NetworkConstants` row are
the chain- and build-time roots binding the produced
transaction to the upstream pin. Read them before signing.

## 7. Sign + submit (out of scope for this CLI)

Pipe `swap.cbor.hex` into your signer (hardware wallet,
[`cardano-wallet-sign`][cws], MPC service) then
`cardano-cli transaction submit` (or any other broadcaster).
Submit within minutes — the wizard's `validityUpperBoundSlot`
ticks down with the tip.

## 8. Two-step form (without the pipe)

```bash
amaru-treasury-tx swap-wizard ... --out intent.json
amaru-treasury-tx tx-build --intent intent.json --out swap.cbor.hex
```

Same behaviour, useful when you want to inspect or hand-edit
`intent.json` between the two stages.

## 9. Withdraw rewards

The withdraw flow has the same wizard-to-builder shape:

```bash
amaru-treasury-tx \
    --node-socket "$CARDANO_NODE_SOCKET_PATH" --network preprod \
    withdraw-wizard \
        --wallet-addr addr_test1... \
        --metadata metadata-mainnet.json \
        --scope core_development \
        --validity-hours 6 \
        --log withdraw-wizard.log \
  | amaru-treasury-tx \
        --node-socket "$CARDANO_NODE_SOCKET_PATH" \
        tx-build \
            --log withdraw-build.log \
            --out withdraw.cbor.hex
```

If the selected treasury reward account has zero rewards,
`withdraw-wizard` exits 0 and writes no intent. See
[Withdraw](withdraw.md) for the existing-intent form, schema shape, and
synthetic golden evidence.

## 10. When something goes wrong

| Exit | Action |
|------|--------|
| 1 (tx-build) | The build aborted before producing CBOR. The trace's `tx-build: ABORT …` line names the cause: bad intent JSON, translation error, or a re-evaluated redeemer failure. |
| 3 (swap-wizard / tx-build) | Setup error. The trace's `ABORT …` line names the offending step (registry mismatch, empty wallet UTxO set, missing UTxOs in chain context, …). |
| 4 (swap-wizard) | Translation error. Re-check `--min-rate`, `--chunk-usdm`/`--split`, and `--validity-hours ∈ [1, 48]`. |
| 6 (tx-build) | The N2C handshake reports a network magic that disagrees with the intent's `network` field. The trace's `tx-build: NETWORK MISMATCH …` line names both networks; point `--node-socket` at the right node. |

Both subcommands are fail-closed — neither writes a partial
output. If the trace ends without `cbor -> …` (or
`intent.json -> …` from the wizard), nothing was written.

## 11. Reproduce the known oracles (developer)

The golden suite rebuilds frozen transaction fixtures:

```bash
nix develop --quiet -c just golden swap
nix develop --quiet -c just golden withdraw
```

The swap fixture compares byte-for-byte against a bash/cardano-cli
oracle. The withdraw fixture is synthetic until issue #17 records a
live preprod reward oracle. Both freeze protocol parameters, resolved
UTxOs, and evaluator ExUnits, so the tests do not depend on today's
chain state. See [Parity report](parity.md), [Withdraw](withdraw.md),
and [Freeze workflow](freeze-workflow.md).

## 12. Smoke the signer UX and pipe contracts (developer)

Before cutting a release or handing a branch to operators, run:

```bash
nix develop --quiet -c just smoke
```

The smoke check runs the focused signer regression, checks the
release-facing help surfaces, and exercises the withdraw fixture path
through schema validation plus the synthetic CBOR golden.

## 13. Trust model

The full account of what the wizard verifies vs. what it asks
the operator to assert lives in
[Trust model](trust-model.md): bake-time and run-time
dependency graphs, the verifier's two trust roots, the
field-by-field map of where each `intent.json` value comes
from. Read it once before signing your first mainnet
transaction.

[cws]: https://github.com/lambdasistemi/cardano-wallet-sign
