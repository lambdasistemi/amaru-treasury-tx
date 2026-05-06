# Contract: `treasury intent.json`

**Plan**: [../plan.md](../plan.md) · **Spec**: [../spec.md](../spec.md)
**Date**: 2026-05-06

This file fixes the on-disk JSON contract that every wizard
(swap, disburse, withdraw, reorganize) writes and that the
unified `tx-build` reads. Replaces feature 002's implicit
`SwapIntentJSON` shape and feature 004's
[contracts/disburse-intent-json.md](https://github.com/lambdasistemi/amaru-treasury-tx/blob/004-disburse-wizard/specs/004-disburse-wizard/contracts/disburse-intent-json.md).

The Haskell record is in [`data-model.md §2`](../data-model.md#2-top-level-intent-record).
Both shapes must stay aligned.

## 1. Shape (top-level)

```jsonc
{
    "schema": 1,
    "action": "swap",                          // OR "disburse" | "withdraw" | "reorganize"
    "network": "mainnet",                      // OR "preprod" | "preview"
    "wallet":   { … },                         // §2.2
    "scope":    { … },                         // §2.3
    "signers":  [ … ],                         // §2.4
    "validityUpperBoundSlot": 186468259,
    "rationale": { … },                        // §2.5

    // Exactly one of the following four blocks is present, named
    // by the value of "action":
    "swap":        { … }                       // §3 — only if action="swap"
    // "disburse":  { … }                      // §3 — only if action="disburse"
    // "withdraw":  { … }                      // §3 — only if action="withdraw"
    // "reorganize":{ … }                      // §3 — only if action="reorganize"
}
```

## 2. Shared blocks

### 2.1 `schema`

Integer, currently `1`. The build allow-list is `[1]`. An intent
with any other value is rejected at parse time with a typed error
naming the offending value.

### 2.2 `wallet`

| Field | Type | Notes |
|---|---|---|
| `txIn` | string `"txid#ix"` | wallet UTxO used as fuel + collateral |
| `address` | bech32 `addr…` | wallet address |

### 2.3 `scope`

| Field | Type | Notes |
|---|---|---|
| `id` | enum string | `core_development` \| `ops_and_use_cases` \| `network_compliance` \| `middleware` \| `contingency` |
| `treasuryAddress` | bech32 | treasury contract address for the scope |
| `treasuryUtxos[]` | strings | inputs the build will spend |
| `treasuryLeftoverLovelace` | integer | lovelace on the leftover output |
| `treasuryLeftoverUsdm` | integer | USDM smallest-unit on the leftover output (0 unless the action carries USDM) |
| `treasuryLeftoverOtherAssets` | nested object | `{policyHex: {assetNameHex: integer}}`; empty unless the action preserves non-ADA, non-USDM assets on the leftover (currently disburse only) |
| `treasuryScriptHash` | hex 28 bytes | scope's treasury validator hash |
| `permissionsRewardAccount` | hex 28 bytes | withdraw-zero target |
| `scopesDeployedAt` | `"txid#ix"` | scope-owners NFT reference UTxO |
| `permissionsDeployedAt` | `"txid#ix"` | deployed permissions script reference |
| `treasuryDeployedAt` | `"txid#ix"` | deployed treasury script reference |
| `registryDeployedAt` | `"txid#ix"` | registry NFT reference |
| `registryPolicyId` | hex 28 bytes | registry NFT policy id |

### 2.4 `signers[]`

Array of 28-byte hex keyhashes. Order is significant: the scope
owner's keyhash is always first, followed by extra signers in the
order they were declared on the wizard's CLI. Duplicates are
removed in the wizard.

### 2.5 `rationale`

| Field | Type | Default applied by wizard |
|---|---|---|
| `event` | string | `"disburse"` (always; same value across actions) |
| `label` | string | `"Swap ADA<->USDM"` for swap; `"Disburse ADA"` / `"Disburse USDM"` for disburse; per-action default for the other two |
| `description` | string | required (operator-supplied) |
| `justification` | string | required |
| `destinationLabel` | string | required |

These render into the on-chain auxiliary_data via the existing
[`Amaru.Treasury.AuxData`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/lib/Amaru/Treasury/AuxData.hs)
builder.

### 2.6 `network`

Lower-case string, exactly one of `"mainnet"`, `"preprod"`,
`"preview"`. The build derives the N2C handshake magic from this
field. The intent file is rejected at parse time if `network` is
absent or unrecognised.

### 2.7 `validityUpperBoundSlot`

Absolute Cardano slot. Set by the wizard from the current chain
tip + `--validity-hours × 3600`. The build uses this as
`invalid_hereafter`.

## 3. Action-specific blocks

The `action` discriminator selects exactly one of the four blocks
below. Mismatch (e.g. `action: "swap"` with a `disburse` block) is
a parse error.

### 3.1 `swap` (when `action = "swap"`)

```jsonc
"swap": {
    "swapOrderAddress": "addr1x…",
    "chunkSizeLovelace": 12500000000,
    "amountLovelace": 408163265306,
    "extraPerChunkLovelace": 3280000,
    "rateNumerator": 245,
    "rateDenominator": 1000,
    "poolId": "64f35d…",
    "coreOwner": "7095fa…",
    "opsOwner": "f3ab64…",
    "networkComplianceOwner": "8bd032…",
    "middlewareOwner": "97e0f6…",
    "sundaeProtocolFeeLovelace": 1280000,
    "usdmPolicy": "c48cbb…",
    "usdmToken": "0014df105553444d"
}
```

Identical fields to today's
[`Tx.SwapIntentJSON.SwapInputs`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/lib/Amaru/Treasury/Tx/SwapIntentJSON.hs).

### 3.2 `disburse` (when `action = "disburse"`)

```jsonc
"disburse": {
    "unit": "ada",                    // OR "usdm"
    "amount": 50000000,
    "beneficiaryAddress": "addr1q…",
    "usdmPolicy": "c48cbb…",
    "usdmToken": "0014df105553444d"
}
```

Mirrors feature 004's
[`DisburseInputsJSON`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/004-disburse-wizard/lib/Amaru/Treasury/Tx/DisburseIntentJSON.hs).

### 3.3 `withdraw` (when `action = "withdraw"`)

Placeholder until [#45](https://github.com/lambdasistemi/amaru-treasury-tx/issues/45)
ships. Parsing an intent with `action: "withdraw"` against a build
binary that predates #45 fails with `"action 'withdraw' not yet
supported by this binary"`.

### 3.4 `reorganize` (when `action = "reorganize"`)

Placeholder until [#46](https://github.com/lambdasistemi/amaru-treasury-tx/issues/46)
ships. Parsing an intent with `action: "reorganize"` against a
build binary that predates #46 fails with `"action 'reorganize' not
yet supported by this binary"`.

## 4. Round-trip guarantee

For any `(WizardEnv, WizardAnswers)` that any wizard's resolver
produces, the following must hold:

```haskell
wizardToTreasuryIntent env answers
  >>= (decodeTreasuryIntent . encodeTreasuryIntent)
  >>= translateTreasuryIntent
  ≡  Right (some TranslatedTreasuryIntent)
```

Failure of this property is a P0 regression and breaks the wizard
+ build pipeline contract.

## 5. Encoder shape

Encoded with `aeson-pretty`:

- 4-space indent.
- Alphabetical key ordering (matching the existing
  `encodeIntentJSON` for swap and `encodeDisburseIntent` for
  disburse).
- Trailing newline.

## 6. Out of scope for v0

- A schema-validator (`json-schema`) representation. The contract
  is prose plus the Haskell record + the round-trip property.
- Backwards compatibility with feature 002's pre-unification swap
  intent. Old swap intents (no `network`, no `schema`, no
  `action`) fail at parse time; operators re-run the wizard.

## 7. Breaking changes vs feature 002 / feature 004 contracts

- **Top-level `schema` field added** (was missing).
- **Top-level `action` field added** (was missing).
- **Top-level `network` field added** (was missing in swap intent;
  was already present in disburse intent at the same path —
  `dijNetwork` becomes `tiNetwork`).
- **Action-specific block named after `action`** (was the only
  top-level non-shared block in each action's intent, but un-keyed
  by action — e.g. swap had a `swap` key already; disburse had a
  `disburse` key already; withdraw and reorganize get new keys).
- Field-by-field shape inside each action's block is **unchanged**
  (so the CBOR bodies of the existing swap golden + the in-flight
  ada-disburse golden don't change).
