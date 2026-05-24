# Feature Specification: typed `buildSwapTx` + HTTP + `/operate` CBOR & Report

**Feature Branch**: `270-build-swap-typed`
**Created**: 2026-05-24
**Status**: Draft
**Input**: User description: Refactor `Build.Swap` so the CLI is one caller among several; extract a pure-ish `buildSwapTx` matching the shape #259 gave `buildSwapIntent`, expose it over HTTP in the same `/v1/build/swap` POST, and wire the `/operate` page so the CBOR + Report tabs render real data.

## User Scenarios & Testing *(mandatory)*

This feature has three callers, each of which can land and ship its own end-to-end slice on top of the prior. The Haskell engineer operating this codebase IS the user — symbol names appear here because they are the contract.

### User Story 1 — Engineer can call `buildSwapTx` from the REPL without crashing the host (Priority: P1)

A Haskell engineer with an open `Backend`, a `GlobalOpts`, and a typed `SwapIntent` value calls `buildSwapTx g backend intent tracer` from `ghci` to obtain the built tx CBOR plus a `Report`. On any failure — wallet underfunded, sundae order rejected, balance check fails, ledger-side coin-selection error — the call returns `Left <typed BuildFailure variant>`. The host process is never killed; the tracer events are diagnostic only.

**Why this priority**: This is the load-bearing API. The CLI, the HTTP endpoint, and every future caller (notebooks, smoke harnesses, indexers) all sit on top of it. Without P1 there is no P2 or P3.

**Independent Test**: Unit / property tests can instantiate a fake `Backend` (or use a fixture-backed one), feed deliberately malformed intents covering every `BuildFailure` constructor, and assert that the `Either` arm matches the expected variant. No CLI process, no HTTP layer, no frontend involved.

**Acceptance Scenarios**:

1. **Given** a well-formed `SwapIntent` and a `Backend` that returns the canonical golden chain state, **When** `buildSwapTx` is run, **Then** it returns `Right (CborHex, Report)` where the CBOR matches the existing golden fixture byte-for-byte AND the report matches the existing golden JSON byte-for-byte.
2. **Given** a `SwapIntent` whose `wallet.address` cannot be resolved on the supplied `Backend`, **When** `buildSwapTx` is run, **Then** it returns `Left (WalletAddressUnresolved ...)` carrying the offending bech32 address; the host process is alive on return; the tracer received only informational events.
3. **Given** any input that produces a non-success arm, **When** `buildSwapTx` is run, **Then** no `exitWith`, `error`, `throwE` of a non-`BuildFailure`, or `abortTr` is reachable from the entry point.

---

### User Story 2 — Operator can `tx-build` from the CLI and get byte-identical output to before (Priority: P2)

A treasury operator runs the existing CLI swap flow (`amaru-treasury-tx swap-wizard ... && amaru-treasury-tx tx-build ...`) against a fixture corpus. Every byte the CLI emits — `intent.json`, the signed-or-unsigned `tx.cbor`, the `report.json` — is identical to the v0.2.15.0 baseline. Sysexits codes match the existing taxonomy (the same 64/69/70 family used for `buildSwapIntent`).

**Why this priority**: The current CLI surface is the production tool. Any byte drift breaks downstream consumers (the on-chain submission script, the journal archive, the audit pipeline). This story is the safety net: the refactor cannot ship if it changes operator-visible output.

**Independent Test**: The golden test corpus runs the CLI binaries against pinned input bundles and compares emitted files byte-for-byte to checked-in fixtures. Passes only if every fixture is byte-identical.

**Acceptance Scenarios**:

1. **Given** the existing CLI golden corpus, **When** the test runner exercises every scenario, **Then** every emitted byte matches the fixture.
2. **Given** a CLI invocation that previously exited with sysexit 64 (usage error), 69 (service unavailable), or 70 (internal software error), **When** the same input runs after the refactor, **Then** the exit code is the same.

---

### User Story 3 — Web operator builds a real tx from the `/operate` page in one click (Priority: P3)

