# Quickstart — `report-render`

Tracking issue: [#74](https://github.com/lambdasistemi/amaru-treasury-tx/issues/74)

This quickstart shows the canonical end-to-end pipeline for a swap
build with the operator-friendly Markdown rendering.

## End-to-end pipeline

```bash
swap-wizard \
    --network mainnet \
    --wallet-addr addr1... \
    --metadata journal/2026/metadata.json \
    --scope network_compliance \
    --usdm 100000.00 \
    --split 32 \
    --min-rate 0.95 \
    --validity-hours 24 \
    --description "Q2 USDM top-up" \
    --justification "Operator runway" \
    --destination-label "Treasury USDM reserve" \
  | amaru-treasury-tx tx-build --report - --out swap.cbor.hex \
  | amaru-treasury-tx report-render > report.md
```

This pipeline:

- builds the unsigned transaction (`swap.cbor.hex`),
- writes the JSON build-output envelope to stdout,
- pipes the build-output envelope into the renderer,
- writes the operator-friendly Markdown to `report.md`.

No intermediate side files. No chain access during rendering.

## Operator helper

For day-to-day swap builds, the helper wraps the pipeline:

```bash
scripts/ops/build-swop --out artefacts/ < intent.json
# produces: artefacts/swap.cbor.hex, artefacts/report.json, artefacts/report.md

scripts/ops/build-swop --out artefacts/ --no-markdown < intent.json
# produces: artefacts/swap.cbor.hex, artefacts/report.json (no report.md)
```

`--no-markdown` is the documented way to skip the Markdown
rendering when a reviewer does not want it.

## Invalid reports

A `report.json` without readable top-level `intent` and `result`
fields is not a valid input to the renderer. A success result must
also contain readable `tx-cbor` and `report` fields. The command
fails instead of accepting a separate intent file or producing a
partial report:

```bash
amaru-treasury-tx report-render --in older/report.json --out older/report.md
```

## Fixture-driven smoke check

The repository ships golden fixtures so reviewers can preview
exactly what the renderer produces:

```bash
# Full-resolution swap fixture (with metadata).
amaru-treasury-tx report-render \
    --in test/fixtures/swap/report.golden.json \
    --metadata journal/2026/metadata.json \
  | diff -u test/fixtures/swap/report.golden.md -

# No-metadata path (unresolved labels for non-built-in addresses).
amaru-treasury-tx report-render \
    --in test/fixtures/swap/report.golden.json \
  | diff -u test/fixtures/swap/report.no-metadata.golden.md -

# Invalid envelope check (missing required fields).
! amaru-treasury-tx report-render \
    --in test/fixtures/swap/report.missing-required-fields.json \
    --out /tmp/report.md
```

Each diff should be empty.

## Pre-signing review

The Markdown rendering is the **pre-signing review artefact** for
multisig reviewers. It is generated mechanically from the JSON
build-output envelope, including its inline intent, transaction CBOR,
and nested mechanical report; the JSON remains the durable
machine-readable contract. See
[`docs/report-render.md`](../../docs/report-render.md) for the full
contract.
