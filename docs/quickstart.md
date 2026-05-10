# Quickstart

Build a transaction end-to-end. The **swap-quote** command is the
normal swap preparation path: it fetches or accepts a fresh quote,
requires explicit slippage, derives the swap limit price, writes an
audit `params.json`, and builds unsigned Conway CBOR. The
**withdraw wizard** answers chain-anchored fields for reward
withdrawals.

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
    swap-quote \
        --wallet-addr addr1q802wxt6cg6aw0nl0vdzfxavu65rxu3yzhvgayw7chfxymduzkt66uw9t5kspx5jwjecx80dz4g33htknafhdhkvzd5st4f9xu \
        --metadata metadata-mainnet.json \
        --out-dir swap-run \
        --scope network_compliance \
        --usdm 100000 \
        --split 33 \
        --price-source coingecko-ada-usd \
        --slippage-bps 100 \
        --validity-hours 28 \
        --description "Swapping ADA for \$100k using a fresh ADA/USD quote" \
        --justification "Required to pay Antithesis as vendor" \
        --destination-label "Network Compliance's treasury" \
        --extra-signer core_development
```

What the flags mean:

| Flag | What it controls |
|---|---|
| `--wallet-addr` | Wallet bech32 address. Wizard picks its largest pure-ADA UTxO as fuel + collateral. |
| `--metadata`   | Local `metadata.json` (untrusted hint; verified against chain). |
| `--out-dir`    | Directory for `intent.json`, `swap.cbor.hex`, `params.json`, `wizard.log`, and `build.log`. |
| `--scope`      | One of `core_development`, `ops_and_use_cases`, `network_compliance`, `middleware`. |
| `--usdm`       | Total USDM the swap should buy. ADA spend is derived from the quote and slippage policy. |
| `--split N`    | Slice the order into N equal chunks. Use `--chunk-usdm X` instead to pin per-chunk size. |
| `--price-source` | Named quote source. `coingecko-ada-usd` is the approved live ADA/USD source. |
| `--ada-usd`    | Explicit ADA/USD quote override for deterministic offline operation. |
| `--ada-usdm`   | Explicit ADA/USDM quote override. Named live ADA/USDM sources are deferred. |
| `--slippage-bps` | Required slippage policy in basis points. There is no hidden default. |
| `--validity-hours` | Validity window from current tip; 1..48. |
| `--description` / `--justification` / `--destination-label` | Free-form rationale fields, pinned into the on-chain audit trail. |
| `--extra-signer SCOPE\|HEX` | Repeated for each witness owner beyond the selected scope owner. Scope names and 28-byte key hashes are accepted; `--signer` remains as an alias. |

## 5. What lands where

| Stream | Contents |
|---|---|
| `swap-run/wizard.log` | `swap-wizard:` step trace, one event per value-affecting step: verifier acceptance, on-chain owners, UTxO selection, validity slot, and chunk shape. |
| `swap-run/intent.json` | Unified swap intent generated from the quote-derived parameters. |
| `swap-run/build.log` | `tx-build:` step trace: intent parse, network check, build summary, redeemer re-eval, and validation result. |
| `swap-run/swap.cbor.hex` | The unsigned Conway transaction as hex. |
| `swap-run/params.json` | Quote-derived audit artifact: quote provenance, observed/fetched time, slippage, derived min rate, requested amount, affordability inputs, selected treasury total, status, and output paths. |

If affordability fails, `swap-quote` writes `params.json` with the
shortfall details and exits before `swap.cbor.hex` is produced.

## 6. Read the audit files before signing

The command never asks for confirmation. Inspect `swap-run/params.json`,
`swap-run/wizard.log`, and `swap-run/build.log` before handing
`swap-run/swap.cbor.hex` to any signer. `params.json` records how the
limit price was chosen; the logs record the chain and build decisions
that produced the unsigned transaction.

For the Markdown pre-signing review artifact, build the same intent
through the report helper:

```bash
scripts/ops/build-swop --out review-run --intent swap-run/intent.json
```

This writes `review-run/swap.cbor.hex`, `review-run/report.json`, and
`review-run/report.md`. The JSON is the build-output envelope with
top-level `intent` plus top-level `result`; the Markdown is derived
from that envelope and is the human review surface. Use
`--no-markdown` only when a JSON-only review bundle is intended.

Pre-signing audit checklist:

- `quote.value`, `quote.provenance`, `quote.observedAt`, and any
  `quote.fetchedAt` match the operator decision.
- `slippage.basisPoints` is the policy approved for the run.
- `derived.minRate`, `derived.amountLovelace`, and
  `derived.chunkSizeLovelace` match the intended economic request.
- `affordability.affordable` is `true`, `shortfallLovelace` is `0`,
  and the selected treasury total is enough for amount plus per-chunk
  overhead.
- `outputs.intentJson`, `outputs.unsignedCborHex`, `outputs.wizardLog`,
  and `outputs.buildLog` point at the files produced for signing review.

Use the typed traces as the second audit trail. A successful run looks
like this:

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
swap-wizard: intent.json -> swap-run/intent.json

tx-build: parsed action=Swap network=mainnet
tx-build: connecting to /path/to/cardano-node.socket
tx-build: required utxos: 6
tx-build: handshake ok (magic 764824073 matches intent network=mainnet)
tx-build: built 14954 bytes  fee=1039703  total_collateral=1559555
tx-build: re-evaluated 2 redeemers, 0 failed
tx-build: cbor -> swap-run/swap.cbor.hex
tx-build: VALIDATION OK
```

