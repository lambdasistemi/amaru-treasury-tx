# Feature Specification: Swap wizard pure intent producer

**Feature Branch**: `259-swap-wizard-pure`
**Created**: 2026-05-23
**Status**: Draft
**Input**: User description: "Refactor the swap wizard runtime so the CLI is one caller among several. Extract a pure-ish `buildSwapIntent` from `runWizard`, and a matching `buildSwapTx` from the existing tx-build pipeline. Replace every `abortTr` exit-on-error site with a typed `WizardFailure` / `BuildFailure` sum-type variant. Demote the tracer to informational logging only. CLI wrappers rewire through the new pure functions and keep byte-for-byte behaviour, pinned by golden tests."

## Clarifications

### Session 2026-05-23

- Q: Should `buildSwapIntent` open its own backend or accept a pre-opened one? → A: Option B — `buildSwapIntent` accepts a pre-opened `Backend` argument; the CLI wrapper retains `withLocalNodeBackend` to bracket-manage the socket lifetime for its single call. This lets an HTTP server reuse one socket across requests.
- Q: Does the refactor introduce typed tracer events, or keep `Tracer IO Text`? → A: Option A — typed `WizardEvent` and `BuildEvent` sum types land in this refactor. The CLI's existing `Tracer IO Text` is recovered via `contramap renderWizardEvent` over the typed tracer; no operator-visible log line is dropped.
- Q: How should CLI exit codes map after the refactor? → A: Option B — family-mapped sysexits codes: `Input*` failures exit `64` (`EX_USAGE`), `Resolve*` failures exit `69` (`EX_UNAVAILABLE`), `Internal*` failures exit `70` (`EX_SOFTWARE`). The "non-zero on failure" contract holds; wrapping scripts and CI can now branch without parsing stderr.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - HTTP handler reuses the wizard without process exits (Priority: P1)

A backend service handling an HTTP request needs to run the swap wizard's intent-construction logic against the chain and return a typed result. Today the wizard's only caller is the CLI, and on any failure the wizard calls `abortTr` which exits the host process. An HTTP request that hits a validation error must surface that error to the client as a structured payload, never as a 502 from a crashed worker.

