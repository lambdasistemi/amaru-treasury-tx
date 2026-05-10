# Feature Specification: Operator-Friendly Markdown Renderer for the Mechanical Transaction Report

**Feature Branch**: `074-report-render`
**Created**: 2026-05-09
**Status**: Draft
**Input**: User description from issue [#74](https://github.com/lambdasistemi/amaru-treasury-tx/issues/74): add a `report-render` subcommand that interprets the JSON `report.json` produced by `tx-build` (issue [#72](https://github.com/lambdasistemi/amaru-treasury-tx/issues/72), PR [#73](https://github.com/lambdasistemi/amaru-treasury-tx/pull/73)) into operator-friendly Markdown, with addresses and key hashes resolved to semantic role labels so a multisig reviewer can recognize the kind of action at a glance, and make the report self-contained by additively embedding the originating intent.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Render the mechanical report into operator-friendly Markdown (Priority: P1)

A treasury multisig reviewer receives a `report.json` build-output envelope for a built but unsigned transaction. The JSON is correct but unfriendly to read at signing time: dozens of nearly identical swap-order entries, every value in raw lovelace, validity bounds expressed only in slot numbers, and important context (intent rationale, swap deal terms) absent. The envelope must carry the intent that requested the transaction, the unsigned transaction CBOR, and the nested mechanical report so the review artifact binds the human-readable facts to the exact transaction bytes being signed. The reviewer wants a Markdown rendering of the same successful envelope that collapses repeated outputs, shows ADA alongside lovelace, derives UTC validity bounds, inlines the CIP-1694 rationale when present, prints a conservation line, and links to a chain explorer for the transaction id, all derived deterministically from the envelope data with no chain access.

**Why this priority**: This is the reviewer pain that issue #74 was filed to address. Without a Markdown rendering, every reviewer reads the raw JSON and re-derives the human-relevant facts manually. This story alone, without identity resolution or pipe-native composition, already gives reviewers a usable artifact.

**Independent Test**: Run the renderer against a checked-in `report.json` fixture from a successful swap build and verify the envelope contains top-level `intent`, `result.tx-cbor`, and `result.report`; the resulting Markdown identifies the transaction CBOR fingerprint or hash, collapses identical swap-order outputs into a single line, prints lovelace amounts together with their ADA equivalents, prints the UTC validity bounds derived from the nested report's slot bounds and the system's era schedule, prints a conservation line of the form `inputs = outputs + fee, residual 0`, and prints an explorer URL for the transaction id. The Markdown bytes are byte-identical across repeated runs with the same inputs.

**Acceptance Scenarios**:

1. **Given** a success envelope whose nested report has N identical swap-order outputs to the same Sundae order address, **When** the operator runs the renderer over it, **Then** the rendered Markdown shows those outputs as a single collapsed line summarising the count and per-chunk amount, not N repeated entries.
2. **Given** a success envelope whose nested report has monetary values as integer lovelace, **When** the renderer prints any lovelace quantity in a value table or summary, **Then** the same line shows the equivalent ADA amount.
3. **Given** a success envelope whose nested report has slot-based validity bounds, **When** the renderer prints validity, **Then** it shows the corresponding UTC instants alongside the slot numbers, derived deterministically from the report's network/era schedule data with no chain access.
4. **Given** the same success envelope rendered twice, **When** both renders complete, **Then** the Markdown bytes are identical.

---

### User Story 2 - Recognize the transaction type at a glance via intent, address, and identity resolution (Priority: P1)

When a multisig reviewer opens the rendered report, they need to recognize, within the first screen of output, what kind of action the transaction performs (swap, disburse, withdraw, reorganize) and which scope it touches. Today the JSON shows raw bech32 addresses and 28-byte signer key hashes; even after Markdown rendering, those bare strings do not let a human distinguish a swap from a disbursement, or one scope from another. The renderer must build an address book and identity map from declarative inputs (treasury metadata, built-in constants, derivations from script hashes, and the embedded intent), then label every address, signer key hash, and reference input it prints with a semantic role tag such as `network_compliance treasury`, `Sundae swap-order [network_compliance]`, `operator wallet`, `network_compliance scope owner`, or `scopes registry`. Anything that cannot be resolved must appear with a clear `unresolved` tag and a truncated bech32 fallback, never as a bare untagged hash.

**Why this priority**: Issue #74 names this as the critical reviewer-safety property: the transaction type must be unmistakable from the first screen of the rendered Markdown. Without identity resolution, the Markdown rendering is prettier but still does not protect a reviewer from misreading a swap as a disbursement or routing funds to the wrong scope.

**Independent Test**: Run the renderer over a swap report fixture using a metadata source that maps treasury and registry script hashes and scope owners to per-scope labels. Verify that the first screen of Markdown identifies the transaction type from the inline intent as a swap on the named scope, that every address printed in the outputs/inputs/reference-inputs sections carries a role label, that every required signer key hash carries a role label, and that no bare bech32 address or bare 28-byte hex key hash appears unaccompanied by either a resolved label or an explicit `unresolved` tag. Repeat for a disburse fixture and a withdraw fixture; verify that the transaction type in each is unambiguous from the leading section of Markdown.

**Acceptance Scenarios**:

1. **Given** a swap success envelope and a metadata source that names treasury, permissions, registry, and per-scope addresses, **When** the renderer prints the report, **Then** the leading section identifies the transaction type as a swap on the named scope without the reviewer needing to inspect any address bytes.
2. **Given** the same address or key hash appears in inputs, outputs, reference inputs, and signer requirements, **When** the renderer prints those sections, **Then** the same role label is used for that identity in every section.
3. **Given** an address or signer key hash that no resolution source recognises, **When** the renderer prints it, **Then** it is shown with an explicit `unresolved` tag and a truncated bech32/hex form, never as a bare untagged value.
4. **Given** a disburse success envelope is rendered with the same renderer and a matching metadata source, **When** the reviewer reads the leading section, **Then** they cannot mistake the disburse for a swap; the transaction-type label from the intent and the role labels of the produced outputs make the kind unambiguous.

---

### User Story 3 - Compose the renderer into a stdin/stdout pipeline with a self-contained report (Priority: P1)

A treasury operator wants to build an unsigned transaction and produce both the JSON build-output envelope and the Markdown rendering in one shell pipeline, without writing intermediate side files and without passing the originating intent separately to the renderer. Today, even after issue #72, the JSON report does not carry the intent it was built from, so any tool that wants the swap-deal summary (target USDM, committed ADA, min rate, quote source, slippage) must be handed the intent file out of band. The operator wants every `tx-build --report` output to be shaped as `{ intent, result }`, where `result` is either a structured failure or a successful payload `{ tx-cbor, report }`, and the renderer to read that envelope from stdin and write Markdown to stdout by default. A malformed envelope is invalid; the renderer must fail clearly instead of accepting a side-channel intent file or guessing from the nested mechanical report.

**Why this priority**: The pipe-native shape and the inline intent are the operational contract that makes the renderer composable with the existing `swap-wizard | tx-build` flow and avoids creating a second source-of-truth file. Without them, every operator script must manage two files and a side-channel intent path, and reviewers cannot trust that `report.md` reflects the same intent the transaction was built from.

**Independent Test**: Run an end-to-end pipeline over a checked-in fixture: produce the JSON build-output envelope on stdout from the build path, pipe it into the renderer with no flags, and capture the Markdown on stdout. Verify that the envelope carries the originating intent under top-level `intent`, the successful result under `result`, the unsigned transaction bytes under `result.tx-cbor`, and the mechanical report under `result.report`; verify that the rendered Markdown contains a swap-deal summary section derived from the embedded intent and identifies the transaction CBOR; verify that an envelope missing required fields or carrying malformed intent/CBOR/report is rejected with a non-zero exit and a clear diagnostic; and verify that `--in <path>`, `--out <path>`, and the explicit stdio aliases override the default streams independently.

**Acceptance Scenarios**:

1. **Given** the build path is invoked with the report destination set to standard output, **When** the renderer is invoked with no flags on the resulting stream, **Then** Markdown is written to standard output and the pipeline produces a single self-contained artifact without intermediate files.
2. **Given** a fresh successful build-output envelope with inline intent, transaction CBOR, and nested report, **When** the renderer prints the leading section, **Then** it shows a swap-deal summary derived from the embedded intent and a deterministic CBOR fingerprint/hash derived from `result.tx-cbor`.
3. **Given** a JSON envelope without readable inline intent, result, transaction CBOR, or nested report, **When** the renderer runs over it, **Then** the command exits non-zero and reports that the required field is missing or invalid.
4. **Given** the renderer is invoked with `--in <path>` and `--out <path>`, or with `--in -` / `--out -` aliases, **When** it runs, **Then** it reads from and writes to the specified streams independently, while the no-flag invocation keeps the default stdin/stdout behavior.

---

### User Story 4 - Document the renderer and wire it into the operator workflow (Priority: P2)

An operator running an end-to-end build flow expects the rendered Markdown report to be produced alongside the JSON build-output envelope by default, without remembering to invoke a second command. Operator documentation must describe the renderer, the `{ intent, result }` envelope, and the address/identity resolution sources, and must position the rendered Markdown as the primary pre-signing review artifact for successful results. The repository's operator-facing helper script that wraps the build path must produce the Markdown rendering by default next to the JSON envelope, with an opt-out flag for the rare case in which the operator does not want it.

**Why this priority**: Documentation and helper-script wiring do not create the safety property by themselves, but they make the Markdown rendering the default operational review surface. Issue #74 names this as an explicit acceptance criterion ("default-on, opt-out documented").

**Independent Test**: Read the operator documentation for the swap and the end-to-end review flow. Verify the docs name the rendered Markdown as the pre-signing review artifact, describe the `report.json` envelope shape (`intent` plus `result`), and document the address/identity resolution sources (treasury metadata, built-in constants, script-hash derivation, embedded intent, and the unresolved fallback). Run the operator-facing helper script that wraps the build flow against a fixture and verify that, by default, it writes the Markdown rendering next to the JSON envelope, and that the documented opt-out flag suppresses the Markdown without touching the JSON envelope.

**Acceptance Scenarios**:

1. **Given** an operator follows the documented build-and-review flow, **When** they reach the pre-signing review step, **Then** the docs direct them to the rendered Markdown report and explain that it is generated mechanically from the JSON build-output envelope.
2. **Given** the operator-facing helper script that wraps the build flow is invoked with default flags against a fixture, **When** it completes, **Then** both the JSON envelope and the Markdown rendering are written and named consistently.
3. **Given** the documented opt-out flag is passed, **When** the helper script runs, **Then** the JSON envelope is still produced and the Markdown rendering is not, and that choice is recorded in the documentation as the supported way to skip rendering.

---

### Edge Cases

- **Malformed build-output envelope**: the renderer must reject missing or malformed top-level `intent`, missing or malformed `result`, and success results missing or malformed `tx-cbor` or `report`, with a non-zero exit and a clear diagnostic. The renderer does not accept a separate intent path and does not render a degraded success report.
- **Failure build result**: a valid failure result carries the inline intent plus structured failure data, but no `tx-cbor` or nested mechanical report. It is not a pre-signing report; the renderer may produce a failure Markdown diagnostic, but it must not present it as a signable transaction review.
- **No metadata source available**: the renderer must still produce Markdown; addresses and key hashes that cannot be resolved appear with an explicit `unresolved` tag and a truncated form. No silent bare bech32/hex.
- **Unknown or future output role**: the renderer must not omit an output; if its role is not a known role from the JSON contract, it must appear under a generic role with the resolved or unresolved address label preserved.
- **Sundae swap-order outputs with mixed amounts**: the renderer collapses only outputs that share the same role and resolved destination and amount; outputs with a remainder chunk are listed alongside the collapsed group rather than absorbed into it.
- **Partial address-book coverage**: if metadata covers some scopes but not others, resolved addresses use the per-scope labels for known scopes and the unresolved tag for the rest, in the same rendering.
- **Unsupported intent transaction type**: any transaction type supported by the unified-intent decoder must yield an unambiguous leading section; an unsupported or malformed intent type is a decode error, not a guess from transaction outputs.
- **No chain access available**: rendering must remain fully deterministic and offline; UTC validity bounds and explorer URLs are derived from data already present in the report (era schedule, network identifier) without any network call.
- **Renderer write failure**: if the rendered output cannot be written to the requested destination (file or stream), the command must exit non-zero and report the failure clearly.

## Requirements *(mandatory)*

### Scope

- This feature adds a Markdown rendering of the existing JSON `report.json` produced by `tx-build` for successful builds.
- It replaces the naked mechanical `report.json` contract with a build-output envelope: top-level `intent` plus top-level `result`. A success result carries required `tx-cbor` and nested `report`; a failure result carries structured failure data. The inline intent is the only carrier of transaction type; neither the envelope nor the nested report may carry a separate top-level `action`, `type`, or equivalent transaction-type field.
- It builds an address and identity map from declarative sources (treasury metadata, built-in constants, derivations from script hashes, embedded intent, and a clear unresolved fallback) and uses it to label every address, signer key hash, and reference input the renderer prints.
- It defines a default standard-input / standard-output composition shape so the renderer composes with the existing build pipeline.
- It updates operator documentation and the operator-facing build helper script so the rendered Markdown is the default pre-signing review artifact.

### Explicit Exclusions

- This feature does not change existing mechanical report fields established in issue [#72](https://github.com/lambdasistemi/amaru-treasury-tx/issues/72) except that the mechanical report is now nested under `result.report` and must not duplicate the intent's transaction type.
- This feature does not produce HTML, PDF, or any non-Markdown rendering.
- This feature does not sign or submit transactions.
- This feature does not reach the chain or any external service to resolve identities or derive validity instants; resolution is offline against declarative sources and report data only.
- This feature does not introduce personal names for signer key hashes; only role labels are used so credential rotation is metadata-only.
- This feature does not implement the quote-derived swap-order parameter-filling workflow from issue [#70](https://github.com/lambdasistemi/amaru-treasury-tx/issues/70), although that future workflow may consume the rendered Markdown.
- This feature does not attempt to render reports that were not produced by the in-tree build path (no third-party `report.json` schemas).

### Functional Requirements

- **FR-001**: The system MUST provide a `report-render` subcommand on the existing executable that reads a JSON build-output envelope and writes a Markdown rendering.
- **FR-002**: The renderer MUST default to reading the JSON build-output envelope from standard input and writing the Markdown to standard output when invoked with no positional arguments.
- **FR-003**: The renderer MUST accept an explicit input override and an explicit output override that select a filesystem path or the standard stream alias, independently of one another.
- **FR-004**: The build path MUST support writing the JSON build-output envelope to standard output as a destination, so that `tx-build --report - | report-render > report.md` is an end-to-end stream-capable pipeline.
- **FR-005**: `tx-build --report` MUST emit a JSON build-output envelope with required top-level `intent` and `result` fields. The top-level `intent` MUST be the full originating unified-intent JSON value with the same shape as the standalone intent JSON.
- **FR-006**: The `result` field MUST be a union: either a structured failure value, or a success object with required `tx-cbor` and `report` fields. Success `tx-cbor` MUST be the exact unsigned transaction CBOR encoded as lowercase hex; success `report` MUST be the mechanical transaction report from issue #72.
- **FR-007**: The envelope decoder and schema MUST reject missing or malformed top-level `intent`, missing or malformed `result`, success results whose `tx-cbor` is missing/not hex/empty, and success results whose nested `report` is missing or malformed.
- **FR-008**: The inline `intent` MUST be the only carrier of transaction type. The build-output envelope and nested mechanical report MUST NOT duplicate the intent's transaction type in any separate top-level `action`, `type`, or equivalent field.
- **FR-009**: The renderer MUST read the originating intent only from the envelope's top-level `intent` field. It MUST NOT accept a separate intent-path argument, and it MUST NOT render a success report when the inline intent cannot be decoded.
- **FR-010**: For success results, the renderer MUST identify the unsigned transaction CBOR in the leading section by printing a deterministic CBOR fingerprint or hash derived from `result.tx-cbor`, so reviewers can bind the Markdown facts to the transaction bytes.
- **FR-011**: The renderer MUST produce byte-identical Markdown for the same build-output envelope and metadata inputs across repeated runs; rendering MUST NOT depend on wall-clock time, randomness, environment variables not derived from the inputs, or local machine state.
- **FR-012**: The renderer MUST collapse runs of identical produced outputs (same role and same resolved destination and same per-output amount) into a single summary line that names the count and the per-output amount, while leaving distinct outputs (including a remainder chunk) listed separately.
- **FR-013**: The renderer MUST display every monetary quantity that is meaningful as ADA in both lovelace and ADA on the same line.
- **FR-014**: The renderer MUST display validity bounds in both slot numbers and UTC instants, with the UTC instants derived deterministically from the era and network data already present in the nested report (no chain access).
- **FR-015**: The renderer MUST inline the CIP-1694 rationale (description, justification, destination label, event, label) when the nested report's auxiliary-data summary indicates one is present, rather than reducing it to a boolean flag.
- **FR-016**: The renderer MUST print a conservation line that states the total inputs, total outputs, transaction fee, and residual; the residual MUST be the arithmetic difference and MUST be shown as such (zero when conservation holds).
- **FR-017**: The renderer MUST print a chain-explorer URL for the transaction id when the nested report includes the transaction id.
- **FR-018**: The renderer MUST build an address book and identity map from, in order of preference: a treasury metadata source supplied by an explicit override or a documented default path when present; built-in constants for known third-party identifiers (such as the Sundae USDM pool, USDM policy and asset, Sundae protocol fee); derivations from script hashes already present in the nested report; the envelope's inline intent; and a clear `unresolved` fallback when no source matches.
- **FR-019**: The renderer MUST label every address it prints with a semantic role tag drawn from the address book, and MUST never print a bare bech32 address without either a resolved label or an explicit `unresolved` tag with a truncated form.
- **FR-020**: The renderer MUST label every required signer key hash it prints with a role tag drawn from the identity map, MUST NOT introduce personal names, and MUST never print a bare hex key hash without either a resolved label or an explicit `unresolved` tag with a truncated form.
- **FR-021**: The renderer MUST label every reference input it prints with a semantic role tag drawn from the script-hash derivations and metadata.
- **FR-022**: The renderer MUST use the same role label for the same identity wherever it appears across inputs, outputs, reference inputs, and signer requirements within one rendering.
- **FR-023**: For success results, the renderer MUST present a leading section that identifies the transaction type from the inline intent and the scope or scopes the transaction touches from the intent and address book, such that a multisig reviewer cannot mistake one transaction type for another from that leading section alone.
- **FR-024**: For swap intents, the leading section MUST include a swap-deal summary derived from the inline intent (target amount, committed ADA, min rate, quote source and timestamp, slippage, treasury leftover).
- **FR-025**: The renderer MUST preserve every produced output from the nested mechanical report in the rendered Markdown; outputs whose role is not a known role from the JSON contract MUST be rendered under a generic role with their resolved or unresolved address label preserved, never silently dropped.
- **FR-026**: If the renderer cannot write its Markdown output to the requested destination, the command MUST exit with a non-zero status and report the failure clearly.
- **FR-027**: The renderer MUST be a pure transformation in the sense that, given the same inputs, it performs no IO beyond reading its input streams or files and writing its output stream or file; it MUST NOT make network calls or read from any source other than the declared inputs.
- **FR-028**: Regression coverage MUST include a checked-in golden Markdown rendering for at least: a swap success envelope rendered with inline intent, transaction CBOR, nested report, and metadata source; a swap success envelope rendered without metadata source; a disburse success envelope; and a withdraw success envelope. Coverage MUST also include invalid-envelope tests for missing or malformed intent, result, transaction CBOR, and nested report. The set MUST demonstrate the transaction-type disambiguation property from FR-023.
- **FR-029**: The repository's operator-facing helper that wraps the build flow MUST, by default, produce the Markdown rendering alongside the JSON build-output envelope and MUST expose a documented opt-out flag that suppresses the Markdown without otherwise changing the build output.
- **FR-030**: Operator documentation MUST describe the rendered Markdown as the pre-signing review artifact, MUST describe the build-output envelope shape (`intent` plus `result`), MUST document the address and identity resolution sources, and MUST document the helper-script default and opt-out.

### Key Entities

- **Build Output Envelope**: The machine-readable artifact written by `tx-build --report`. It has top-level `intent` and `result`. A success result contains `tx-cbor` and nested mechanical `report`; a failure result contains structured failure data.
- **JSON Transaction Report**: The nested mechanical report established in issue [#72](https://github.com/lambdasistemi/amaru-treasury-tx/issues/72), now carried under `result.report` for successful build-output envelopes. It does not carry intent, transaction CBOR, or a duplicate transaction-type field.
- **Originating Intent (inline)**: The same unified-intent JSON value that the build path consumes, carried inline by the build-output envelope so the renderer is a pure pipe stage with no side files. It is the authoritative source for transaction type and intent-specific review fields.
- **Transaction CBOR**: The unsigned transaction bytes carried inline by a successful build-output envelope as lowercase hex under `result.tx-cbor`, binding the review facts to the exact transaction to be signed.
- **Markdown Transaction Report**: The new operator-friendly rendering produced from the build-output envelope and metadata sources. Deterministic, offline, and golden-tested.
- **Address Book**: The map from on-chain addresses to semantic role labels, built from treasury metadata, built-in constants, script-hash derivations, and the embedded intent, with an explicit `unresolved` fallback.
- **Identity Map**: The map from required signer key hashes to role labels (such as per-scope scope-owner roles), with the same fallback discipline as the address book and no personal names.
- **Resolution Source**: One of the declarative inputs the address book and identity map are built from: treasury metadata, built-in constants, derivations from script hashes already in the nested report, and the inline intent. The unresolved fallback is the explicit signal that no source matched.
- **Transaction Type**: The mechanical classification of the transaction (swap, disburse, withdraw, reorganize, or another kind supported by the unified-intent contract) used to drive the leading section so reviewers can recognise the action at a glance. It is read from the inline intent, not duplicated elsewhere in the report.
- **Operator-Facing Build Helper**: The repository's helper script that wraps the build flow end to end and, after this feature, also produces the Markdown rendering by default.
- **Pipeline Composition Contract**: The default standard-input / standard-output behaviour of the renderer, plus the build path's standard-output report destination, that together make `tx-build --report - | report-render > report.md` a single end-to-end stream-capable pipeline.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A multisig reviewer can correctly identify the transaction type (swap vs disburse vs withdraw vs reorganize) and the touched scope from the leading section of the rendered Markdown alone, without inspecting any address bytes, for every fixture in the regression set.
- **SC-002**: The rendered Markdown for the checked-in swap fixture is byte-identical across two independent renderings with the same inputs.
- **SC-003**: The rendered Markdown for the checked-in swap fixture contains zero bare bech32 addresses and zero bare 28-byte hex key hashes that are not accompanied by either a resolved role label or an explicit `unresolved` tag.
- **SC-004**: The end-to-end pipeline `tx-build --report - | report-render > report.md` produces, on the checked-in fixture, a build-output JSON stream that includes top-level `intent`, success `result.tx-cbor`, success `result.report`, plus the same Markdown bytes as the golden artifact, with no intermediate side files.
- **SC-005**: A JSON envelope missing `intent`, `result`, success `tx-cbor`, or success `report`, or carrying malformed inline intent JSON, malformed CBOR hex, or malformed nested report JSON, is rejected by the renderer with a non-zero exit and a clear diagnostic.
- **SC-006**: For the swap fixture, the conservation line in the rendered Markdown shows total inputs, total outputs, fee, and a residual of zero (or the arithmetic value, if any), and the values agree with the nested mechanical report.
- **SC-007**: Operator documentation names the Markdown rendering as the pre-signing review artifact, documents the build-output envelope shape, and documents the helper-script default and opt-out.
- **SC-008**: The repository's operator-facing build helper, when invoked with default flags against the swap fixture, produces both the JSON build-output envelope and the Markdown rendering; the documented opt-out flag suppresses only the Markdown.

## Assumptions

- The build-output envelope is the authoritative input for the renderer. It wraps the issue [#72](https://github.com/lambdasistemi/amaru-treasury-tx/issues/72) mechanical report under `result.report`, carries `intent` at the top level, carries transaction CBOR under `result.tx-cbor` on success, and makes the intent the sole transaction-type carrier.
- The unified-intent JSON shape produced by the wizard layer (used today as `intent.json`) is the same shape carried inline by the build-output envelope; downstream tools that already consume the standalone intent can consume the inline copy without translation.
- A treasury metadata source describing per-scope treasury addresses, treasury and permissions and registry script hashes, and per-scope scope-owner key hashes is available to operators and is the primary identity source for the renderer; the renderer falls back gracefully when it is absent.
- The Sundae swap-order address can be derived deterministically from the treasury script hash already present in the report, so the renderer needs no external lookup to label swap-order outputs.
- The era and network identifiers needed to derive UTC validity bounds are already carried by the nested mechanical report (or by the runtime constants the report identifies), so the renderer can derive UTC instants offline.
- A chain-explorer URL pattern keyed by network identifier is acceptable as the link target for transaction ids; the renderer does not validate that the explorer page exists.
- The operator-facing helper script that wraps the build flow is the documented integration point for default-on Markdown rendering, even if its current path or name evolves; the spec requires a default-on behaviour and a documented opt-out, not a specific script location.
- Personal-name signer labels are explicitly out of scope; the role label per scope is sufficient, since reviewers know who holds each scope's key, and credential rotation should be a metadata change rather than a code change.
- Issue [#70](https://github.com/lambdasistemi/amaru-treasury-tx/issues/70) (quote-derived parameter filling) may later consume the same Markdown rendering and the inline intent, but issue #74 does not depend on issue #70 being complete.
