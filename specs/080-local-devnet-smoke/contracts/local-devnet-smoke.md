# Contract: DevNet Governance Smoke

## Entrypoints

Manual smoke command:

```bash
just devnet-smoke PHASE
```

Direct script form:

```bash
scripts/smoke/devnet-local --phase PHASE --run-dir PATH
```

`PHASE` is one of:

- `node`: start the DevNet, verify socket/magic/timing, then exit.
- `governance`: run the node boundary, prepare governance setup state,
  submit the treasury-withdrawal governance action, and record evidence.
- `all`: run all phases implemented by this slice.

`withdraw` and `swap` are not part of this contract; they are tracked
by #83 and #84.

## Environment

- Must run from the repository root.
- Must run inside `nix develop` after implementation.
- `CARDANO_NODE_SOCKET_PATH` is managed by the smoke and must not be
  required from the caller.
- Any local setup signing/submission remains harness-internal.

## Output

Every run prints a short summary:

```text
devnet-smoke: run-dir PATH
devnet-smoke: network devnet magic 42
devnet-smoke: epoch-duration SECONDS
devnet-smoke: socket PATH
devnet-smoke: phase PHASE STATUS
```

Successful governance output also includes:

```text
devnet-smoke: governance-tx-id TXID
devnet-smoke: governance-action-id ACTION_ID
devnet-smoke: reward-account ACCOUNT
devnet-smoke: governance-amount LOVELACE
devnet-smoke: governance-summary PATH
```

## Artifact Layout

Given `--run-dir runs/devnet/20260511T120000Z`, the smoke writes:

```text
runs/devnet/20260511T120000Z/
|-- summary.json
|-- summary.log
|-- node.log
|-- timing.json
`-- governance/
    |-- certificates.json
    |-- action.json
    `-- summary.json
```

## Failure Contract

The command exits non-zero and prints a typed failure prefix:

- `NODE_NOT_READY`: socket or readiness failed.
- `NETWORK_MISMATCH`: observed network magic is not `42`.
- `MISSING_GOVERNANCE_FUNDS`: local protocol treasury/reserve setup is insufficient.
- `MISSING_UPSTREAM_GOVERNANCE_SUPPORT`: required `cardano-node-clients` support is unavailable.
- `GOVERNANCE_ACTION_NOT_OBSERVED`: submission completed but the action boundary was not observed within the wait budget.

Failure summaries must include the run directory and the last available
observation for the failed boundary.

## Non-Goals

- The release-facing `amaru-treasury-tx` command does not sign or
  submit transactions.
- The smoke is not part of default CI.
- The smoke does not claim public-network governance compatibility.
