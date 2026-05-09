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
- writes the JSON report (now carrying the inline intent) to stdout,
- pipes the JSON report into the renderer,
- writes the operator-friendly Markdown to `report.md`.

No intermediate side files. No chain access during rendering.

## Operator helper

For day-to-day swap builds, the helper wraps the pipeline:

```bash
scripts/ops/build-swop --intent intent.json --out artefacts/
# produces: artefacts/swap.cbor.hex, artefacts/report.json, artefacts/report.md

scripts/ops/build-swop --intent intent.json --out artefacts/ --no-markdown
# produces: artefacts/swap.cbor.hex, artefacts/report.json (no report.md)
```

`--no-markdown` is the documented way to skip the Markdown
rendering when a reviewer does not want it.

## Re-rendering an older report

A `report.json` written before this feature does not carry the
inline intent. The renderer still renders it, with the swap-deal
section omitted and a one-line note explaining why:

```bash
cat older/report.json | amaru-treasury-tx report-render > older/report.md
```

To re-render an older report against a current intent file, use
the override:

```bash
amaru-treasury-tx report-render \
    --in older/report.json \
    --intent current/intent.json \
    --out older/report.md
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

# `--no-intent` opt-out (swap-deal section omitted).
amaru-treasury-tx report-render \
    --in test/fixtures/swap/report.golden.json \
    --metadata journal/2026/metadata.json \
    --no-intent \
  | diff -u test/fixtures/swap/report.no-intent.golden.md -
```

Each diff should be empty.

## Pre-signing review

The Markdown rendering is the **pre-signing review artefact** for
multisig reviewers. It is generated mechanically from the JSON
report and the metadata; the JSON remains the durable
machine-readable contract. See [`docs/report-render.md`](../../docs/report-render.md)
for the full contract.
