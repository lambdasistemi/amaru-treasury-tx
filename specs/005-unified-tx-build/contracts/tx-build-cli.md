# Contract: `amaru-treasury-tx tx-build` CLI

**Plan**: [../plan.md](../plan.md) · **Spec**: [../spec.md](../spec.md)
**Date**: 2026-05-06

This file fixes the user-visible CLI surface for the unified
`tx-build` subcommand. Replaces the `swap` subcommand and the
(un-shipped) `disburse` subcommand from feature 004's
[contracts/disburse-cli.md](https://github.com/lambdasistemi/amaru-treasury-tx/blob/004-disburse-wizard/specs/004-disburse-wizard/contracts/disburse-cli.md).

## 1. Subcommand and options

```text
amaru-treasury-tx
    tx-build
    [--node-socket PATH]      (or CARDANO_NODE_SOCKET_PATH)
    [--intent PATH]           (defaults to stdin)
    [--out PATH]              (defaults to stdout)
    [--summary-out PATH]      (defaults to <action>.summary.json
                                          in CWD)
    [--log PATH]              (defaults to stderr)
```

Notes:

- The intent JSON is read from `--intent <path>` if given, otherwise
  from stdin. This is what makes any
  `<action>-wizard ... | tx-build` pipe work without an
  intermediate file.
- `--out` writes the unsigned hex CBOR. Defaults to stdout.
- `--summary-out` writes the summary sidecar JSON. Defaults to
  `<action>.summary.json` in CWD where `<action>` is the intent's
  `action` field (e.g. `swap.summary.json`,
  `disburse.summary.json`).
- `--log` writes typed trace events. Defaults to stderr.
- **`--network`/`--network-magic` are NOT accepted on this
  subcommand.** The N2C handshake magic is derived from the
  intent's `network` field (FR-005). Operators who pass
  `--network` get an `optparse-applicative` parse error.

## 2. Stdout / stderr shape

- The unsigned Conway transaction hex CBOR is written to `--out`
  (or stdout if omitted) as exactly one line: hex characters, no
  prefix, no whitespace, no trailing JSON.
- The summary JSON is written to `--summary-out`.
- Step-by-step typed trace events go to `--log` (or stderr).
- Errors go to stderr as a single line with `tx-build: <message>`
  prefix.

## 3. Exit codes

| Code | Meaning |
|------|---------|
| 0 | Tx built, balanced, all redeemers re-evaluated successfully; CBOR + summary emitted. |
| 1 | One or more redeemers failed re-evaluation; summary still emitted with the failure. |
| 2 | Invalid CLI args (handled by `optparse-applicative`). |
| 3 | Intent JSON parse failure: bad shape, unknown `schema`, action / payload mismatch, unknown `action`. Typed message identifies the offending value. |
| 4 | Translation error (typed message from `translateTreasuryIntent`). |
| 5 | Build / balance error (e.g. insufficient ADA in selected inputs after fee estimation). |
| 6 | **Network mismatch**: N2C handshake reports a magic that differs from `intent.network`'s magic. Stderr message names both magics and both networks. |

`0` is reserved for fully successful builds. A built-but-failing-
script case exits `1` — the summary captures the per-script failure
detail and the CBOR is still emitted (operator may inspect it).

## 4. Summary sidecar

The summary file at `--summary-out` (default
`<action>.summary.json`) has the same shape as today's per-action
summary; it gains a top-level `action` field so the consumer knows
which kind of tx the summary describes.

Top-level fields:

| Field | Source |
|-------|--------|
| `action` | `intent.action` |
| `network` | `intent.network` |
| `txId` | computed from the body bytes |
| `feeLovelace` | balancer output |
| `totalCollateralLovelace` | balancer output |
| `redeemers[]` | one entry per `ScriptResult` in build order |
| `redeemers[].purpose` | `"spend"` \| `"withdraw"` \| etc. |
| `redeemers[].index` | canonical sorted-input / sorted-withdrawal index |
| `redeemers[].exUnits` | from re-evaluation |
| `redeemers[].failure` | populated when `ScriptResult` is `Left` |

## 5. Trace event categories

Typed events emitted on `--log`. Constructors live in a new
`Amaru.Treasury.TreasuryBuild.Trace` module; the constructors
mirror today's `Tx.Swap.Trace.SwapEvent` shape but the prefix
becomes `Tbe-` (for "TreasuryBuildEvent"):

- `TbeIntentSource`: path or `<stdin>`.
- `TbeIntentParsed`: the action and network read from the parsed
  intent (so the trace shows what kind of tx the build is about
  to construct).
- `TbeConnect`: socket path.
- `TbeNetworkOk`: handshake magic matches `intent.network`.
- `TbeNetworkMismatch`: handshake magic differs from
  `intent.network`. Terminal event for non-zero exit (code 6).
- `TbeRequiredUtxos`: count of UTxOs needed for the build.
- `TbeBuilt`: cbor byte length, fee, total collateral.
- `TbeReevaluated`: total redeemer count, failure count.
- `TbeScriptFail`: one event per failed redeemer with purpose +
  error string.
- `TbeWroteCbor`: output path or `<stdout>`.
- `TbeWroteSummary`: summary path.
- `TbeValidationOk` / `TbeValidationFailed`: terminal event.
- `TbeAborted`: typed error message (terminal event for parse /
  translate / build failures).

Mirrors `Amaru.Treasury.Tx.Swap.Trace.SwapEvent` 1:1 but with the
new `TbeIntentParsed` / `TbeNetworkOk` / `TbeNetworkMismatch`
events to surface the unified-intent invariants.

## 6. Out of scope for v0

- `--blacklist-file` / `--exclude` (UTxO selection happens in the
  wizard).
- `--ttl-seconds` (validity bound is set by the wizard).
- `--metadata` (verified by the wizard; build reads only the
  intent).
- A post-build "submit" verb (Constitution IV).
