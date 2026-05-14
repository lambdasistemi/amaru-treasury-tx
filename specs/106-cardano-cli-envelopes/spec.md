# Feature Specification: pipeline-friendly envelope / de-envelope commands

**Feature Branch**: `feat/106-cardano-cli-envelopes`
**Created**: 2026-05-14
**Status**: Draft
**Issue**: [#106](https://github.com/lambdasistemi/amaru-treasury-tx/issues/106)
**Input**: "I want a command to envelope and deenvelop tx and witnesses, both pipeline friendly."

## Background

`cardano-cli` reads and writes transactions and witnesses as JSON envelopes: `{"type": "...", "description": "...", "cborHex": "..."}`. Operators who flow files between `cardano-cli` and our pipeline today have to translate by hand (`jq -r .cborHex` going in, `jq -n --arg cbor "$(cat ...)" '{type:"...",cborHex:$cbor}'` going out).

Rather than bolting envelope-awareness into every existing command, this feature adds **four small composable filters** that translate between the envelope shape and the raw CBOR hex our existing pipeline already speaks. Existing commands (`tx-build`, `attach-witness`, `submit`) are unchanged — operators compose the new filters at the pipeline ends where the shape needs to switch.

## User Scenarios & Testing *(mandatory)*

### User Story 1 — Wrap raw tx hex into a `cardano-cli` body envelope (Priority: P1)

An operator just produced an unsigned tx via `tx-build` and wants to hand it to a signer who only accepts the `cardano-cli` `Tx ConwayEra` envelope shape on disk.

**Why this priority**: Without this, the operator pipes `tx-build` into a hand-written `jq` recipe to wrap the hex. Every operator script ends up reimplementing the same wrapper.

**Independent Test**: `echo deadbeef | amaru-treasury-tx envelope-tx` emits JSON whose `type` is `"Tx ConwayEra"` and whose `cborHex` field is `"deadbeef"`.

**Acceptance Scenarios**:

1. **Given** raw CBOR hex on stdin, **When** running `envelope-tx`, **Then** stdout contains a single JSON envelope with `type: "Tx ConwayEra"`, the canonical `description`, and `cborHex` equal to the stdin bytes verbatim.
2. **Given** the pipeline `tx-build --out - | envelope-tx > body.tx.body.json`, **When** the operator hands `body.tx.body.json` to `cardano-cli conway transaction witness --tx-body-file body.tx.body.json`, **Then** `cardano-cli` accepts it without complaint.

---

### User Story 2 — Wrap raw witness hex into a `cardano-cli` witness envelope (Priority: P1)

Symmetric to US1, for detached vkey witnesses. An operator's hardware signer or offline signing tool produced a bare `WitVKey` CBOR hex; downstream tooling (or audit) expects the `TxWitness ConwayEra` envelope shape.

**Why this priority**: Same friction as US1 — every signer flow reinvents the wrapper.

**Independent Test**: `echo 82582000...58400... | amaru-treasury-tx envelope-witness` emits JSON whose `type` is `"TxWitness ConwayEra"` and whose `cborHex` is the stdin bytes.

**Acceptance Scenarios**:

1. **Given** raw witness CBOR hex on stdin, **When** running `envelope-witness`, **Then** stdout is a JSON envelope with `type: "TxWitness ConwayEra"`, the canonical `description`, and `cborHex` equal to the stdin bytes.
2. **Given** the pipeline `signer-tool | envelope-witness > scope-owner-1.witness.json`, **When** the operator hands the file to `cardano-cli conway transaction assemble --witness-file scope-owner-1.witness.json`, **Then** `cardano-cli` accepts it.

---

### User Story 3 — Wrap raw signed tx hex into a `cardano-cli` signed envelope (Priority: P1)

After `attach-witness` merges all witnesses, the operator wants the signed result as a `Tx ConwayEra` envelope — so they can submit through `cardano-cli conway transaction submit --tx-file` or hand the file to a tool that expects the `cardano-cli` shape.

**Why this priority**: Closes the "going out" side of the pipeline. Without this, the operator has to manually wrap the signed hex.

**Independent Test**: `echo <signedhex> | amaru-treasury-tx envelope-signed-tx | cardano-cli conway transaction submit --tx-file /dev/stdin` submits the tx (or fails for a non-envelope reason like double-spend, never for envelope-shape reasons).

**Acceptance Scenarios**:

1. **Given** raw signed CBOR hex on stdin, **When** running `envelope-signed-tx`, **Then** stdout is a JSON envelope with `type: "Tx ConwayEra"`, the canonical `description`, and `cborHex` equal to the stdin bytes.
2. **Given** the pipeline `... | attach-witness ... | envelope-signed-tx > signed.json`, **When** running `cardano-cli conway transaction submit --tx-file signed.json`, **Then** the file is accepted as a valid signed envelope.

---

### User Story 4 — Strip an envelope down to raw hex (Priority: P1)

A scope owner returned a `*.witness.json` from `cardano-cli conway transaction witness`; the operator wants to feed its `cborHex` into our existing `attach-witness --witness HEX` flow.

**Why this priority**: Closes the "coming in" side of the pipeline. Without this, every operator runs `jq -r .cborHex` by hand.

**Independent Test**: `cat scope-owner-1.witness.json | amaru-treasury-tx de-envelope` emits exactly the `cborHex` string from the envelope on stdout, with no trailing whitespace beyond a single newline.

**Acceptance Scenarios**:

1. **Given** a `TxWitness ConwayEra` envelope JSON on stdin, **When** running `de-envelope`, **Then** stdout is the `cborHex` value (raw hex, no JSON, no quotes) followed by a single trailing newline.
2. **Given** a `Tx ConwayEra` envelope on stdin, **When** running `de-envelope`, **Then** the same extraction works — `de-envelope` does not care which Conway envelope kind it is given.
3. **Given** the pipeline `cat body.tx.body.json | de-envelope | attach-witness --witness HEX ...`, **When** running, **Then** `attach-witness` consumes the unsigned tx bytes from stdin and merges the witness, with no `jq` step needed.

---

### User Story 5 — `de-envelope` refuses non-Conway envelopes (Priority: P2)

The operator pipes a stale `Tx BabbageEra` envelope into the pipeline. We catch it before it reaches the node.

**Why this priority**: Defence-in-depth. The node would reject the tx anyway, but rejecting at the seam saves a round-trip and surfaces the error where the operator can fix it (re-export the tx in Conway, or stop using the stale file).

**Independent Test**: `cat babbage.tx.body.json | amaru-treasury-tx de-envelope` exits non-zero with a stderr diagnostic that names the era found.

**Acceptance Scenarios**:

1. **Given** any envelope whose `type` field does not contain `ConwayEra`, **When** running `de-envelope`, **Then** the command exits with code 1 and stderr contains the literal `type` string from the envelope.
2. **Given** malformed JSON on stdin (file starts with `{` but does not parse), **When** running `de-envelope`, **Then** the command exits with code 1 and stderr names the JSON decode error.

---

### Edge Cases

- **Empty stdin** — `envelope-*` commands receive zero bytes on stdin: they emit an envelope whose `cborHex` is `""` (the empty string). The wrapper has no domain knowledge of what valid CBOR is.
- **Trailing whitespace on input hex** — `envelope-*` commands strip trailing ASCII whitespace from stdin (the common pipe artefact); they do **not** strip internal whitespace. The body of the `cborHex` field is the trimmed value.
- **Trailing newline on output hex** — `de-envelope` always emits exactly one trailing newline after the hex so the output composes safely with `attach-witness` and `submit`, which already accept a trailing newline on their stdin.
- **Unknown `description`** — `de-envelope` ignores the `description` field entirely. `envelope-*` commands always emit the canonical `description` for their kind.
- **Extra JSON keys** — an envelope with extra top-level keys (e.g. an editor's `_source` field) is accepted by `de-envelope` as long as `type` and `cborHex` are present and well-typed; extra keys are ignored.
- **Non-`{` first byte on `de-envelope` stdin** — rejected with a typed error naming the first byte. We do **not** silently pass raw hex through; the caller asked for de-enveloping and we surface the mismatch.
- **`envelope-*` stdin contains JSON** — accepted verbatim as a string into `cborHex`. The commands are dumb wrappers; semantic validity of the hex is a downstream concern.

## Requirements *(mandatory)*

### Functional Requirements

#### Subcommands

- **FR-1** New subcommand `envelope-tx`: reads raw CBOR hex on stdin, writes a single JSON envelope on stdout with `type: "Tx ConwayEra"`, the canonical `description`, and `cborHex` equal to the (trailing-whitespace-trimmed) stdin bytes.
- **FR-2** New subcommand `envelope-witness`: same shape, `type: "TxWitness ConwayEra"`.
- **FR-3** New subcommand `envelope-signed-tx`: same shape, `type: "Tx ConwayEra"`.
- **FR-4** New subcommand `de-envelope`: reads a JSON envelope on stdin, validates that the `type` field contains `ConwayEra`, and writes the `cborHex` value (raw, unquoted, no JSON) followed by a single trailing newline on stdout.

#### Output format

- **FR-5** All `envelope-*` commands emit JSON with exactly three top-level keys in this order: `type`, `description`, `cborHex`. Indentation is four spaces. The output ends in a single trailing newline.
- **FR-6** The canonical `description` is `"Ledger Cddl Format"` for tx envelopes and `"Key Witness ShelleyEra"` for witness envelopes (matching what `cardano-cli` emits today).

#### Validation

- **FR-7** `de-envelope` refuses non-Conway envelopes with exit code 1 and a stderr diagnostic that includes the offending `type` string.
- **FR-8** `de-envelope` refuses input whose first non-whitespace byte is not `{` (raw hex or other non-JSON input) with exit code 1 and a stderr diagnostic that names the first byte.
- **FR-9** `de-envelope` refuses input that begins with `{` but fails JSON parsing with exit code 1 and a stderr diagnostic that includes the JSON decode error.

#### Untouched

- **FR-10** `attach-witness`, `submit`, and `tx-build` are not changed by this feature. Their flag sets, defaults, and pipe behaviour are byte-identical before and after.

### Key Entities

- **Envelope** — a `{type, description, cborHex}` JSON object as emitted/consumed by `cardano-cli`. The `type` field is the discriminator. `description` is informational and not parsed.
- **EnvelopeKind** — internal tag identifying which `type` string a wrapper command emits (`Tx`, `Witness`, `SignedTx`). Each `envelope-*` subcommand binds to one kind.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-1** The four pipelines below all complete with exit code 0 and produce byte-identical output to the equivalent hand-rolled `jq` recipe on the same inputs:
  - `echo $HEX | envelope-tx`
  - `echo $HEX | envelope-witness`
  - `echo $HEX | envelope-signed-tx`
  - `cat envelope.json | de-envelope`
- **SC-2** Round-trip identity: `envelope-tx | de-envelope`, `envelope-witness | de-envelope`, `envelope-signed-tx | de-envelope` all emit the original input bytes verbatim (modulo a single trailing newline) for any input.
- **SC-3** A real `cardano-cli`-emitted `*.witness.json` (checked-in oracle fixture under `test/fixtures/106-cardano-cli-oracle/`) is accepted by `de-envelope` and produces a `cborHex` byte-identical to the file's `cborHex` field.
- **SC-4** A real raw witness hex (checked-in oracle fixture, the same bytes the oracle `cardano-cli` was given) piped through `envelope-witness` produces a file byte-identical to the `cardano-cli`-emitted `*.witness.json` from the oracle.
- **SC-5** A stale `Tx BabbageEra` envelope (checked-in fixture) piped through `de-envelope` exits non-zero with a stderr line containing the literal string `BabbageEra`.
- **SC-6** The v0.2.5.1 `tx-build | attach-witness | submit` pipeline is byte-identical on this branch (raw-hex path untouched).
- **SC-7** `nix develop -c just ci` is green.

## Assumptions

- The Cardano envelope format is stable for Conway-era. We do not need to track or accept older eras; envelopes tagged with older eras are rejected, not transcoded.
- `cardano-cli`'s emitted byte shape (four-space indent, three-key order, canonical `description` strings, trailing newline) is a stable contract for Conway era. If a future `cardano-cli` version emits a different shape, that's a new ticket — pinned by the checked-in oracle fixture.
- Operators willing to use these filters are comfortable with the Unix pipe model. Operators who want flag aliases on `attach-witness` (à la `cardano-cli --tx-body-file`) are out of scope; they can compose `de-envelope | attach-witness` instead.

## Out of Scope

- Modifying `attach-witness`, `submit`, or `tx-build`. Their interfaces are frozen.
- Byron / Shelley / Allegra / Mary / Alonzo / Babbage envelopes. Rejected at the `de-envelope` seam.
- Reading or writing the cardano-cli `Genesis*Key`, `*VerificationKey`, etc. envelope kinds. Only tx and witness envelopes.
- An `envelope` mega-command with a `--kind` flag. The CLI shape is four small commands by design (US1..US4 are independent stories; their tests are independent).
- File-path input/output (`--in PATH` / `--out PATH`). All four commands are stdin/stdout only. File I/O is the shell's job.
- Wrapping our `intent.json` in an envelope. `intent.json` is our own contract.
