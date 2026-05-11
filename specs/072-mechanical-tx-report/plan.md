# Implementation Plan: Mechanical Transaction Report

**Branch**: `072-mechanical-tx-report` | **Date**: 2026-05-09 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from [`specs/072-mechanical-tx-report/spec.md`](./spec.md)
**Tracking issue**: [#72](https://github.com/lambdasistemi/amaru-treasury-tx/issues/72)
**Pull request**: [#73](https://github.com/lambdasistemi/amaru-treasury-tx/pull/73)

## Summary

Add an optional mechanically generated JSON report to successful
`tx-build` runs. The report is requested with an explicit destination,
is written only after the transaction builds and redeemers re-evaluate
successfully, and is generated entirely from Haskell data already used
by the builder: parsed intent, translated intent, resolved UTxOs,
balanced transaction body, fee/collateral fields, signer hashes,
reference inputs, output values, and validation results.

The feature does not sign, submit, or change transaction semantics.
When no report destination is supplied, existing `tx-build` behavior
stays unchanged. When a report destination is supplied and cannot be
written, `tx-build` exits non-zero rather than producing a "successful"
build missing the requested review artifact.

The report JSON is a public contract. The implementation will include a
checked-in JSON Schema, executable schema validation, and a swap golden
report fixture. The swap golden proves the issue's key operator claim:
for the treasury-funded-overhead success path, wallet net spend equals
the transaction fee and returned collateral is not double-counted.

## Technical Context

**Language/Version**: Haskell, GHC 9.6+.

**Primary Dependencies**:

- Existing `app/amaru-treasury-tx/Main.hs` `tx-build` CLI parser and
  runner.
- Existing `Amaru.Treasury.IntentJSON` parsed intent and
  `translateIntent` result.
- Existing `Amaru.Treasury.Build` build runners and
  `BuildResult`.
- Existing `Amaru.Treasury.ChainContext` / fixture helpers for
  resolved UTxO values.
- Existing `aeson`, `aeson-pretty`, `jsonschema`, `hspec`, and golden
  test suites.

**Storage**: filesystem JSON artifact at the operator-supplied report
path; no database or persistent service state.

**Testing**:

- Unit tests for report encoding, deterministic key order, output role
  coverage, wallet accounting, treasury accounting, signer sources, and
  write-failure handling.
- Contract test validating report examples and the swap golden report
  against a checked-in JSON Schema.
- Golden test for the frozen swap fixture report, including a direct
  assertion that wallet net spend equals fee on the success path.
- Documentation check through the existing docs/format gate.

**Target Platform**: existing CLI platforms, Linux CI and macOS
developer machines.

**Project Type**: Haskell CLI tool plus library modules and tests.

**Performance Goals**: report generation is linear in transaction
inputs/outputs/redeemers and must not add node queries after the
successful build. It should be negligible relative to local-node
queries and script evaluation.

**Constraints**:

- Preserve the build/no-signing boundary from the constitution and
  spec exclusions.
- Preserve the pure builder boundary: the report model and accounting
  functions are pure over build data; file writing stays in
  `app/Main.hs`.
- Preserve existing no-report behavior for `tx-build`.
- Do not use LLM-generated explanation or hand-authored interpretive
  prose in the report; labels and sources come from structured build
  facts.
- Include every produced output exactly once, using `unknown`/`other`
  for anything not mechanically classified.
- Keep report bytes deterministic: stable field ordering, stable list
  ordering from ledger order or canonical sorted keys, trailing newline,
  and no wall-clock/random/local-machine fields.

**Scale/Scope**:

- One new report module family under `lib/Amaru/Treasury/Report/`.
- One new report schema generator or checked contract asset under
  `docs/assets/`.
- Small `BuildResult` extension so callers can inspect the
  final balanced transaction body and translated build context without
  re-decoding CBOR.
- One `tx-build` CLI option for the report destination.
- Golden fixture additions under `test/fixtures/swap/`.
- Focused docs updates in swap/quickstart flows.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Faithful port of bash recipes | PASS | The report is a post-build artifact. It does not alter redeemers, datums, metadata, output ordering, fees, collateral, or CBOR bytes. Golden CBOR fixtures remain the transaction-shape gate. |
| II. Pure builders, impure shell | PASS | Report construction and accounting are pure over parsed/translated intent, `ChainContext`, and final build result. Only CLI argument parsing and `ByteString.writeFile` are impure. |
| III. Pluggable data source, local-node default | PASS | The report uses the already-resolved `ChainContext` gathered by `tx-build`; it does not introduce a backend-specific query path. |
| IV. Build, never sign or submit | PASS | The feature adds a pre-signing review artifact only. It does not handle keys, signatures, submission, or post-submit state. |
| V. Test-first with golden CBOR fixtures | PASS | Golden CBOR fixtures stay unchanged. The feature adds a separate golden JSON report and schema validation, plus a wallet-net-spend equals fee assertion for the swap success fixture. |
| VI. Hackage-ready Haskell | PASS | New exports need Haddock, explicit export lists, fourmolu-compatible formatting, and must pass the existing `just build`, unit, golden, format, hlint, and release checks. |

No violations. Complexity Tracking is intentionally omitted.

## Project Structure

### Documentation (this feature)

```text
specs/072-mechanical-tx-report/
|-- plan.md
|-- research.md
|-- data-model.md
|-- quickstart.md
|-- contracts/
|   `-- tx-report-json.md
|-- checklists/
|   `-- requirements.md
`-- tasks.md             # Created later by /speckit.tasks
```

### Source Code (repository root)

```text
lib/Amaru/Treasury/
|-- Report.hs                         # Public report API, stable encoder.
|-- Report/
|   |-- Accounting.hs                 # Pure wallet/treasury accounting.
|   |-- Classify.hs                   # Produced-output role classifier.
|   `-- Schema.hs                     # JSON Schema generator/asset source.
|-- Build.hs                  # Extend result with final tx/body data
|                                      # needed by report construction.
`-- Build/Trace.hs            # Add report-write trace events.

app/amaru-treasury-tx/
`-- Main.hs                           # Add --report PATH, build report
                                       # after validation succeeds, fail
                                       # non-zero on requested write failure.

docs/
|-- assets/tx-report-schema.json      # Machine-readable report contract.
|-- quickstart.md                     # Pre-signing report review step.
`-- swap.md                           # Swap-specific report walkthrough.

test/fixtures/swap/
`-- report.golden.json                # Deterministic swap report fixture.

test/unit/Amaru/Treasury/
|-- ReportSpec.hs                     # Encoder/accounting/classifier tests.
`-- ReportSchemaSpec.hs               # Schema drift + fixture validation.

test/golden/
`-- SwapGoldenSpec.hs                 # Build report for frozen swap fixture
                                       # and compare bytes to golden JSON.
```

**Structure Decision**: Keep report construction in the library and
report file I/O in the executable. This matches the constitution's
"pure builders, impure shell" rule and keeps report accounting
testable without a live node. Use a new `Report` module family instead
of expanding the older `Summary` sidecar because the issue requires a
broader pre-signing audit contract with accounting, output roles,
signer sources, and validation facts.

## Contract And Proof Strategy

The JSON contract lives in `docs/assets/tx-report-schema.json` and is
described in [`contracts/tx-report-json.md`](./contracts/tx-report-json.md).
It is versioned independently with a report `schema` integer so future
tooling can reject unknown shapes explicitly.

Executable proof:

- `just schema-check` or an equivalent repo gate validates the checked
  schema asset is in sync with the Haskell schema source.
- Unit tests validate representative report values against the schema.
- The swap golden test writes/compares
  `test/fixtures/swap/report.golden.json`.
- The swap golden test asserts:
  `wallet.netSpendLovelace == validation.feeLovelace`.
- A deterministic rebuild test compares two encodings from identical
  frozen inputs byte-for-byte.

The report writer is not part of the unsigned-CBOR semantics. CBOR
golden tests remain the proof that `tx-build` did not alter the
transaction body.

## Vertical TDD Slices

1. Contract and encoder slice: add the report data model, stable
   encoder, checked schema asset, and unit/schema tests that fail until
   the encoder and contract align.
2. Accounting/classification slice: add pure wallet accounting,
   treasury accounting, and output-role classification against frozen
   swap data, including the wallet-net-spend equals fee assertion.
3. Build integration slice: expose the final balanced tx/build context
   needed for reporting without changing CBOR bytes, then generate the
   swap golden report from the existing frozen fixture.
4. CLI writer slice: add the `tx-build --report PATH` option, preserve
   no-report behavior, write the report only on validation success, and
   fail clearly when the requested report path cannot be written.
5. Operator docs slice: update quickstart/swap docs to make the report
   the pre-signing review artifact and state that it is mechanically
   generated from build data.

Each implementation slice should be one bisect-safe durable commit with
its own regression proof. The task breakdown must keep RED tests and
GREEN implementation paired within each vertical slice.