**Why this priority**: This unblocks the swap build page (#256) and the `POST /build/{kind}` slice of #248. Without it, every downstream HTTP feature on the wizard inherits the same exit-on-error pathology.

**Independent Test**: Call the refactored intent builder from a test harness with deliberately malformed inputs (unknown scope, malformed wallet bech32, validity-hours out of range, registry verification failure). Verify the harness receives a typed `Left` for each failure mode and the host process does not exit.

**Acceptance Scenarios**:

1. **Given** the wizard is invoked from a non-CLI caller with a malformed wallet address, **When** the caller awaits the result, **Then** the caller receives a typed validation failure carrying the field name and a human-readable reason, and the host process keeps running.
2. **Given** the wizard is invoked with a well-formed input that ultimately fails registry verification because the metadata file references a missing tenant, **When** the caller awaits the result, **Then** the caller receives a typed registry failure carrying the missing reference, and the host process keeps running.
3. **Given** the wizard is invoked from a non-CLI caller and the live chain query times out, **When** the caller awaits the result, **Then** the caller observes an IO exception scoped to that call (or a typed transport failure), not a process exit.

---

### User Story 2 - CLI keeps producing byte-identical artefacts (Priority: P1)

The existing `amaru-treasury-tx swap-wizard` CLI is the operator's daily tool. After the refactor it must continue to read the same flags, write the same `intent.json` bytes, and produce the same exit codes. The downstream `tx-build` step must continue to read that intent and emit the same CBOR and the same `report.json`.

**Why this priority**: The CLI is in the hands of an operator running real swaps. Any behaviour drift — different field ordering in intent.json, a new whitespace in CBOR, a missing trace line — is a regression visible to the human running it.

**Independent Test**: A golden-fixture test runs the CLI binary (or the underlying function) against a canonical input and compares the produced intent.json, CBOR, and report.json byte-for-byte against pre-refactor snapshots.

**Acceptance Scenarios**:

1. **Given** a canonical wizard input fixture, **When** the operator runs the CLI before and after the refactor, **Then** the produced intent.json files are byte-identical.
2. **Given** the canonical intent.json, **When** the operator runs `tx-build` before and after the refactor, **Then** the produced CBOR is byte-identical and the report.json is byte-identical.
3. **Given** a wizard input that fails validation, **When** the operator runs the CLI, **Then** the CLI exits non-zero with the same exit code and the same human-readable error text as before the refactor.

---

### User Story 3 - Failures carry enough data to drive a UI (Priority: P2)

When the wizard or tx-build fails, the caller — whether HTTP handler or future GUI — needs to do more than print a string. It needs to know which input field is at fault so the UI can highlight it, and what category of failure occurred so the UI can choose between "fix and retry", "wait and retry", or "contact operations".

**Why this priority**: This is what makes the refactor materially better than a `String`-typed error. Without per-field data the GUI degrades to a single error banner; with it, the GUI can produce per-field hints and the right call-to-action.

**Independent Test**: Inspect the failure sum types and confirm that each constructor either (a) names the offending field by a stable identifier matching the form schema, or (b) is unambiguously a "system" failure not attributable to a single field.

**Acceptance Scenarios**:

1. **Given** a failure constructor produced by the wizard, **When** the caller inspects it, **Then** the constructor either names an input field by a stable identifier or marks itself as a system-level failure.
2. **Given** a failure constructor's payload, **When** the caller renders it, **Then** the payload contains a human-readable reason in addition to any machine-readable identifiers.

---

### Edge Cases

- The CLI reads inputs from the host environment (network socket, node config) that the wizard internals need; the refactor must keep these accessible to non-CLI callers without forcing every caller to mimic CLI argument parsing.
- A failure that today exits with one line of traced text may today combine "log" and "error message" in the same string; the refactor must split those — the error variant carries the message, the tracer continues to log the lead-up — without losing either signal.
- A non-CLI caller may invoke the wizard concurrently. Today the wizard uses process-global resources (stdout, stderr, exit). Concurrent invocations from one host must each get their own logical result without polluting another in-flight call.
- A future caller may want to capture the tracer's log lines (for a request-scoped trace ID). The tracer interface must support per-call tracer injection, even though only logging behaviour is required in this slice.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST expose a callable function that produces a swap intent value (or a typed failure) without exiting the host process.
- **FR-002**: The system MUST expose a callable function that produces a transaction body and a report value (or a typed failure) given an intent, without exiting the host process.
- **FR-003**: Every error condition currently signalled by `abortTr` MUST be represented by a distinct constructor of a typed failure value.
- **FR-004**: Each failure constructor MUST carry either (a) the stable identifier of the offending input field plus a human-readable reason, or (b) a marker that the failure is system-level and not attributable to a single field, plus a human-readable reason.
- **FR-005**: The tracer interface MUST remain available for informational logging, but MUST NOT be required by any caller in order to receive a failure value. The tracer parameter MUST accept a typed event sum (`WizardEvent` / `BuildEvent`) rather than free-form `Text`; the CLI's existing text tracer is recovered by contramapping a renderer over the typed tracer.
- **FR-006**: The CLI `swap-wizard` invocation MUST produce intent.json files that are byte-identical to the pre-refactor CLI for every fixture in the existing test corpus.
- **FR-007**: The CLI `tx-build` invocation MUST produce CBOR and report.json files that are byte-identical to the pre-refactor CLI for every fixture in the existing test corpus.
- **FR-008**: The CLI MUST keep its observable behaviour on failure paths in two respects: (a) the same human-readable error text is printed for the same triggering condition; (b) the exit code is non-zero. The numeric exit code MAY change: this refactor maps the failure family to sysexits codes — `Input*` → `64` (`EX_USAGE`), `Resolve*` → `69` (`EX_UNAVAILABLE`), `Internal*` → `70` (`EX_SOFTWARE`) — so wrapping scripts can branch on family without parsing stderr.
- **FR-009**: A non-CLI caller MUST be able to invoke both functions concurrently from one host without one call's failure or trace stream affecting another's. Concurrent invocations within one process MUST be supported by accepting a pre-opened `Backend` value as a parameter — `buildSwapIntent` MUST NOT open its own backend, so an HTTP server can share a single backend handle across in-flight requests. The CLI wrapper retains `withLocalNodeBackend` to bracket-manage the backend lifetime around its single call.
- **FR-010**: The failure-value contract MUST be discoverable from one place (the failure types' module) so callers can enumerate every variant they may receive.
- **FR-011**: The system MUST permit a caller to supply its own tracer (or to opt out of tracing) without affecting the returned failure or success value.

### Key Entities

- **Swap intent**: The structured operator instruction produced by the wizard — scope, wallet, amount, rate, validity, rationale, extra signers, metadata reference. Today serialised to `intent.json`; the refactor exposes it as an in-memory value that the same serialiser can consume.
- **Wizard failure**: A typed sum value describing why intent construction did not succeed. Each variant carries either a field identifier + reason or a system-level marker + reason.
- **Build artefact**: The pair of transaction CBOR (hex-encoded byte string) plus the structured pre-signing report. Today written to disk by `tx-build`; the refactor exposes it as an in-memory value.
- **Build failure**: A typed sum value describing why transaction construction did not succeed. Same shape rules as wizard failure.
- **Tracer**: An informational logging surface that the wizard and tx-build emit typed events (`WizardEvent`, `BuildEvent`) through. Independent of the failure channel. The CLI's existing text-tracer is recovered by `contramap`-ing a renderer over the typed tracer; a non-CLI caller can pass `nullTracer` to opt out or compose a capturing tracer for request-scoped log collection.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Every existing wizard CLI fixture produces intent.json that is byte-identical pre- and post-refactor (100% of fixtures in the test corpus).
- **SC-002**: Every existing tx-build CLI fixture produces CBOR + report.json that is byte-identical pre- and post-refactor (100% of fixtures in the test corpus).
- **SC-003**: A non-CLI caller deliberately triggering every failure variant receives a typed failure value for every one, with zero host-process exits, across the full suite.
- **SC-004**: No callable function reachable from the new builder functions calls `abortTr`, `die`, or `exitWith` (verified by inspection of the failure-construction call graph).
- **SC-005**: Every wizard failure variant exposes either a stable field identifier or a system-level marker; spot-check 100% of variants in the failure-types' module.

## Assumptions

- The existing wizard's IO requirements (chain queries, registry verification, resolver) remain in IO after the refactor. "Pure" here means "does not exit the host process on error", not "no IO".
- The existing `Tracer IO Text` shape continues to satisfy logging needs; no new structured-event tracer is introduced in this slice.
- Existing test fixtures cover the canonical happy path and a representative subset of failure paths. New fixtures may be added during the refactor if a path is presently uncovered.
- The CLI's argument parsing remains unchanged. The refactor is internal to the wizard runtime; flags, environment, and exit semantics are operator-facing contracts the refactor preserves.
- This slice covers swap only. Cancel-swap, disburse, reorganize, and withdraw wizards will receive the same treatment in follow-up slices.
- The HTTP endpoint that will eventually call the refactored functions is out of scope; this slice does not change the API server's routes or middleware.
- Indexer integration (#241) is out of scope; the wizard continues to read chain data via the existing N2C path.