A web operator visits `/operate`, fills the swap form, clicks **Build unsigned tx**. The HTTP response carries the typed intent, the CBOR hex string, and a `Report` object. The frontend tabs **Intent**, **CBOR**, **Report** all render real data — no more "ships in PR B" placeholders. On a typed failure, the relevant input field is highlighted and the failure variant tag is shown verbatim.

**Why this priority**: Closes the feedback loop the user has been hammering on through the entire #263 cycle. The `/operate` page is currently a half-built advertisement for the CLI; this turns it into a self-service tool.

**Independent Test**: Spin up the api binary against a fixture-backed backend and a frozen wallet UTxO snapshot, POST a well-formed swap request, assert the response carries non-`null` `cborHex` + `report`. With Playwright (or a manual smoke), open `/operate`, fill the form, click **Build**, observe all three preview tabs populate.

**Acceptance Scenarios**:

1. **Given** a well-formed `POST /v1/build/swap` request, **When** the server handles it, **Then** the response is HTTP 200 with `intentJson`, `cborHex`, and `report` fields all populated.
2. **Given** a request whose intent assembly fails (e.g. unresolved scope), **When** the server handles it, **Then** the response is HTTP 200 with a typed failure tag at the `intentFailure` field; `cborHex` and `report` are `null` because tx-build was never attempted.
3. **Given** a request whose intent succeeds but tx-build fails (e.g. wallet underfunded), **When** the server handles it, **Then** the response is HTTP 200 with `intentJson` populated and a typed failure tag at the `buildFailure` field; `cborHex` and `report` are `null`.

---

### Edge Cases

- The `SwapIntent` is bit-perfect but the on-chain wallet UTxO set has drifted since the intent was assembled (the planner-time UTxOs were spent between wizard and tx-build): `buildSwapTx` must return `Left (WalletUtxoStale ...)` carrying the missing `TxIn`s, not crash.
- A previously-resolved `Backend` becomes unavailable mid-build (node socket reconnect, chain rollback): `Left (BackendUnavailable ...)` with the underlying error string.
- The frontend posts twice in quick succession: idempotent — both POSTs return the same fixture-bound response; no in-process global state mutated.
- The intent's `swap.rateNumerator` / `rateDenominator` is mathematically valid but the resulting order is rejected by sundae's on-chain validator: `Left (SundaeOrderRejected ...)` with the validator's reason.
- The tracer is `nullTracer`: end-to-end behaviour is unchanged from the same call with a real tracer — control flow does not branch on tracer presence.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: `Amaru.Treasury.Wizard.Swap` (or a sibling new module) MUST export `buildSwapTx :: GlobalOpts -> Backend -> SwapIntent -> Tracer IO BuildEvent -> ExceptT BuildFailure IO (CborHex, Report)`.
- **FR-002**: Every existing exit-on-error site in the `Build.Swap` pipeline (every `throwE`, `exitWith`, ambient exit) MUST be replaced by a `Left <BuildFailure constructor>` carrying enough data for a UI to highlight the offending field or step. No host-process termination is reachable from `buildSwapTx`.
- **FR-003**: `BuildFailure` MUST have one constructor per distinct failure mode currently produced by `Build.Swap.runSwap` / `runSwapAction`. Each constructor's payload MUST be testable (no opaque `SomeException` arms).
- **FR-004**: `Tracer IO BuildEvent` MUST be informational only. The full sequence of events MUST be identical between a successful call with `nullTracer` and the same call with a real tracer; control flow MUST NOT branch on tracer presence.
- **FR-005**: The CLI wrappers (`Cli.SwapWizard.runWizard`, any `tx-build` subcommand path) MUST rewire through `buildSwapTx` and MUST keep their existing byte-for-byte CBOR + report.json output. CLI exit codes MUST keep their existing sysexits taxonomy (64 usage / 69 unavailable / 70 internal-software).
- **FR-006**: A golden test corpus MUST pin `intent.json`, the built tx CBOR, and `report.json` byte-for-byte against the v0.2.15.0 baseline. Every existing scenario in the swap corpus MUST be covered.
- **FR-007**: A property / harness test MUST exercise every `BuildFailure` constructor at least once via deliberately malformed inputs and assert the typed variant matches.
- **FR-008**: `SwapBuildResponse` (the JSON body returned by `POST /v1/build/swap`) MUST be extended with `cborHex :: Maybe Text` and `report :: Maybe Report` fields. The response shape MUST encode the four arms — success / intent-failure / build-failure / internal-failure — unambiguously and round-trip through the typed Haskell + frontend codecs.
- **FR-009**: The HTTP handler MUST run `buildSwapIntent` and `buildSwapTx` in one POST, reusing the pre-opened `Backend`. A typed intent failure MUST short-circuit; tx-build MUST NOT be attempted if intent assembly failed.
- **FR-010**: The `/operate` page CBOR + Report tabs MUST render real data from the response when present. The placeholders ("ships in PR B") MUST be removed.
- **FR-011**: The CBOR tab MUST display the `cborHex` as a copyable hex string with a structure-level copy button (consistent with the intent.json tab). The Report tab MUST render the `Report` object through the same `JsonTree.render` path the intent uses, with the same single-click / double-click collapse UX.
- **FR-012**: On a typed failure, the `/operate` page MUST surface the failure variant tag at the preview status banner and (when the failure variant carries a field reference) highlight the corresponding form input.

