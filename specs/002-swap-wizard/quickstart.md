# Quickstart: Swap Wizard

**Plan**: [plan.md](./plan.md) · **Spec**: [spec.md](./spec.md)
**Date**: 2026-05-05

This file is the operator-facing walkthrough that ships when the
feature lands. It mirrors the steps in
`pragma-org/amaru-treasury/journal/2026/bin/swap.sh` for the input
side, then hands off to the existing `swap` subcommand for the
build.

## 1. Prerequisites

- A running cardano-node socket reachable by the local-node
  `Provider` (preprod or mainnet).
- `amaru-treasury-tx` built from the `002-swap-wizard` branch
  (e.g. `nix build .#default`).
- Your wallet bech32 address (the wallet must hold a pure-ADA UTxO
  to use as fuel + collateral).
- A `registry.json` file describing the registry refs, scope owner
  key hashes, and per-scope treasury addresses. A working preprod
  example is checked in at
  [`test/fixtures/swap-wizard/registry.example.json`](../../test/fixtures/swap-wizard/registry.example.json) —
  copy it and adapt to your network/scope state.

> **MVP note**: the v1 resolver does *not* walk the registry NFT
> on-chain. It loads the file you pass via `--registry`. The
> on-chain walk is tracked as a follow-up.

## 2. Run the wizard

```bash
amaru-treasury-tx \
    --node-socket /path/to/node.socket \
    --network-magic 764824073 \
    swap-wizard \
    --wallet-addr addr1q802wxt6cg6aw0nl0vdzfxavu65rxu3yzhvgayw7chfxymduzkt66uw9t5kspx5jwjecx80dz4g33htknafhdhkvzd5st4f9xu \
    --registry test/fixtures/swap-wizard/registry.example.json \
    --scope core_development \
    --ada 408163.265306 \
    --chunk-ada 12500 \
    --min-rate 0.245 \
    --validity-hours 6 \
    --description 'Swapping ADA for $100k at a rate of $0.245 per ADA' \
    --justification 'Required to pay Antithesis as vendor' \
    --destination-label "Network Compliance's treasury" \
    --signer f3ab64b0f97dcf0f91232754603283df5d75a1201337432c04d23e2e \
    --signer 8bd03209d227956aaf9670751e0aa2057b51c1537a43f155b24fb1c1 \
    --out intent.json \
    --verbose --yes
```

The above recreates the existing mainnet swap golden in
[`test/fixtures/swap/intent.json`](../../test/fixtures/swap/intent.json).
Substitute `--chunks N` if you'd rather the wizard compute the
per-chunk size from a chunk count.

The wizard:

1. Loads the registry view from `--registry`.
2. Connects to the node, resolves wallet + treasury UTxOs and the
   current chain tip.
3. With `--verbose`, prints a summary of every resolved field on
   stderr.
4. Asks for confirmation (skipped under `--yes`).
5. Writes `intent.json` to the path given to `--out`.

`--dry-run` prints the JSON to stdout instead of writing the file.
`--force` overwrites an existing `--out` path; without it, exit 5.

## 3. Build the swap transaction

The wizard's only output is the JSON file. Hand it to the existing
subcommand:

```bash
amaru-treasury-tx swap \
    --intent intent.json \
    --out swap.tx.cbor
```

Sign and submit out-of-band per the existing operator runbook.

## 4. Verifying the wizard

Two checks the operator can run without touching chain state:

**JSON round-trip**

```bash
amaru-treasury-tx swap-wizard ... --dry-run \
    | amaru-treasury-tx swap --intent /dev/stdin --out /tmp/swap.tx.cbor
```

If `swap` accepts the JSON without errors the wizard's translation
matches the existing schema.

**Golden parity (developer)**

```bash
just unit  # runs SwapWizardSpec golden + roundtrip tests
just golden  # runs the existing swap golden harness
```

A wizard regression breaks `SwapWizardSpec`; a translation
regression breaks the swap golden.

## 5. When something goes wrong

| Exit | Action |
|------|--------|
| 1 | You answered "no" at confirmation. Re-run. |
| 3 | Resolver error. Check `--registry-utxo` is correct, the wallet has a pure-ADA UTxO, and the treasury has UTxOs. |
| 4 | Translation error. Re-check `--rate-den` is non-zero, `--chunk-ada` ≤ `--amount-ada`, validity hours in [1, 48]. |
| 5 | `--out` exists. Move it or pass `--force`. |

The wizard never writes a partial JSON. Either the file is complete
or it does not exist.
