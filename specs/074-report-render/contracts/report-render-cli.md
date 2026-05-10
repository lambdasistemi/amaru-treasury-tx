# Contract — `report-render` CLI

Tracking issue: [#74](https://github.com/lambdasistemi/amaru-treasury-tx/issues/74)

This is the public CLI contract added by feature 074. It also
documents the additive `--report -` change to the existing
`tx-build` subcommand.

## `amaru-treasury-tx report-render`

Reads a JSON build-output envelope written by `tx-build --report`
and emits operator-friendly Markdown. On success envelopes, the
nested `result.report` is the mechanical report from issue
[#72](https://github.com/lambdasistemi/amaru-treasury-tx/issues/72).

### Synopsis

```text
amaru-treasury-tx report-render
    [--in PATH | --in -]
    [--out PATH | --out -]
    [--metadata PATH]
```

### Options

| Flag             | Argument | Default                                | Effect |
|------------------|----------|----------------------------------------|--------|
| `--in`           | `PATH` or `-` | stdin                            | Read the JSON build-output envelope from this stream. |
| `--out`          | `PATH` or `-` | stdout                           | Write the Markdown rendering to this stream. |
| `--metadata`     | `PATH`   | `journal/2026/metadata.json` if it exists, else none | Treasury metadata source for identity resolution. |

### Streams

- No flags: stdin → stdout. The pipeline
  `tx-build --report - | report-render > report.md` is the canonical
  invocation.
- `-` is accepted as the explicit stdio alias for `--in` and
  `--out` and is equivalent to omitting the flag.
- Output write failures cause the command to exit with a non-zero
  status and print the failure to stderr (FR-025).
- Envelopes whose top-level `intent` or `result` field is missing or
  malformed are invalid; success results whose `tx-cbor` or `report`
  field is missing or malformed are invalid. The command exits
  non-zero and reports the decode failure.
- Valid failure envelopes may be rendered as failure diagnostics, but
  they are not signable transaction reviews and the command exits
  non-zero so a shell pipeline does not mask the failed build.
- There is no renderer argument for a separate intent file. The
  envelope's top-level `intent` is the only source of intent data.
- The rendered transaction type is read from the inline `intent`.
  Envelopes and nested reports do not carry a separate top-level
  action/type field.

### Determinism

- Output is byte-identical for identical inputs (FR-009, SC-002).
- No wall-clock, randomness, environment reads beyond declared
  inputs, or local-machine state.

### Output shape (informative)

The rendered Markdown follows this top-level structure:

1. `# <transaction-type> on <scope>` — title (line 1).
2. Blank line.
3. **Leading section** (lines 3..27, i.e. first 25 lines after the
   title and blank): transaction type from the inline intent, scope,
   transaction id with explorer link, CBOR fingerprint/hash, validity
   bounds (slots + UTC), conservation line, required signers (role
   labels), and, for swap intents, a swap-deal summary block.
4. Sections: produced outputs (collapsed where applicable), inputs,
   reference inputs, signers, validation facts, CIP-1694 rationale
   (when present).
5. Trailing newline.

The leading-section bound (lines 3..27 = 25 lines) is the
reproducibly assertable form of issue #74's "first 30 lines"
property and is the bound SC-001 enforces.

## `amaru-treasury-tx tx-build` (additive change)

The existing `--report PATH` argument now also accepts the literal
`-` as an alias for stdout. All previous `--report PATH`
invocations are unchanged.

```text
amaru-treasury-tx tx-build
    ...
    [--report PATH | --report -]
    ...
```

This change makes the end-to-end pipeline
`tx-build --report - | report-render > report.md` an in-tree
contract. Envelopes newly produced by the in-tree build path include
the required top-level `intent` value that was decoded and passed
through unchanged, using the same unified-intent JSON shape as the
standalone intent file, and required top-level `result`.

On success, `result` is:

```json
{
  "tx-cbor": "84a4...",
  "report": {}
}
```

On failure after intent decoding, `result` is:

```json
{
  "failure": {}
}
```

The success `tx-cbor` value contains the unsigned transaction CBOR as
lowercase hex. The success `report` value contains the mechanical
report: the builder's explanation of the relevant transaction facts,
so consumers do not need to parse CBOR to understand what was built.
The failure value explains why no transaction was created. If the
originating intent cannot be decoded, the build path cannot form the
envelope and exits with the existing parse failure.

## `scripts/ops/build-swop` (new helper)

A POSIX-shell wrapper that runs the swap build flow end to end and,
by default, also produces `report.md` next to `report.json`.

### Synopsis

```text
scripts/ops/build-swop [--no-markdown] [other build flags...]
```

### Default behaviour

- Runs `amaru-treasury-tx tx-build --report <path>/report.json`.
- Then runs
  `amaru-treasury-tx report-render --in <path>/report.json --out <path>/report.md`.

### `--no-markdown`

Suppresses the second step. The JSON build-output envelope is still
produced.
Documented as the supported way to skip Markdown.

### Failure mode

The helper exits non-zero if either step fails. It never produces
a stale `report.md` from a previous run; it removes any prior
`report.md` before invoking the renderer.
