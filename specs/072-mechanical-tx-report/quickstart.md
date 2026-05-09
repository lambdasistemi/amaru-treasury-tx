# Quickstart: Mechanical Transaction Report

**Plan**: [plan.md](./plan.md) | **Spec**: [spec.md](./spec.md)
**Date**: 2026-05-09

This quickstart describes the intended operator flow after the feature
ships.

## Build with a report

```bash
amaru-treasury-tx \
  --node-socket "$CARDANO_NODE_SOCKET_PATH" \
  tx-build \
    --intent intent.json \
    --out swap.cbor.hex \
    --report swap.report.json \
    --log build.log
```

Expected successful artifacts:

- `swap.cbor.hex`: unsigned Conway transaction CBOR as hex.
- `swap.report.json`: deterministic pre-signing review report.
- `build.log`: typed `tx-build:` trace events.

## Review before signing

Before handing `swap.cbor.hex` to any signer, inspect
`swap.report.json` for:

- wallet net spend and fee;
- collateral input, total collateral, and collateral return;
- treasury input total, Sundae order totals, per-chunk overhead, and
  treasury leftover;
- every produced output role;
- required signer key hashes and their mechanical sources;
- validation facts: network match, body size, redeemer count, zero
  redeemer failures, and validity interval.

For the treasury-funded-overhead swap fixture, the report must show:

```text
walletAccounting.netSpendLovelace == validation.feeLovelace
validation.redeemerFailures == 0
validation.validationStatus == "ok"
```

The report is generated mechanically by the executable from the same
build data that produced the unsigned CBOR. It is not LLM-written
analysis and is not a substitute for signing policy.

## No report requested

Existing usage remains valid:

```bash
amaru-treasury-tx tx-build --intent intent.json --out swap.cbor.hex
```

When `--report` is omitted, no report file is written and existing CBOR
and trace behavior remains unchanged.

## Write failure

If a report path is requested but cannot be written, the command must
exit non-zero and name the failed report path. Operators should treat
the build as incomplete until both the unsigned CBOR and requested
report artifact exist.

