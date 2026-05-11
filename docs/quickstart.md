# Quickstart

Build a transaction end-to-end. The **swap wizard** answers
chain-anchored swap fields, can derive its rate from a fresh quote,
and emits a unified intent on stdout. Pipe that intent into
`tx-build --report -`, then pipe the build-output envelope into
`report-render`. The **disburse wizard** resolves ADA or USDM
treasury disbursements. The **withdraw wizard** answers
chain-anchored fields for reward withdrawals.

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

## 4. The famous swap, end to end, no intermediate files

```bash
amaru-treasury-tx \
    --node-socket "$CARDANO_NODE_SOCKET_PATH" --network mainnet \
    swap-wizard \
        --wallet-addr addr1q802wxt6cg6aw0nl0vdzfxavu65rxu3yzhvgayw7chfxymduzkt66uw9t5kspx5jwjecx80dz4g33htknafhdhkvzd5st4f9xu \
        --metadata metadata-mainnet.json \
        --scope network_compliance \
        --usdm 100000 \
        --split 33 \
        --price-source coingecko-ada-usd \
        --slippage-bps 100 \
        --validity-hours 28 \
        --description "Swapping ADA for \$100k using a fresh ADA/USD quote" \
        --justification "Required to pay Antithesis as vendor" \
        --destination-label "Network Compliance's treasury" \
        --extra-signer core_development \
| amaru-treasury-tx \
    --node-socket "$CARDANO_NODE_SOCKET_PATH" --network mainnet \
    tx-build --out /dev/null --report - \
| amaru-treasury-tx \
    report-render --metadata metadata-mainnet.json
```

What the flags mean:

| Flag | What it controls |
|---|---|
| `--wallet-addr` | Wallet bech32 address. Wizard picks its largest pure-ADA UTxO as fuel + collateral. |
| `--metadata`   | Local `metadata.json` (untrusted hint; verified against chain). |
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
| `tx-build --report -` | Emits `{ intent, result }` on stdout. Successful `result` contains both `tx-cbor` and the mechanical report; expected build failures contain `result.failure.code` and `result.failure.message`. |
| `report-render` | Reads the build-output envelope from stdin and renders Markdown. |

## 5. What flows where

| Stream | Contents |
|---|---|
| `swap-wizard` stdout | Unified swap intent generated from the quote-derived parameters. |
| `tx-build` stdout | Build-output envelope: top-level `intent` plus top-level `result`. |
| successful `result` | Contains required `tx-cbor` and `report`. |
| final stdout | Markdown review report. |
| stderr | `swap-wizard:` and `tx-build:` typed traces. |

## 6. Read the audit files before signing

The command never asks for confirmation. Read the rendered Markdown
report before handing `result.tx-cbor` to any signer. The report is
derived from the same build-output envelope that carries the inline
intent and transaction CBOR.

Pre-signing audit checklist:

- the rendered transaction type is `swap`;
- the scope, required signers, and rationale match the operator decision;
- the validity slot and rendered UTC instant are acceptable;
- conservation has zero residual;
- `result.tx-cbor` is present in the JSON envelope used for rendering.

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
swap-wizard: intent.json -> stdout

tx-build: parsed action=Swap network=mainnet
tx-build: connecting to /path/to/cardano-node.socket
tx-build: required utxos: 6
tx-build: handshake ok (magic 764824073 matches intent network=mainnet)
tx-build: built 14954 bytes  fee=1039703  total_collateral=1559555
tx-build: re-evaluated 2 redeemers, 0 failed
tx-build: cbor -> /dev/null
tx-build: VALIDATION OK
```

The `VERIFIED scope=…` line and the `NetworkConstants` row are
the chain- and build-time roots binding the produced
transaction to the upstream pin. Read them before signing.

## 7. Sign + submit (out of scope for this CLI)

After the report and traces pass review, extract `result.tx-cbor`
from the JSON envelope and pass it to your signer (hardware wallet,
[`cardano-wallet-sign`][cws], MPC service) then
`cardano-cli transaction submit` (or any other broadcaster).
Submit within minutes — the wizard's `validityUpperBoundSlot`
ticks down with the tip.

## 8. Deterministic quote override

```bash
amaru-treasury-tx \
    --node-socket "$CARDANO_NODE_SOCKET_PATH" --network mainnet \
    swap-wizard \
        --wallet-addr addr1q... \
        --metadata metadata-mainnet.json \
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

