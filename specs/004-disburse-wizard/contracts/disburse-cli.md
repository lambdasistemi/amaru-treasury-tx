# Contract: `amaru-treasury-tx disburse` CLI

**Plan**: [../plan.md](../plan.md) · **Spec**: [../spec.md](../spec.md)
**Date**: 2026-05-06

This file fixes the user-visible CLI surface for the `disburse`
subcommand: options, defaults, exit codes, and stdout shape. Mirrors
the `swap` subcommand contract (which is documented inline in the
existing
[`app/amaru-treasury-tx/Main.hs`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/app/amaru-treasury-tx/Main.hs)).

## 1. Subcommand and options

```text
amaru-treasury-tx [--node-socket PATH]
                  (--network mainnet|preprod|preview | --network-magic N)
    disburse
    [--intent PATH]            (defaults to stdin)
    [--out PATH]               (defaults to stdout)
    [--summary-out PATH]       (defaults to disburse.summary.json in CWD)
    [--log PATH]               (defaults to stderr)
```

Notes:

- The intent JSON is read from `--intent <path>` if given, otherwise
  from stdin. This is what makes `disburse-wizard ... | disburse`
  work without an intermediate file.
- `--out` writes the unsigned hex CBOR. Defaults to stdout.
- `--summary-out` writes the summary sidecar JSON. Defaults to
  `disburse.summary.json` in the current directory.
- `--log` writes typed trace events. Defaults to stderr.
- The network and node socket follow the same global-flag conventions
  as every other subcommand.

## 2. Stdout / stderr shape

- The unsigned Conway transaction hex CBOR is written to `--out` (or
  stdout if omitted) as exactly one line: hex characters, no prefix,
  no whitespace, no trailing JSON.
- The summary JSON is written to `--summary-out`.
- Step-by-step typed trace events go to `--log` (or stderr).
- Errors go to stderr as a single line with `disburse: <message>`
  prefix.

## 3. Exit codes

| Code | Meaning |
|------|---------|
| 0 | Tx built, balanced, all redeemers re-evaluated successfully; CBOR + summary emitted. |
| 1 | One or more redeemers failed re-evaluation; summary still emitted with the failure. |
| 2 | Invalid CLI args (handled by `optparse-applicative`). |
| 3 | Intent JSON parse failure (typed message identifies the parse position). |
| 4 | Translation error (`String` returned by `translateDisburseIntent`). |
| 5 | Build / balance error (e.g. insufficient ADA in selected inputs after fee estimation). |

`0` is reserved for fully successful builds. A built-but-failing-
script case exits `1` — the summary captures the per-script failure
detail and the CBOR is still emitted (operator may inspect it).

## 4. Summary sidecar

Conforms to
[`specs/001-treasury-tx-cli/contracts/summary-schema.json`](../../001-treasury-tx-cli/contracts/summary-schema.json)
unchanged. Top-level fields populated by the disburse path:

| Field | Source |
|-------|--------|
| `txId` | computed from the body bytes |
| `feeLovelace` | balancer output |
| `totalCollateralLovelace` | balancer output |
| `redeemers[]` | one entry per `ScriptResult` in build order |
| `redeemers[].purpose` | `"spend" \| "withdraw"` |
| `redeemers[].index` | canonical sorted-input / sorted-withdrawal index |
| `redeemers[].exUnits` | from re-evaluation |
| `redeemers[].failure` | populated when `ScriptResult` is `Left` |

## 5. Trace event categories

Typed events emitted on `--log` (constructors live in
`Amaru.Treasury.Tx.Disburse.Trace`):

- `DeIntentSource`: path or `<stdin>`.
- `DeConnect`: socket path.
- `DeRequiredUtxos`: count of UTxOs needed for the build.
- `DeBuilt`: cbor byte length, fee, total collateral.
- `DeReevaluated`: total redeemer count, failure count.
- `DeScriptFail`: one event per failed redeemer with purpose + error
  string.
- `DeWroteCbor`: output path or `<stdout>`.
- `DeWroteSummary`: summary path.
- `DeValidationOk` / `DeValidationFailed`: terminal event.
- `DeAborted`: typed error message (terminal event for parse /
  translate / build failures).

Mirrors `Amaru.Treasury.Tx.Swap.Trace` 1:1; the constructor prefix
`De-` distinguishes disburse events.

## 6. Out of scope for v0

- A `--blacklist-file` / `--exclude` UTxO blacklist (the wizard
  already pinned the treasury inputs).
- `--ttl-seconds` (the validity bound is set by the wizard, carried
  through the JSON).
- Multi-network builds in one invocation.
