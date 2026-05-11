# Contract: tx-build Failure Output

## CLI Contract

For expected builder failures, `tx-build` exits non-zero and writes one stable diagnostic through the existing build trace/stderr path.

The diagnostic:

- starts with `tx-build:`;
- contains a stable failure class in words;
- labels numeric lovelace fields;
- does not include `runSwap: build failed`, `runDisburse: build failed`, `runWithdraw: build failed`, `user error`, or an unhandled exception prefix.

Example shape:

```text
tx-build: balance failed: insufficient fee capacity (requiredFeeLovelace=577583, availableInputLovelace=1450020000000)
```

The exact wording may change during implementation, but the message must keep labeled fields and stable failure class language.

Internally, the diagnostic is structured. Action, phase, network, report destination, or selected input context is attached as typed context and rendered only here.

## Report Contract

The existing failure envelope shape remains:

```json
{
  "intent": { "...": "inline intent JSON" },
  "result": {
    "failure": {
      "code": "balance-insufficient-fee",
      "message": "tx-build: balance failed: insufficient fee capacity (requiredFeeLovelace=577583, availableInputLovelace=1450020000000)"
    }
  }
}
```

`result.tx-cbor` and `result.report` are absent on failure.

## Stable Codes

| Failure | Code |
|---|---|
| Insufficient fee balance failure | `balance-insufficient-fee` |
| Fee convergence failure | `balance-fee-not-converged` |
| Collateral shortfall | `balance-collateral-shortfall` |
| Script evaluation failure | `script-evaluation-failed` |
| Final validation failure | `validation-failed` |
| Fee bump failure | `fee-bump-failed` |
| Missing required UTxOs | `missing-utxos` |
| Fee alignment failure | `fee-alignment-failed` |
| Unsupported action | `unsupported-action` |

## Non-Goals

- No change to success envelope shape.
- No change to transaction balancing semantics.
- No promise that the insufficient-fee numeric fields alone identify the business-level affordability gap.
- No string-prefix exception composition inside runner internals; context composition should stay typed. Use `mapException` where pure exception mapping applies, and an equivalent typed `try`/`catch` wrapper for `IO` exceptions.
