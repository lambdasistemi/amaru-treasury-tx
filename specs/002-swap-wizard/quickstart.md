# Quickstart: Swap Wizard

**Plan**: [plan.md](./plan.md) · **Spec**: [spec.md](./spec.md)
**Date**: 2026-05-05

This file is the operator-facing walkthrough that ships when the
feature lands. It mirrors the steps in
`pragma-org/amaru-treasury/journal/2026/bin/swap.sh` for the input
side, then hands off to the existing `swap` subcommand for the
build.

## 1. Prerequisites

- A running cardano-node socket reachable by `Provider IO` (or your
  configured backend).
- `amaru-treasury-tx` built from the `002-swap-wizard` branch.
- Knowing your wallet bech32 address and the registry-NFT UTxO for
  your network.

## 2. Run the wizard

```bash
amaru-treasury-tx swap-wizard \
    --network preprod \
    --wallet-addr addr1q... \
    --registry-utxo <txid>#<ix> \
    --out intent.json \
    --verbose
```

The wizard:

1. Walks the registry, builds `WizardEnv`.
2. Asks the ~7 questions (scope, total ADA, chunk size, rate
   numerator/denominator, validity hours, rationale fields,
   optional signer override).
3. Prints a verbose summary of every resolved field.
4. Asks for confirmation.
5. Writes `intent.json` to the path you gave.

For scripted use, supply the answers as flags and pass `--yes`:

```bash
amaru-treasury-tx swap-wizard \
    --network preprod \
    --wallet-addr addr1q... \
    --registry-utxo <txid>#<ix> \
    --scope core \
    --amount-ada 50000000000 \
    --chunk-ada 5000000000 \
    --rate-num 425000 --rate-den 1000000 \
    --validity-hours 6 \
    --signers <hex28>,<hex28>,<hex28> \
    --out intent.json \
    --yes
```

Add `--dry-run` to print the JSON to stdout instead of writing.

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
