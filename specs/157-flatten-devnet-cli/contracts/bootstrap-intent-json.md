# Contract: `bootstrap-intent.json`

The seven new sub-action intents share the existing unified
`intent.json` envelope:

```json
{
  "action": "<flat-action-tag>",
  "schemaVersion": "1",
  "network": "devnet",
  "payload": { ... }
}
```

## Flat action tags

```text
registry-init-seed-split
registry-init-mint
registry-init-reference-scripts
stake-reward-init-script-account
stake-reward-init-plain-account
governance-withdrawal-init-proposal
governance-withdrawal-init-materialization
```

Every other `action` value (including the bare `"registry-init"`,
`"stake-reward-init"`, `"governance-withdrawal-init"`) is rejected
by the decoder.

## Network policy

`network` is `Text`. The **decoder** accepts any value
(consistent with the existing `swap` / `disburse` / `withdraw`
envelopes), so that inspection / fixture / wizard tooling can
still round-trip a `bootstrap-intent.json` regardless of its
network field.

The **dispatcher** (`Amaru.Treasury.Build.runBuildExcept` arms for
the seven init sub-actions, optionally via a shared
`requireDevnet :: Text -> ExceptT BuildError IO ()` helper)
rejects any value other than `"devnet"` with a typed
`BuildError` **before** any N2C connection or transaction
construction.

This split keeps the wire format reusable and the policy in one
place — when parent #156 specifies mainnet/preprod semantics for
an init action, the change is a dispatcher widening, not a JSON
edit.

## Per-sub-action `payload`

The `payload` object is the JSON projection of the
corresponding sub-action input record in `data-model.md`. Field
names use lowerCamelCase to match the existing `swap` / `disburse`
/ `withdraw` payloads.

### `registry-init-seed-split` payload

```json
{
  "fundingTxIn": "<hex>#<ix>",
  "fundingAddress": "addr_test1...",
  "seedCount": 3,
  "seedLovelace": 500000000
}
```

### `registry-init-mint` payload

```json
{
  "seedTxIns": ["<hex>#<ix>", "<hex>#<ix>", "<hex>#<ix>"],
  "ownerKeyHash": "<hex>",
  "scriptSet": { "scopes": "<hex>", "registry": "<hex>" }
}
```

### `registry-init-reference-scripts` payload

```json
{
  "registryDeployedAt": "<hex>#<ix>",
  "permissionsScript": "<base16>",
  "treasuryScript": "<base16>",
  "fundingTxIn": "<hex>#<ix>"
}
```

### `stake-reward-init-script-account` payload

```json
{
  "registryAnchor": "<hex>#<ix>",
  "permissionsRef": "<hex>#<ix>",
  "treasuryRef": "<hex>#<ix>",
  "scriptCredential": "<hex>",
  "fundingTxIn": "<hex>#<ix>",
  "fundingAddress": "addr_test1..."
}
```

### `stake-reward-init-plain-account` payload

```json
{
  "plainStakeKeyHash": "<hex>",
  "fundingTxIn": "<hex>#<ix>",
  "fundingAddress": "addr_test1..."
}
```

### `governance-withdrawal-init-proposal` payload

```json
{
  "treasuryAnchor": "<hex>#<ix>",
  "withdrawalAmount": 1000000000,
  "anchor": { "url": "https://...", "hash": "<hex>" },
  "fundingTxIn": "<hex>#<ix>",
  "fundingAddress": "addr_test1..."
}
```

### `governance-withdrawal-init-materialization` payload

```json
{
  "proposalTxIn": "<hex>#<ix>",
  "withdrawalScriptCredential": "<hex>",
  "fundingTxIn": "<hex>#<ix>",
  "fundingAddress": "addr_test1..."
}
```

*(Field names + types are illustrative; the implementing
subagent's brief freezes the exact mapping from each existing
`lib/Amaru/Treasury/Devnet/*Init.hs` input. The orchestrator
confirms the mapping at slice review.)*

## Round-trip invariant

```text
decodeTreasuryIntent . encodeSomeTreasuryIntent ≡ Right
```

per sub-action, covered by `IntentJSONSpec` and the schema check
in `IntentJSONSchemaSpec`.

## Schema asset

`docs/assets/intent-schema.json` MUST include all seven sub-action
variants. `just schema-check` MUST pass.

## CBOR equivalence (per sub-action)

For each sub-action, a golden test holds these byte-for-byte equal:

```text
runTxBuild(intentJson)
   ==
extractedConstructionCore(sameInputs)
```

where the construction core is the pure function extracted from
the corresponding sub-transaction inside the existing library
entry. The `submitX`/`withDevnet` code path stays on top of the
extracted core unchanged. Fixtures live under
`test/fixtures/intent/`.
