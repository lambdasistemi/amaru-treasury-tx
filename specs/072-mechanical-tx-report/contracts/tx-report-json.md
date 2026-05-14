# Contract: `tx-build` Transaction Report JSON

**Plan**: [../plan.md](../plan.md) | **Spec**: [../spec.md](../spec.md)
**Date**: 2026-05-09

The report is a deterministic JSON artifact written by
`amaru-treasury-tx tx-build --report PATH` after a successful build and
redeemer validation. It is generated mechanically from build data and is
intended for pre-signing review and downstream tooling.

## CLI surface

```text
amaru-treasury-tx
    tx-build
    [--intent PATH]      (defaults to stdin)
    [--out PATH]         (defaults to stdout)
    [--log PATH]         (defaults to stderr)
    [--report PATH]      (optional; no report is written when omitted)
```

Rules:

- `--report` never changes unsigned CBOR bytes.
- If `--report` is omitted, successful behavior stays as it is today.
- If `--report` is supplied and the report cannot be written, the
  command exits non-zero and prints a clear write failure.
- No report is written for parse, translation, build, or validation
  failures.

## Top-level shape

Field names are camelCase. Values are deterministic and contain no
timestamps or host-local paths.

```json
{
  "schema": 1,
  "action": "swap",
  "network": "mainnet",
  "identity": {
    "txId": "<64 hex chars>",
    "bodySizeBytes": 14987,
    "feeLovelace": 1041155,
    "totalCollateralLovelace": 1561733,
    "validityInterval": {
      "invalidBefore": null,
      "invalidHereafter": 186796799
    }
  },
  "walletAccounting": {
    "inputs": [],
    "collateralInput": {},
    "changeOutput": {},
    "collateralReturn": {},
    "feeLovelace": 1041155,
    "netSpendLovelace": 1041155
  },
  "treasuryAccounting": {
    "inputs": [],
    "inputTotal": {},
    "sundaeOrderTotal": {},
    "perChunkOverheadLovelace": 3280000,
    "treasuryLeftover": {},
    "netDebit": {}
  },
  "outputs": [],
  "signers": [],
  "validation": {
    "intentNetwork": "mainnet",
    "socketNetworkMagic": 764824073,
    "networkMatches": true,
    "feeLovelace": 1041155,
    "bodySizeBytes": 14987,
    "redeemerCount": 2,
    "redeemerFailures": 0,
    "validationStatus": "ok",
    "validityInterval": {
      "invalidBefore": null,
      "invalidHereafter": 186796799
    }
  },
  "referenceInputs": [],
  "metadata": {
    "auxiliaryDataHash": "<hash or null>",
    "cip1694LabelPresent": true
  }
}
```

## Value shape

Every value object uses the same shape:

```json
{
  "lovelace": 123,
  "assets": {
    "<policy id hex>": {
      "<asset name hex>": 456
    }
  }
}
```

Native assets with zero quantity are omitted. Empty asset maps are
encoded as `{}`.

## Output roles

Every produced output appears exactly once in `outputs`.

Allowed v1 roles:

- `swapOrder`
- `treasuryLeftover`
- `walletChange`
- `collateralReturn`
- `metadata`
- `unknown`

`unknown` is valid and required when the transaction has a produced
output that cannot be classified mechanically by the v1 code.

## Signer sources

Allowed v1 signer sources:

- `selectedScopeOwner`
- `extraSigner`
- `intentRequiredSigner`
- `txBodyRequiredSigner`

Each signer entry includes `keyHash` and `source`. Entries may include
`scope` when the source is the selected scope owner.

## Schema asset

The machine-readable contract will be committed at:

```text
docs/assets/tx-report-schema.json
```

The implementation must provide an executable drift/validation check
that keeps this asset aligned with the Haskell data model and validates
the swap golden report fixture.
