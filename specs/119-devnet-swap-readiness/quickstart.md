# Quickstart: DevNet Swap Contract Readiness

Run from the repository dev shell:

```bash
nix develop --quiet
```

## RED Proof

Before implementation, write the focused readiness test and run:

```bash
nix develop --quiet -c cabal test devnet-tests -O0 \
  --test-show-details=direct \
  --test-option=--match \
  --test-option='swap-ready readiness'
```

The initial failure is expected: the current harness has no `swap-ready`
phase or readiness artifact contract.

## GREEN Proof

After implementation:

```bash
nix develop --quiet -c just devnet-smoke swap-ready
```

Expected output includes:

```text
devnet-smoke: run-dir runs/devnet/YYYYMMDDTHHMMSSZ
devnet-smoke: phase swap-ready passed
devnet-smoke: swap-ready-order-script-hash <28-byte-hex>
devnet-smoke: swap-ready-order-script-ref <txid>#<ix>
devnet-smoke: swap-ready-registry runs/devnet/YYYYMMDDTHHMMSSZ/swap-ready/registry.json
```

Inspect:

```bash
jq . runs/devnet/YYYYMMDDTHHMMSSZ/swap-ready/registry.json
```

The registry is the handoff to #84. It proves only that the local DevNet
has the required order-validator reference information. It does not
prove that an order was built, funded, submitted, or spent.
