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
        --ada-usdm 0.270 \
        --slippage-bps 100 \
        --validity-hours 28 \
        --description "Swapping ADA for \$100k against an operator-supplied ADA/USDM quote" \
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
| `--all-ada`    | Alternative to `--usdm`. Spend the maximum ledger-valid ADA from pure ADA treasury UTxOs in the selected scope. Requires `--split`; incompatible with `--chunk-usdm`. |
| `--split N`    | Slice the order into N equal chunks. Use `--chunk-usdm X` instead to pin per-chunk size. |
| `--ada-usdm`   | Operator-supplied ADA/USDM quote (USDM per ADA). The wizard applies slippage on top. For live retrieval, use the separate `swap-quote` command. |
| `--slippage-bps` | Required slippage policy in basis points. There is no hidden default. |
| `--min-rate`   | Expert path: pre-validated minimum USDM per ADA. Bypasses slippage. |
| `--validity-hours` | Optional. Omit to use the chain's current horizon (longest plutus-translatable slot). When present, must be inside the horizon — overshoot returns a typed wizard error before `tx-build` runs. |
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

For a remaining-ADA swap, replace `--usdm 100000` with `--all-ada`
and keep `--split N`. The wizard uses verified metadata and live
treasury UTxOs to select pure ADA only, reserves the per-order
Sundae overhead plus the minimum treasury leftover, and logs the
computed ADA amount plus implied USDM target before emitting the
intent.

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
tx-build: built 14987 bytes  fee=1041155  total_collateral=1561733
tx-build: re-evaluated 2 redeemers, 0 failed
tx-build: cbor -> /dev/null
tx-build: VALIDATION OK
```

The `VERIFIED scope=…` line and the `NetworkConstants` row are
the chain- and build-time roots binding the produced
transaction to the upstream pin. Read them before signing.

## 7. Sign + submit

After the report and traces pass review, extract `result.tx-cbor`
from the JSON envelope and create the required detached witnesses.
External signers such as hardware wallets, [`cardano-wallet-sign`][cws],
or MPC services can still feed `attach-witness` directly.

Create an encrypted age vault once from the Cardano signing-key
material, then use the built-in `witness` command for signing. Humans
should use `--signing-key-paste`; the pasted signing-key material is
hidden while the CLI reads it, and the vault passphrase prompt is
no-echo too.

Treat `vault create` as the import ceremony: pasted or streamed
signing-key material is the only plaintext key input, and normal
signing after this point uses `treasury.vault.age` plus the passphrase.
Accepted input is either a `cardano-cli` `.skey` JSON envelope or one
`cardano-addresses` address extended signing key line beginning
`addr_xsk1`. After verifying and backing up the encrypted vault, clear
the clipboard or source buffer under your custody policy.

```bash
amaru-treasury-tx --network mainnet vault create \
    --signing-key-paste \
    --label core_development \
    --out treasury.vault.age

# Paste either the full cardano-cli .skey JSON or the addr_xsk1... line.
# The pasted bytes are hidden.
```

The `addr_xsk1...` input is the address-level extended signing key
format produced by `cardano-addresses`, not a root or account private
key. Paste the single bech32 line exactly as exported by the custody
tool.

For automation, stream the signing key from a secret manager and pass the
vault passphrase through an inherited file descriptor:

```bash
exec 9<<<"$VAULT_PASSPHRASE"

secret-manager-read core-development-payment-skey \
| amaru-treasury-tx --network mainnet vault create \
    --signing-key-stdin \
    --label core_development \
    --out treasury.vault.age \
    --vault-passphrase-fd 9

exec 9<&-
exec 9<<<"$VAULT_PASSPHRASE"
```

The transaction passed to `witness --tx` may be either raw Conway CBOR
hex or a `cardano-cli` `Tx ConwayEra` JSON envelope. If the transaction
comes from `cardano-cli`, put the full JSON envelope in a file and pass
that file directly to `witness`; do not paste the JSON interactively
into `de-envelope`.

```bash
jq -e . cli.tx.body.json >/dev/null
test "$(jq -r .cborHex cli.tx.body.json | wc -l | tr -d ' ')" = 1
```

That check confirms the envelope parses as JSON and that `cborHex`
contains one logical line. Terminal or browser visual wrapping is fine;
real newlines inside the JSON string are not.

```bash
amaru-treasury-tx --network mainnet witness \
    --tx unsigned.cbor.hex \
    --vault treasury.vault.age \
    --vault-passphrase-fd 9 \
    --identity core_development \
    --out core_development.witness.hex

exec 9<&-

owner_witness_hex="$(
  tr -d '\n' < core_development.witness.hex
)"

amaru-treasury-tx attach-witness \
    --tx unsigned.cbor.hex \
    --witness "$owner_witness_hex" \
    --out signed.cbor.hex

amaru-treasury-tx --network mainnet submit --tx signed.cbor.hex
```

For a `cardano-cli` envelope input, replace `--tx unsigned.cbor.hex`
with `--tx cli.tx.body.json` in the `witness` command above. Before
`attach-witness`, unwrap the same envelope once because `attach-witness`
uses the raw CBOR-hex contract:

```bash
amaru-treasury-tx de-envelope < cli.tx.body.json > unsigned.cbor.hex
```

If the transaction does not declare required signer hashes, add
`--expected-key-hash HASH` or the explicit `--allow-unlisted-key`
acknowledgement. Submit within minutes — the wizard's
`validityUpperBoundSlot` ticks down with the tip.

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
        --ada-usdm 0.270 \
        --slippage-bps 100 \
        --validity-hours 28 \
        --description "Swapping ADA for \$100k against an operator-supplied ADA/USDM quote" \
        --justification "Required to pay Antithesis as vendor" \
        --destination-label "Network Compliance's treasury" \
        --extra-signer core_development
```

For a live ADA/USDM quote, use the `swap-quote` command (it owns the
outbound HTTP). The wizard itself does no outbound HTTP after #110.

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
| 4 (swap-wizard) | Translation error in the expert manual path. Re-check `--min-rate`, `--chunk-usdm`/`--split`. `--validity-hours`, when present, must be inside the current chain horizon — the wizard returns a typed `WizardValidityOvershoot` if not. |
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
release-facing help surfaces, exercises the vault-backed witness path,
including hidden paste and no-echo passphrase prompts, and exercises
the withdraw fixture path through schema validation plus the synthetic
CBOR golden.

## 14. Trust model

The full account of what the wizard verifies vs. what it asks
the operator to assert lives in
[Trust model](trust-model.md): bake-time and run-time
dependency graphs, the verifier's two trust roots, the
field-by-field map of where each `intent.json` value comes
from. Read it once before signing your first mainnet
transaction.

[cws]: https://github.com/lambdasistemi/cardano-wallet-sign
