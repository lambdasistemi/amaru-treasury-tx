# Quickstart: Swap Wizard

**Plan**: [plan.md](./plan.md) · **Spec**: [spec.md](./spec.md)
**Date**: 2026-05-05

> **Updated by feature 005** (unified `tx-build`). Use
> [`docs/quickstart.md`](../../docs/quickstart.md) on the
> published docs site for the operator-facing walkthrough on
> the unified shape; this page is preserved as the spec-trail
> for feature 002, with examples retargeted to `| tx-build`.

This is the operator-facing walkthrough. It mirrors the input
side of `pragma-org/amaru-treasury/journal/2026/bin/swap.sh`,
then hands off to the unified `tx-build` subcommand to produce
the unsigned Conway transaction CBOR — all in one pipe.

## 1. Prerequisites

- A running cardano-node socket reachable by the local-node
  `Provider` (preprod or mainnet).
- Your wallet bech32 address (the wallet must hold a pure-ADA
  UTxO to use as fuel + collateral).
- A local `journal/2026/metadata.json`-shaped file. The wizard
  treats it as an untrusted hint and verifies the consumed
  registry anchors against the local node before building an
  intent. Fetch the upstream pin once:

  ```bash
  curl -fsSL https://raw.githubusercontent.com/pragma-org/amaru-treasury/main/journal/2026/metadata.json \
      -o metadata-mainnet.json
  ```

You don't need a local checkout; the binary is published from
the `002-swap-wizard` branch flake. Set `EXE` once and reuse it:

```bash
EXE='nix run github:lambdasistemi/amaru-treasury-tx/002-swap-wizard#amaru-treasury-tx --'
```

## 2. The famous swap, end to end

The full pipeline — wizard → intent.json on stdout → tx-build →
hex CBOR on `--out` — is one command. The exact mainnet
parameters that produce a 33-chunk USDM swap valid for 28
hours from the current tip:

```bash
$EXE \
    --node-socket /code/cardano-mainnet/ipc/node.socket \
    --network mainnet \
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
  | $EXE \
        --node-socket /code/cardano-mainnet/ipc/node.socket \
        tx-build \
            --log build.log \
            --out swap.cbor.hex
```

`tx-build` reads the network from the intent's top-level
`network` field — there is no `--network` flag on the build
side (single source of truth). On a magic mismatch between
the socket and the intent it exits 6 before any chain query.

What lands where:

| Stream | Contents |
|---|---|
| `wizard.log` (or stderr if `--log` omitted) | Wizard's `swap-wizard:`-prefixed trace lines, one per value-affecting step |
| pipe between the two commands | The unified `intent.json` payload (JSON), wizard stdout → tx-build stdin |
| `build.log` (or stderr) | Build's `tx-build:`-prefixed trace lines: source, parsed, network ok / mismatch, connect, built, re-eval, validation |
| `swap.cbor.hex` | The unsigned Conway transaction as hex |

Every flag has a sensible default for the non-pipe case:

- Drop `--out` from the wizard to write `intent.json` to stdout
  (this is what the pipe relies on).
- Drop `--intent` from `tx-build` to read the intent from stdin
  (also what the pipe relies on).
- Drop `--log` from either to send the trace to stderr.

## 3. Reading the trace

Every line that affects the produced tx is one event. With
`--log wizard.log` the wizard writes:

```
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
```

…and the build writes:

```
tx-build: intent <- stdin
tx-build: parsed action=Swap network=mainnet
tx-build: connecting to /code/cardano-mainnet/ipc/node.socket
tx-build: required utxos: 6
tx-build: handshake ok (magic 764824073 matches intent network=mainnet)
tx-build: built 15240 bytes  fee=1025037  total_collateral=1537556
tx-build: re-evaluated 2 redeemers, 0 failed
tx-build: cbor -> swap.cbor.hex
tx-build: VALIDATION OK
```

Operators read this trace as the audit gate before signing.
`VERIFIED scope=… permissionsRewardAccount=…` and the
`NetworkConstants` row are the chain- and build-time roots
binding the produced transaction to the upstream pin.

## 4. Sign + submit

The pipeline emits hex CBOR; sign it with the configured scope
owner's key plus the witness owner keys named with
`--extra-signer` (or the `--signer` compatibility alias) and
submit per your existing operator runbook.

## 5. Doing it without the pipe

If you prefer two separate steps, use the same flags but write
to a file in between:

```bash
$EXE swap-wizard ... --out intent.json
$EXE tx-build --intent intent.json --out swap.cbor.hex
```

## 6. When something goes wrong

| Exit | Action |
|------|--------|
| 1 (tx-build) | The build aborted before producing CBOR. The trace's `ABORT` line names the cause: bad intent JSON, translation error, validation failure on a re-evaluated redeemer. |
| 3 (swap-wizard / tx-build) | Setup error. Check `--metadata`, local node sync, wallet fuel UTxO, treasury UTxOs. The trace's `ABORT` line names the offending step. |
| 4 (swap-wizard) | Translation error. Re-check `--min-rate`, `--chunk-usdm`/`--split`, `--validity-hours` in [1, 48]. |
| 6 (tx-build) | The N2C handshake reports a network magic that disagrees with the intent's `network` field. The trace's `NETWORK MISMATCH` line names both networks; point `--node-socket` at the right node. |

Both subcommands are fail-closed — neither writes a partial
output. If the trace ends without `cbor -> …` (or
`intent.json -> …` from the wizard), nothing was written.

## 7. Verifying the wizard (developer)

```bash
just unit     # SwapWizardSpec golden + roundtrip
just golden   # existing swap golden harness
just smoke    # focused signer UX smoke + CLI help surface
```

A wizard regression breaks `SwapWizardSpec`; a translation
regression breaks the swap golden. A signer UX regression breaks the
smoke check before a release artifact is published.
