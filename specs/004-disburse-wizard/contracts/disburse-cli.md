# Contract: `amaru-treasury-tx tx-build` for disburse intents

**Plan**: [../plan.md](../plan.md) · **Spec**: [../spec.md](../spec.md)
**Date**: 2026-05-06

This file fixes the user-visible build surface for disburse intents.
After feature 005, feature 004 does **not** add a per-action
`disburse` subcommand. `disburse-wizard` emits a unified
`TreasuryIntent` with top-level `schema` and `action = "disburse"`;
the existing `tx-build` subcommand decodes that JSON and dispatches to
the disburse builder.

## 1. Subcommand and options

```text
amaru-treasury-tx [--node-socket PATH]
    tx-build
    [--intent PATH]            (defaults to stdin)
    [--out PATH]               (defaults to stdout)
    [--log PATH]               (defaults to stderr)
```

Notes:

- The intent JSON is read from `--intent <path>` if given, otherwise
  from stdin. This is what makes `disburse-wizard ... | tx-build`
  work without an intermediate file.
- `--out` writes the unsigned hex CBOR. Defaults to stdout.
- `--log` writes typed trace events. Defaults to stderr.
- The node socket follows the same global-flag convention as every
  other subcommand. The network is read from `intent.network`; the CLI
  does not accept a second network flag for this subcommand.

## 2. Stdout / stderr shape

- The unsigned Conway transaction hex CBOR is written to `--out` (or
  stdout if omitted) as exactly one line: hex characters, no prefix,
  no whitespace, no trailing JSON.
- The summary JSON sidecar is added in Phase 7; the unified build
  trace already reserves a `BuildEventWroteSummary` event for that path.
- Step-by-step typed trace events go to `--log` (or stderr).
- Errors go to stderr as a single line with `tx-build: <message>`
  prefix.

## 3. Exit codes

| Code | Meaning |
|------|---------|
| 0 | Tx built, balanced, all redeemers re-evaluated successfully; CBOR + summary emitted. |
| 1 | One or more redeemers failed re-evaluation; CBOR is emitted for inspection and the trace records the failure. |
| 2 | Invalid CLI args (handled by `optparse-applicative`). |
| 3 | Intent JSON parse failure, required-UTxO derivation failure, or build setup failure. |
| 6 | The local-node socket's network magic does not match `intent.network`. |

`0` is reserved for fully successful builds. A built-but-failing-
script case exits `1` — the summary captures the per-script failure
detail and the CBOR is still emitted (operator may inspect it).

## 4. Summary sidecar

Conforms to
[`specs/001-treasury-tx-cli/contracts/summary-schema.json`](../../001-treasury-tx-cli/contracts/summary-schema.json)
unchanged once Phase 7 wires it into `tx-build`. Top-level fields
populated by the disburse path:

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
`Amaru.Treasury.Build.Trace`):

- `BuildEventIntentSource`: path or `<stdin>`.
- `BuildEventIntentParsed`: action and network read from the intent.
- `BuildEventConnect`: socket path.
- `BuildEventNetworkOk` / `BuildEventNetworkMismatch`: socket magic vs
  `intent.network`.
- `BuildEventRequiredUtxos`: count of UTxOs needed for the build.
- `BuildEventBuilt`: cbor byte length, fee, total collateral.
- `BuildEventReevaluated`: total redeemer count, failure count.
- `BuildEventScriptFail`: one event per failed redeemer with purpose + error
  string.
- `BuildEventWroteCbor`: output path or `<stdout>`.
- `BuildEventWroteSummary`: summary path once Phase 7 lands.
- `BuildEventValidationOk` / `BuildEventValidationFailed`: terminal event.
- `BuildEventAborted`: typed error message (terminal event for parse /
  translate / build failures).

The constructor prefix `BuildEvent-` distinguishes the unified treasury build
events from wizard-specific events.

## 6. Out of scope for v0

- A `--blacklist-file` / `--exclude` UTxO blacklist (the wizard
  already pinned the treasury inputs).
- `--ttl-seconds` (the validity bound is set by the wizard, carried
  through the JSON).
- Multi-network builds in one invocation.
