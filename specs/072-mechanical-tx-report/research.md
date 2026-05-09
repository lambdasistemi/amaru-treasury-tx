# Research: Mechanical Transaction Report

**Plan**: [plan.md](./plan.md) | **Spec**: [spec.md](./spec.md)
**Date**: 2026-05-09

## R1. Report surface

**Decision**: Add a new `tx-build --report PATH` option for the
pre-signing report destination.

**Rationale**: The spec requires existing behavior to remain unchanged
when no destination is supplied. An explicit `--report` flag makes the
new artifact opt-in, unambiguous, and independent from stdout CBOR and
stderr/log trace routing.

**Alternatives considered**:

- Reuse the existing summary sidecar name: rejected because the current
  `Summary` shape is much smaller than the issue #72 report and does
  not cover wallet/treasury accounting or signer sources.
- Always write a default report file: rejected because the spec requires
  unchanged successful behavior when no report destination is supplied.

## R2. Report construction boundary

**Decision**: Build the report from parsed intent, translated intent,
resolved `ChainContext`, final balanced transaction body, fee/collateral
fields, signer hashes, and script validation results.

**Rationale**: These are the facts that actually produced the unsigned
CBOR. They are also enough to compute accounting and classify produced
outputs without querying the node again or reconstructing state from
historical CBOR.

**Alternatives considered**:

- Decode only the final CBOR: rejected because the spec explicitly
  excludes reconstructing reports from arbitrary historical CBOR without
  builder context.
- Extend logging and parse trace lines: rejected because logs are not a
  stable machine-readable contract and lose resolved input values.

## R3. JSON contract strategy

**Decision**: Define a versioned structured JSON report and validate it
with a checked-in JSON Schema plus golden fixtures.

**Rationale**: Downstream tooling needs a stable shape. The repository
already has a schema-check pattern for intent JSON and a golden-fixture
pattern for transaction outputs; reusing both keeps the report contract
reviewable.

**Alternatives considered**:

- Golden JSON only: rejected because it proves one fixture but not the
  public shape.
- Schema only: rejected because it does not prove deterministic bytes or
  the issue's swap accounting claim.

## R4. Deterministic encoding

**Decision**: Use a stable `aeson-pretty` encoder with explicit key
ordering, ledger-order output arrays, canonical ordering for maps, and a
trailing newline.

**Rationale**: The success criteria require byte-identical reports from
identical inputs. Existing intent and summary code already use stable
pretty encoders, so this follows local convention.

**Alternatives considered**:

- Plain `encode`: rejected because object key order is less reviewable
  and would make golden diffs harder to inspect.
- Include timestamps or local paths: rejected by the deterministic
  artifact requirement.

## R5. Failure and validation timing

**Decision**: Generate and write the report only after CBOR build and
redeemer validation succeed. If writing the requested report fails,
`tx-build` exits non-zero and reports the write error.

**Rationale**: The report is a successful-build review artifact. Failed
builds keep existing traces as the diagnostic surface. A requested
artifact that cannot be written is an incomplete command result and must
not be presented as success.

**Alternatives considered**:

- Emit reports for failed builds: rejected because the spec says no
  success report is produced on build or validation failure.
- Ignore report write failures after CBOR is written: rejected because
  it violates FR-015 and would hide missing audit artifacts.