The `VERIFIED scope=…` line and the `NetworkConstants` row are
the chain- and build-time roots binding the produced
transaction to the upstream pin. Read them before signing.

## 7. Sign + submit (out of scope for this CLI)

After the audit files and traces pass review, pipe
`swap-run/swap.cbor.hex` into your signer (hardware wallet,
[`cardano-wallet-sign`][cws], MPC service) then
`cardano-cli transaction submit` (or any other broadcaster).
Submit within minutes — the wizard's `validityUpperBoundSlot`
ticks down with the tip.

## 8. Deterministic quote override

```bash
amaru-treasury-tx \
    --node-socket "$CARDANO_NODE_SOCKET_PATH" --network mainnet \
    swap-quote \
        --wallet-addr addr1q... \
        --metadata metadata-mainnet.json \
        --out-dir swap-run \
        --scope network_compliance \
        --usdm 100000 \
        --split 33 \
        --ada-usd 0.8123 \
        --slippage-bps 100 \
        --validity-hours 28 \
        --description "Swapping ADA for \$100k using an operator ADA/USD quote" \
        --justification "Required to pay Antithesis as vendor" \
        --destination-label "Network Compliance's treasury" \
        --extra-signer core_development
```

Use `--ada-usdm` instead when the approved operator input is already
an ADA/USDM quote. Named live ADA/USDM sources are not selected in
this issue; use explicit `--ada-usdm` until a provider contract is
approved.

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
| 3 (swap-quote / swap-wizard / tx-build) | Setup or economic error. The trace's `ABORT …` line names the offending step: quote source failure, registry mismatch, empty wallet UTxO set, treasury affordability shortfall, missing UTxOs in chain context, and similar fail-closed cases. |
| 4 (swap-wizard) | Translation error in the expert manual path. Re-check `--min-rate`, `--chunk-usdm`/`--split`, and `--validity-hours` in `[1, 48]`. |
| 6 (tx-build) | The N2C handshake reports a network magic that disagrees with the intent's `network` field. The trace's `tx-build: NETWORK MISMATCH …` line names both networks; point `--node-socket` at the right node. |

Both subcommands are fail-closed — neither writes a partial
output. If the trace ends without `cbor -> …` (or
`intent.json -> …` from the wizard), nothing was written.

Direct `swap-wizard --min-rate` remains available as an expert/manual
override for precomputed rates. That path does not create
`params.json`, so the operator must keep the external quote,
slippage, arithmetic, and affordability audit record separately.

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
