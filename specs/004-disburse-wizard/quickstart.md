# Quickstart: Disburse Wizard

**Plan**: [plan.md](./plan.md) · **Spec**: [spec.md](./spec.md)
**Date**: 2026-05-06

This is the operator-facing walkthrough. It mirrors the input side of
[`pragma-org/amaru-treasury/journal/2026/bin/disburse.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/bin/disburse.sh),
then hands off to the unified `tx-build` subcommand to produce the
unsigned Conway transaction CBOR from the action-keyed
`TreasuryIntent` JSON — all in one pipe.

## 1. Prerequisites

- A running cardano-node socket reachable by the local-node
  `Provider` (preprod or mainnet).
- Your wallet bech32 address (the wallet must hold a pure-ADA UTxO to
  use as fuel + collateral).
- The beneficiary's bech32 address (must be on the same network).
- A local `journal/2026/metadata.json`-shaped file. The wizard treats
  it as an untrusted hint and verifies the consumed registry anchors
  against the local node before resolving the intent. Fetch the
  upstream pin once:

  ```bash
  curl -fsSL https://raw.githubusercontent.com/pragma-org/amaru-treasury/main/journal/2026/metadata.json \
      -o metadata-mainnet.json
  ```

You don't need a local checkout; the binary is published from the
`004-disburse-wizard` branch flake. Set `EXE` once and reuse it:

```bash
EXE='nix run github:lambdasistemi/amaru-treasury-tx/004-disburse-wizard#amaru-treasury-tx --'
```

## 2. ADA disburse, end to end

Pay 50 ADA from the `core_development` scope to a vendor, co-signed
by the `ops_and_use_cases` scope owner, valid for 6 hours from the
current tip:

```bash
$EXE \
    --node-socket /code/cardano-mainnet/ipc/node.socket \
    --network mainnet \
    disburse-wizard \
        --wallet-addr addr1q802wxt6cg6aw0nl0vdzfxavu65rxu3yzhvgayw7chfxymduzkt66uw9t5kspx5jwjecx80dz4g33htknafhdhkvzd5st4f9xu \
        --metadata metadata-mainnet.json \
        --scope core_development \
        --beneficiary-addr addr1q9vendor… \
        --unit ada \
        --amount 50000000 \
        --validity-hours 6 \
        --description "Q2 vendor invoice — translation services" \
        --justification "Per CIP-1694 budget allocation for the period" \
        --destination-label "ACME Translations Ltd." \
        --extra-signer ops_and_use_cases \
        --log wizard.log \
  | $EXE \
        --node-socket /code/cardano-mainnet/ipc/node.socket \
        tx-build \
            --log build.log \
            --out disburse.cbor.hex
```

What lands where:

| Stream | Contents |
|---|---|
| `wizard.log` (or stderr if `--log` omitted) | Wizard's `disburse-wizard:`-prefixed trace events, one per value-affecting step |
| pipe between the two commands | The `intent.json` payload (JSON), wizard stdout → builder stdin |
| `build.log` (or stderr) | Builder's `tx-build:`-prefixed trace events: source, parsed action/network, connect, build, re-eval, validation |
| `disburse.cbor.hex` | The unsigned Conway transaction as hex |
| `disburse.summary.json` | Summary sidecar with txid, fee, ExUnits per redeemer once Phase 7 lands |

Every flag has a sensible default for the non-pipe case:

- Drop `--out` from the wizard to write `intent.json` to stdout (this
  is what the pipe relies on).
- Drop `--intent` from `tx-build` to read the intent from stdin (also
  what the pipe relies on).
- Drop `--log` from either to send the trace to stderr.

## 3. USDM disburse

Same shape, different `--unit` and `--amount`. Pay 100 USDM (i.e.
`100000000` smallest units, USDM has 6 decimals) from
`network_compliance`:

```bash
$EXE \
    --node-socket /code/cardano-mainnet/ipc/node.socket \
    --network mainnet \
    disburse-wizard \
        --wallet-addr addr1q802… \
        --metadata metadata-mainnet.json \
        --scope network_compliance \
        --beneficiary-addr addr1q9vendor… \
        --unit usdm \
        --amount 100000000 \
        --validity-hours 6 \
        --description "Settle Antithesis March invoice" \
        --justification "Per network-compliance budget for vendor X" \
        --destination-label "Antithesis Inc." \
        --log wizard.log \
  | $EXE \
        --node-socket /code/cardano-mainnet/ipc/node.socket \
        tx-build \
            --log build.log \
            --out disburse.cbor.hex
```

The wizard:

- Selects treasury UTxOs sorted by USDM quantity (largest-first).
- Sets the beneficiary output value to `100 USDM + getMinCoinTxOut`
  lovelace.
- Routes every spent ADA + leftover USDM + every other spent asset
  into the leftover treasury output.

## 4. Reading the trace

Every line that affects the produced tx is one event. With `--log
wizard.log` the wizard writes:

```
disburse-wizard: network mainnet (magic 764824073)
disburse-wizard: metadata = metadata-mainnet.json
disburse-wizard: VERIFIED scope=core_development treasury=addr1xyezq8w… treasuryScriptHash=32201dc1… registryPolicyId=38c627d4… permissionsRewardAccount=a64d1b9e…
disburse-wizard: owners core=7095faf3… ops=f3ab64b0… network_compliance=8bd03209… middleware=97e0f6d6…
disburse-wizard: wallet utxos: 3
disburse-wizard: treasury utxos: 4 (total 1450000000000 lovelace)
disburse-wizard: tip slot 186446659
disburse-wizard: NetworkConstants usdmPolicy=c48cbb3d… usdmToken=0014df105553444d
disburse-wizard: wallet utxo selected 42e4c279…#0
disburse-wizard: treasury utxos selected 64f27254…#0 leftoverLov=1399999500000 leftoverUsdm=0
disburse-wizard: validity tip=186446659 upperBound=186468259 (+21600 slots)
disburse-wizard: intent.json -> stdout
```

…and the builder writes:

```
tx-build: intent <- stdin
tx-build: parsed action=Disburse network=mainnet
tx-build: connecting to /code/cardano-mainnet/ipc/node.socket
tx-build: handshake ok (magic 764824073 matches intent network=mainnet)
tx-build: required utxos: 7
tx-build: built 4920 bytes  fee=215037  total_collateral=322556
tx-build: re-evaluated 2 redeemers, 0 failed
tx-build: cbor -> disburse.cbor.hex
tx-build: VALIDATION OK
```

Operators read this trace as the audit gate before signing.
`VERIFIED scope=… permissionsRewardAccount=…` and the
`NetworkConstants` row are the chain- and build-time roots binding
the produced transaction to the upstream pin.

## 5. Sign + submit

The pipeline emits hex CBOR; sign it with:

- The selected scope's owner key (always required, inferred by the
  wizard).
- Each witness owner key declared via `--extra-signer` (or the
  `--signer` compatibility alias).
- Your wallet key for the fuel input.

Submit per your existing operator runbook. `tx-build` does not sign
or submit (Constitution IV).

## 6. Doing it without the pipe

If you prefer two separate steps, use the same flags but write to a
file in between:

```bash
$EXE disburse-wizard ... --out intent.json
$EXE --node-socket /code/cardano-mainnet/ipc/node.socket \
    tx-build --intent intent.json --out disburse.cbor.hex
```

## 7. When something goes wrong

| Exit | Action |
|------|--------|
| 1 (tx-build) | One or more redeemers failed re-evaluation. The trace captures the per-script failure detail; CBOR is still emitted for inspection. |
| 3 (tx-build) | Intent JSON parse, required-UTxO, or build setup failure. Check the JSON shape against [`disburse-intent-json.md`](./contracts/disburse-intent-json.md). |
| 6 (tx-build) | `intent.network` does not match the local-node socket's network magic. |
| 3 (disburse-wizard) | Resolver error. Check `--metadata`, local node sync, wallet fuel UTxO, treasury UTxOs, beneficiary address network. |
| 4 (disburse-wizard) | Translation error (`DisburseError`). Re-check `--unit`, `--amount`, `--validity-hours` in [1, 48]. |

Both subcommands are fail-closed — neither writes a partial output.
If the trace ends without `cbor -> …` (or `intent.json -> …` from the
wizard), nothing was written.

## 8. Verifying the wizard (developer)

```bash
just unit     # DisburseSpec / schema conformance / resolver specs
just golden --test-options=--match=ada-disburse
              # ADA body-CBOR golden via unified tx-build path
just smoke    # focused signer + pipe smoke
```

A wizard regression breaks `DisburseWizardSpec`; a translation
regression breaks the unified schema tests or the body-CBOR golden.
A signer UX regression breaks the smoke check before a release
artifact is published.

## 9. Validating on preprod (recorded smoke)

After 004 lands, the live smoke proceeds against preprod:

1. Fund a preprod wallet with ~100 ADA.
2. Re-run §2 against `--network preprod` and the preprod
   `metadata.json` (when published) or a local fixture pinned for
   that purpose.
3. Sign + submit; observe `cardano-cli query tx-mempool …` until the
   tx is on chain.
4. Promote the recorded fixtures to a checked-in preprod golden if
   the team agrees the value of an additional golden outweighs its
   maintenance cost.

This step is its own follow-up issue; it does not gate 004.