### Key Entities

- **`SwapIntent`**: The output of `buildSwapIntent` (#259, already typed). Input to `buildSwapTx`.
- **`BuildFailure`**: New sum type. One constructor per failure mode in `Build.Swap`. Each variant carries enough data for a UI to highlight the offending step.
- **`BuildEvent`**: New sum type for informational tracer events emitted along the tx-build pipeline. Mirrors `WizardEvent` from #259.
- **`CborHex`**: A `Text` newtype carrying the hex-encoded serialised tx body. Already exists in the codebase; reused.
- **`Report`**: The existing `Report` value the CLI emits as `report.json`. Reused, not redefined.
- **`SwapBuildResponse`** (HTTP): Extended with `cborHex :: Maybe Text` + `report :: Maybe Report` + a typed `buildFailure :: Maybe Text` tag.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: The CLI golden test corpus runs zero byte-diff against the v0.2.15.0 baseline — every fixture passes unchanged.
- **SC-002**: Every `BuildFailure` constructor is exercised by at least one harness test; coverage report shows 100 % of constructors hit.
- **SC-003**: No `abortTr`, `die`, `exitWith`, or unchecked `error` is reachable from `buildSwapTx` or `buildSwapIntent`. Static check (grep / lint) passes.
- **SC-004**: From `/operate`, a typical web operator completes "fill swap form → click Build → see CBOR and Report" in under 10 seconds against the dev container.
- **SC-005**: A POST to `/v1/build/swap` with a well-formed request body returns HTTP 200 with `cborHex` and `report` populated in under 5 seconds end-to-end (excluding network latency to the user) against the mainnet-pinned dev container.
- **SC-006**: Per-commit CI ("Build Gate") stays green on every commit in the PR — bisect-safe.

## Assumptions

- The existing `Backend` type already supports the full read interface (pparams, UTxO at address, tip slot) required by `Build.Swap`; the refactor is shape-preserving for the `Backend` contract.
- The existing `Report` type's `ToJSON` instance is stable; we do not redefine the report shape, only surface it over HTTP.
- The frontend's `JsonTree.render` (from the `browser-json-tree` flake input) can render a `Report` JSON value as-is, with the same UX as the intent.json tab.
- No new wallet / signing / submission code lands in this slice — the response carries the unsigned tx body for offline signing via the existing `attach-witness` + `envelope-*` CLI tools.
- The Cardano-side test fixtures (chain snapshot, pparams, wallet UTxO set) used by the existing CLI golden corpus are sufficient to drive the new harness tests; no new fixtures need to be cut.

## Out of Scope

- Extending the same refactor to `disburse`, `reorganize`, `withdraw` (separate follow-ups).
- Wallet signing or on-chain submission from the API.
- Indexer integration.
- Multi-tenant metadata loading (the metadata file remains baked into the image, single-tenant — see #267 / #268 follow-ups).
