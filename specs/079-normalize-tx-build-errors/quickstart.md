# Quickstart: Normalized tx-build Failures

## Goal

Verify expected builder failures travel through the same normalized diagnostic path for CLI stderr and report envelopes.

## Unit-Level Smoke

Run the focused tests after implementation:

```bash
nix develop --quiet -c just unit "TreasuryBuild"
nix develop --quiet -c just unit "Report"
```

Expected:

- normalizer tests pass for every current upstream `BuildError` constructor;
- failure envelope tests assert stable `code` and `message` values;
- no expected failure assertion matches raw `show (BuildError ())` output.

## CLI-Level Smoke

Use a fixture or synthetic context that forces a builder failure after intent parsing. Then run:

```bash
amaru-treasury-tx \
  --node-socket "$CARDANO_NODE_SOCKET_PATH" \
  tx-build \
  --intent failing.intent.json \
  --report -
```

Expected stdout shape:

```json
{
  "intent": {},
  "result": {
    "failure": {
      "code": "balance-insufficient-fee",
      "message": "tx-build: balance failed: insufficient fee capacity ..."
    }
  }
}
```

Expected stderr/log:

```text
tx-build: parsed action=...
tx-build: ...
tx-build: balance failed: insufficient fee capacity ...
```

The output must not contain:

- `runSwap: build failed`
- `runDisburse: build failed`
- `runWithdraw: build failed`
- `user error`
- `Uncaught exception`

## Full Gate

Before PR handoff:

```bash
nix develop --quiet -c just ci
```
