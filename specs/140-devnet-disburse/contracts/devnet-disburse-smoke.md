# Contract: DevNet Disburse Smoke

## Command

```bash
nix develop --quiet -c just devnet-smoke disburse
```

Equivalent direct script form:

```bash
scripts/smoke/devnet-local --phase disburse --run-dir runs/devnet/<timestamp>
```

The phase is opt-in and not part of `just ci`.

## Success Artifacts

```text
runs/devnet/<timestamp>/
|-- node.log
|-- summary.json
|-- summary.log
|-- timing.json
|-- withdraw/
|   `-- summary.json
`-- disburse/
    |-- prerequisite.json
    |-- intent.json
    |-- tx-body.cbor.hex
    |-- report.json
    |-- report.md
    |-- tx-build.log
    |-- usdm-boundary.json
    `-- summary.json
```

The `withdraw/` subtree is prerequisite fixture evidence when the
disburse run creates treasury ADA by using the merged withdrawal smoke
path. The disburse success claim starts at `disburse/prerequisite.json`
and `disburse/intent.json`.

## Summary Fields

`disburse/summary.json`:

- `phase`: `disburse`
- `status`: `passed`
- `network`: `devnet`
- `networkMagic`
- `runDirectory`
- `socket`
- `scope`
- `unit`
- `amount`
- `beneficiaryAddress`
- `walletTxIn`
- `treasuryTxIns`
- `treasuryAddress`
- `registryReferenceTxIns`
- `signers`
- `validityUpperBoundSlot`
- `intentPath`
- `txBodyPath`
- `reportJsonPath`
- `reportMarkdownPath`
- `txBuildLogPath`
- `txId`
- `feeLovelace`
- `prerequisitePath`
- `withdrawSummaryPath`
- `usdmBoundaryPath`
- `usdmBoundaryStatus`
- `usdmDiagnosticCode`

## Failure Artifacts

Expected failures write:

```text
runs/devnet/<timestamp>/disburse/failure.json
runs/devnet/<timestamp>/disburse/summary.json
runs/devnet/<timestamp>/summary.json
```

Pre-intent failures write no success `intent.json`,
`tx-body.cbor.hex`, or reports. Build failures may preserve the fresh
intent and build log, but must remove stale unsigned CBOR and stale
success summaries.

Required diagnostic codes:

- `missing-disburse-phase`
- `missing-treasury-state`
- `insufficient-treasury-ada`
- `missing-wallet-fuel`
- `missing-wallet-collateral`
- `missing-registry-reference`
- `missing-permissions-reference`
- `beneficiary-network-mismatch`
- `intent-network-mismatch`
- `missing-usdm-setup`
- `missing-usdm-treasury-value`
- `tx-build-failed`
- `stale-run-directory`

Failure JSON:

```json
{
  "phase": "disburse",
  "status": "failed",
  "code": "missing-usdm-setup",
  "message": "Local DevNet USDM setup is not available",
  "runDirectory": "runs/devnet/<timestamp>",
  "network": "devnet",
  "networkMagic": 42,
  "intentPath": null,
  "txBuildLogPath": null,
  "summaryPath": "runs/devnet/<timestamp>/disburse/summary.json"
}
```

## Boundary

This contract proves disburse intent and unsigned transaction build
evidence only. It must not write swap-order intent, swap-order funding,
swap execution, or reorganize evidence.
