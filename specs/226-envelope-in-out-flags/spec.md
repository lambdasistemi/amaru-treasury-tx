# spec — #226 `--in` / `--out` flags for the envelope filters

## Problem

`envelope-tx`, `envelope-witness`, `envelope-signed-tx` and
`de-envelope` are parsed as `pure Cmd…` with no options
(`lib/Amaru/Treasury/Cli.hs`); they read stdin and write stdout only.
Operators composing rundir scripts must redirect, and
`envelope-tx --in a --out b` fails with `Invalid option`. (The issue's
table claiming two of them already take `--in`/`--out` is wrong on
`main` 9670aaff.)

## User story

US-1 — As an operator scripting a rundir, I pass
`--in "$RUNDIR/x" --out "$RUNDIR/y"` to any of the four envelope
commands and get exactly the bytes the stdin/stdout form would have
produced, without shell redirection.

## Requirements

- REQ-1 — Each of the four commands accepts optional `--in FILE` and
  optional `--out FILE`, independently.
- REQ-2 — `--in` omitted → read stdin; `--out` omitted → write stdout;
  with both omitted the behaviour is byte-identical to `main`.
- REQ-3 — `--out FILE` receives exactly the bytes the stdin/stdout form
  writes to stdout for the same input; nothing else is written to
  stdout in that case.
- REQ-4 — `de-envelope` failure (bad/stale envelope) keeps today's
  stderr text and exit 1; with `--out FILE` the file is not created or
  modified.
- REQ-5 — `--help` of each command shows `--in FILE` and `--out FILE`
  with one-line help text naming the stdin/stdout default.
- REQ-6 — Operator docs that show these commands (`docs/`,
  `skills/amaru-treasury-tx-operator/`, `README.md`) mention the flags
  where they present the command, in the same diff.

## Invariants

| ID | Holds when | Fails when |
|---|---|---|
| INV-1 | for every command and every fixture in `test/fixtures/106-cardano-cli-oracle`, the `--in`/`--out` run produces a file byte-equal to the stdin→stdout run, executed through the real CLI entry point | any command rejects the flags (current `main`) or bytes differ |
| INV-2 | each flag works alone (`--in` → stdout, stdin → `--out`) | only the combined form works |
| INV-3 | the no-flag form is byte-identical to `main`: existing smoke (`scripts/smoke/cardano-cli-envelope-oracle`), unit and golden suites pass unmodified in their existing assertions | any existing assertion changes or fails |
| INV-4 | `de-envelope --out F` on an invalid envelope exits 1, writes the existing diagnostic to stderr, and leaves `F` absent/unchanged | `F` is created, truncated or written |
| INV-5 | `--help` text for all four commands contains `--in FILE` and `--out FILE`, checked by a CI-run command | help omits a flag, or no CI command checks it |
| INV-6 | the INV-1/INV-2/INV-4/INV-5 checks run in a CI job (`unit`, `golden` or `smoke`) and fail on `main` 9670aaff | checks are skipped, local-only, or pass on `main` |
| INV-7 | the operator docs listed in REQ-6 mention the flags where they show these commands | docs show the commands with no mention of the flags |

## Non-goals

- No change to envelope/de-envelope CBOR or JSON semantics.
- No deprecation of stdin/stdout.
- No short flags; no change to any other subcommand.
