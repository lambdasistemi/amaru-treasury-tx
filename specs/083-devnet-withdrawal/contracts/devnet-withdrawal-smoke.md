# Contract: DevNet Withdrawal Smoke

## Command

```bash
nix develop --quiet -c just devnet-smoke withdraw
```

Optional script form:

```bash
scripts/smoke/devnet-local --phase withdraw \
  --run-dir runs/devnet/<timestamp> \
  --reward-timeout-seconds 600
```

## Success Artifacts

```text
runs/devnet/<timestamp>/
|-- summary.json
|-- summary.log
|-- timing.json
|-- node.log
`-- withdraw/
    |-- governance-prerequisite.json
    |-- intent.json
    |-- tx-body.cbor.hex
    |-- report.json
    |-- report.md
    |-- tx-build.log
    `-- summary.json
```

## Summary Fields

- `phase`: `withdraw`
- `status`: `passed`
- `network`: `devnet`
- `networkMagic`: `42`
- `rewardAccount`
- `rewardBeforeLovelace`
- `rewardAfterGovernanceLovelace`
- `withdrawRewardsLovelace`
- `intentPath`
- `txBodyPath`
- `reportJsonPath`
- `reportMarkdownPath`
- `txBuildLogPath`
- `txId`
- `upstreamCardanoNodeClientsMain`

## Failure Contract

Pre-intent failures write no success `intent.json` or
`tx-body.cbor.hex`. `tx-build` failures preserve the already-written
intent and fresh build report/log when available, but remove the tx
body so stale unsigned CBOR cannot be mistaken for success.

Diagnostics must include:

- failing phase,
- stable failure code,
- single-line message,
- last observed reward value when available,
- epoch/tip context when available,
- preserved artifact paths.
