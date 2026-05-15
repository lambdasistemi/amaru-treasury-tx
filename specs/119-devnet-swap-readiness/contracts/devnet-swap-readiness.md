# Contract: DevNet Swap Readiness

## Command

```bash
just devnet-smoke swap-ready
```

Equivalent direct script form:

```bash
scripts/smoke/devnet-local --phase swap-ready --run-dir runs/devnet/<timestamp>
```

The phase is opt-in and not part of `just ci`.

## Success Artifacts

```text
runs/devnet/<timestamp>/
|-- node.log
|-- summary.json
|-- summary.log
|-- timing.json
`-- swap-ready/
    |-- registry.json
    |-- summary.json
    `-- provenance.json
```

`swap-ready/registry.json`:

```json
{
  "schemaVersion": 1,
  "phase": "swap-ready",
  "status": "passed",
  "network": "devnet",
  "networkMagic": 42,
  "orderValidator": {
    "sourceRepository": "https://github.com/SundaeSwap-finance/sundae-contracts",
    "sourceCommit": "be33466b7dbe0f8e6c0e0f46ff23737897f45835",
    "validatorTitle": "order.spend",
    "scriptHash": "<28-byte-hex>",
    "fixtureOnly": false
  },
  "orderReference": {
    "referenceTxIn": "<txid>#<ix>",
    "address": "addr_test1...",
    "scriptHash": "<28-byte-hex>"
  },
  "orderBuildInputs": {
    "swapOrderAddress": "addr_test1...",
    "orderScriptRef": "<txid>#<ix>"
  }
}
```

`swap-ready/summary.json` repeats the fields needed for release notes:
run directory, network magic, order validator source, order address,
script hash, reference-script UTxO, and registry path.

## Failure Artifacts

On expected failure, write:

```text
runs/devnet/<timestamp>/swap-ready/failure.json
runs/devnet/<timestamp>/swap-ready/summary.json
runs/devnet/<timestamp>/summary.json
```

Failure JSON:

```json
{
  "phase": "swap-ready",
  "status": "failed",
  "code": "missing-sundae-order-validator",
  "message": "SundaeSwap V3 order validator artifact is missing",
  "runDirectory": "runs/devnet/<timestamp>",
  "network": "devnet",
  "networkMagic": 42,
  "registryPath": "runs/devnet/<timestamp>/swap-ready/registry.json",
  "summaryPath": "runs/devnet/<timestamp>/swap-ready/summary.json"
}
```

Required diagnostic codes:

- `missing-sundae-order-validator`
- `sundae-order-validator-hash-mismatch`
- `reference-script-publish-failed`
- `reference-script-utxo-missing`
- `reference-script-hash-mismatch`
- `fixture-only-not-compatibility-evidence`
- `network-mismatch`
- `stale-run-directory`

## Boundary

This contract proves readiness only. It must not write a swap intent,
swap transaction body, swap report, submitted order tx id, or order-spend
evidence.