## 9. Disburse USDM or ADA

Most operator disbursements pay USDM, so `disburse-wizard` defaults to
`--unit usdm`. `--amount` is always in the smallest unit: 1e-6 USDM
for USDM, lovelace for ADA.

```bash
amaru-treasury-tx \
    --node-socket "$CARDANO_NODE_SOCKET_PATH" --network mainnet \
    disburse-wizard \
        --wallet-addr addr1q... \
        --metadata metadata-mainnet.json \
        --scope network_compliance \
        --beneficiary-addr addr1qvendor... \
        --amount 100000000 \
        --validity-hours 6 \
        --description "Settle March vendor invoice" \
        --justification "Approved network-compliance budget line" \
        --destination-label "Vendor Ltd." \
        --log disburse-wizard.log \
  | amaru-treasury-tx \
        --node-socket "$CARDANO_NODE_SOCKET_PATH" \
        tx-build \
            --log disburse-build.log \
            --out disburse.cbor.hex
```

The example pays 100 USDM. For ADA, add `--unit ada` and pass
lovelace in `--amount`. The wizard verifies the registry anchors,
selects wallet fuel, selects treasury UTxOs, computes validity, and
emits a unified `action = "disburse"` intent for `tx-build`.

See [Disburse](disburse.md) for the existing-intent form, payload
shape, USDM selection rules, and test evidence.

## 10. Withdraw rewards

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

## 11. When something goes wrong

| Exit | Action |
|------|--------|
| 1 (tx-build) | The build aborted before producing CBOR. Expected builder failures print a normalized `tx-build: ... failed ...` diagnostic; report output, when requested, carries the same stable failure code/message. |
| 3 (swap-quote / swap-wizard / disburse-wizard / tx-build) | Setup or economic error. The trace's `ABORT …` line names the offending step: quote source failure, registry mismatch, empty wallet UTxO set, treasury affordability shortfall, beneficiary network mismatch, missing UTxOs in chain context, and similar fail-closed cases. |
| 4 (swap-wizard) | Translation error in the expert manual path. Re-check `--min-rate`, `--chunk-usdm`/`--split`, and `--validity-hours` in `[1, 48]`. |
| 6 (tx-build) | The N2C handshake reports a network magic that disagrees with the intent's `network` field. The trace's `tx-build: NETWORK MISMATCH …` line names both networks; point `--node-socket` at the right node. |

Both subcommands are fail-closed — neither writes a partial
output. If the trace ends without `cbor -> …` (or
`intent.json -> …` from the wizard), nothing was written.

Direct `swap-wizard --min-rate` remains available as an expert/manual
override for precomputed rates. That path does not create
`params.json`, so the operator must keep the external quote,
slippage, arithmetic, and affordability audit record separately.

## 12. Reproduce the known oracles (developer)

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

## 13. Smoke the signer UX and pipe contracts (developer)

Before cutting a release or handing a branch to operators, run:

```bash
nix develop --quiet -c just smoke
```

The smoke check runs the focused signer regression, checks the
release-facing help surfaces, and exercises the withdraw fixture path
through schema validation plus the synthetic CBOR golden.

## 14. Trust model

The full account of what the wizard verifies vs. what it asks
the operator to assert lives in
[Trust model](trust-model.md): bake-time and run-time
dependency graphs, the verifier's two trust roots, the
field-by-field map of where each `intent.json` value comes
from. Read it once before signing your first mainnet
transaction.

[cws]: https://github.com/lambdasistemi/cardano-wallet-sign
