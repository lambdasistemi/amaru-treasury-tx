# Contract — `docs/assets/intent-schema.json` delta

The published JSON schema regenerates on `cabal run -v0 -O0
exe:amaru-treasury-intent-schema > docs/assets/intent-schema.json`,
and `just schema-check` enforces that the committed file matches.

This file documents the *expected* delta after S1, so the reviewer
can verify the regenerated schema matches the intent.

## Before (current main / this branch up to S1)

```json
"reorganize": {
  "type": "object",
  "additionalProperties": false,
  "properties": {}
}
```

(The empty object reflects the placeholder
`data ReorganizeInputs = ReorganizeInputs` shape.)

## After S1

```json
"reorganize": {
  "type": "object",
  "additionalProperties": false,
  "required": [
    "walletUtxo",
    "treasuryUtxos",
    "treasuryAddress",
    "treasuryDeployedAt",
    "registryDeployedAt",
    "permissionsRewardAccount",
    "permissionsDeployedAt",
    "scopeOwnerSigner",
    "upperBound"
  ],
  "properties": {
    "walletUtxo":                 { "$ref": "#/definitions/TxIn" },
    "treasuryUtxos": {
      "type": "array",
      "minItems": 1,
      "items": { "$ref": "#/definitions/TxIn" }
    },
    "treasuryAddress":            { "$ref": "#/definitions/Addr" },
    "treasuryDeployedAt":         { "$ref": "#/definitions/TxIn" },
    "registryDeployedAt":         { "$ref": "#/definitions/TxIn" },
    "permissionsRewardAccount":   { "$ref": "#/definitions/RewardAccount" },
    "permissionsDeployedAt":      { "$ref": "#/definitions/TxIn" },
    "scopeOwnerSigner":           { "$ref": "#/definitions/KeyHashGuard" },
    "upperBound":                 { "type": "integer", "minimum": 0 }
  }
}
```

Field-name decisions match `data-model.md` §1 / §7.

## What the regen pulls

`exe:amaru-treasury-intent-schema`'s generator builds the schema
from `ToJSON` instances (or hand-written schema descriptors,
depending on the project's pattern — slice executor surveys
`app/amaru-treasury-intent-schema/Main.hs` first). The actual
JSON keys come from the `FromJSON` / `ToJSON` instances on
`ReorganizeInputs`; if a field is renamed in the Haskell record,
the schema follows.

## Verification

The S1 slice executor verifies:

1. After replacing `ReorganizeInputs` with the real record and
   writing the JSON instances, run:
   ```
   cabal run -v0 -O0 exe:amaru-treasury-intent-schema > docs/assets/intent-schema.json
   ```
2. `just schema-check` returns 0 with no diff output.
3. The reviewer's diff hunk for `docs/assets/intent-schema.json`
   matches this contract's "After S1" section.

## Other schema definitions referenced

- `#/definitions/TxIn` — already present in the schema; reused.
- `#/definitions/Addr` — already present; reused.
- `#/definitions/RewardAccount` — already present (used by
  `WithdrawInputs.treasuryRewardAccount`); reused.
- `#/definitions/KeyHashGuard` — already present (used by
  `DisburseInputs.signers`); reused.

No new shared `definitions` entry is added by this slice.
