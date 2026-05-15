# Quickstart: DevNet Withdrawal Slice

## Prerequisites

- Branch includes the #82 governance DevNet harness.
- `cardano-node-clients` pin has been refreshed to the merged upstream
  `main` commit containing #132.
- Local machine can enter the repository Nix shell.

## Run

```bash
nix develop --quiet -c just devnet-smoke withdraw
```

## Expected Result

The command starts a short-epoch local DevNet, prepares governance
prerequisite reward state, runs `withdraw-wizard` against the live node,
then runs `tx-build` on the live withdraw intent. The opt-in DevNet
harness signs and submits that built transaction and waits for the
treasury output that materializes the withdrawn ADA.

On success, inspect:

```text
runs/devnet/<timestamp>/withdraw/summary.json
runs/devnet/<timestamp>/withdraw/intent.json
runs/devnet/<timestamp>/withdraw/tx-body.cbor.hex
runs/devnet/<timestamp>/withdraw/signed-tx.cbor.hex
runs/devnet/<timestamp>/withdraw/submit.log
runs/devnet/<timestamp>/withdraw/materialized.json
runs/devnet/<timestamp>/withdraw/report.json
runs/devnet/<timestamp>/withdraw/report.md
```

The intent must contain `action = "withdraw"` and
`rewardsLovelace > 0`. The final summary and materialization artifact
must show `submittedTxAccepted = true`, `rewardAfterSubmitLovelace = 0`,
and `materializedAdaLovelace` equal to the withdrawn rewards. This
signing/submission is local DevNet harness behavior; the release-facing
CLI still emits unsigned transactions for the operator signer flow.
