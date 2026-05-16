# Quickstart: DevNet Disburse Slice

Run from the repository dev shell:

```bash
nix develop --quiet
```

## RED Proof

Before implementation:

```bash
tmp="$(mktemp -d)"
scripts/smoke/devnet-local --phase disburse --run-dir "$tmp"
```

Expected current result:

```text
devnet-smoke: unknown phase: disburse
```

The command should return exit `64`, proving the phase is absent before
the implementation slice.

## GREEN Proof

After implementation:

```bash
nix develop --quiet -c just devnet-smoke disburse
```

Expected success output includes:

```text
devnet-smoke: run-dir runs/devnet/YYYYMMDDTHHMMSSZ
devnet-smoke: phase disburse passed
devnet-smoke: disburse-unit ADA
devnet-smoke: disburse-tx <txid>
devnet-smoke: disburse-summary runs/devnet/YYYYMMDDTHHMMSSZ/disburse/summary.json
```

Inspect:

```bash
jq . runs/devnet/YYYYMMDDTHHMMSSZ/disburse/summary.json
jq . runs/devnet/YYYYMMDDTHHMMSSZ/disburse/intent.json
```

The intent must contain `action = "disburse"`, the beneficiary address,
the selected treasury input references, the selected unit and amount,
and a validity upper bound. The build artifacts must include unsigned
CBOR and JSON/Markdown reports. USDM must be represented either by
successful USDM fields or by a typed missing-token/setup diagnostic in
`disburse/usdm-boundary.json`.
