# Contract: Local Devnet Smoke

## Entrypoints

The feature exposes a manual smoke command:

```bash
just devnet-smoke PHASE
```

Direct script form:

```bash
scripts/smoke/devnet-local \
  --phase PHASE \
  --run-dir PATH \
  --reward-timeout-seconds N
```

`PHASE` is one of:

- `node`: start the devnet, verify socket/magic/timing, then exit.
- `withdraw`: run `node`, prepare or require reward state, wait for
  positive rewards, and emit a withdrawal intent.
- `disburse`: run `node`, prepare or require local treasury state, run
  disburse wizard/build, and emit build artifacts.
- `all`: run all available phases in order.

## Environment

- Must run from the repository root.
- Must run inside `nix develop` after implementation, so the
  `cardano-node` binary and Cabal dependencies are available.
- `CARDANO_NODE_SOCKET_PATH` is managed by the smoke and must not be
  required from the caller.

## Output

Every run prints a short summary to stdout:

```text
devnet-smoke: run-dir PATH
devnet-smoke: network devnet magic 42
devnet-smoke: epoch-duration SECONDS
devnet-smoke: socket PATH
devnet-smoke: phase PHASE STATUS
```

Successful withdrawal output also includes:

```text
devnet-smoke: rewards-lovelace N
devnet-smoke: reward-account ACCOUNT
devnet-smoke: withdraw-intent PATH
```

Successful disburse/build output also includes:

```text
devnet-smoke: disburse-intent PATH
devnet-smoke: build-log PATH
devnet-smoke: unsigned-cbor PATH
devnet-smoke: report-json PATH
```

## Artifact Layout

Given `--run-dir runs/devnet/20260511T120000Z`, the smoke writes:

```text
runs/devnet/20260511T120000Z/
|-- summary.json
|-- summary.log
|-- node.log
|-- timing.json
|-- withdraw/
|   |-- intent.json
|   `-- rewards.json
`-- disburse/
    |-- intent.json
    |-- build.log
    |-- unsigned.cbor
    |-- report.json
    `-- report.md
```

## Failure Contract

The command exits non-zero and prints a typed failure prefix:

- `NODE_NOT_READY`: socket or LSQ readiness failed.
- `NETWORK_MISMATCH`: observed network magic is not `42`.
- `REWARDS_TIMEOUT`: rewards stayed zero through the wait budget.
- `MISSING_TREASURY_STATE`: required wallet, treasury, registry, or
  permissions UTxO was not available.
- `BUILD_FAILED`: wizard or `tx-build` failed after prerequisites
  were satisfied.

Failure summaries must include the run directory and the last
available observation for the failed boundary.

## Non-Goals

- The release-facing `amaru-treasury-tx` command does not sign or
  submit transactions.
- The smoke is not part of default CI.
- The smoke does not claim public-network compatibility for the
  local-only `devnet` network name.
