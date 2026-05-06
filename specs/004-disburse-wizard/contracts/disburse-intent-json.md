# Contract: `disburse intent.json`

**Plan**: [../plan.md](../plan.md) · **Spec**: [../spec.md](../spec.md)
**Date**: 2026-05-06

This file fixes the on-disk JSON contract that the wizard writes and
the build path reads. The Haskell record is in
[`data-model.md §4`](../data-model.md#4-disburseintentjson--the-json-contract).
Both shapes must stay aligned.

## 1. Shape

```jsonc
{
  "network": "mainnet",
  "wallet": {
    "txIn": "42e4c279…#0",
    "address": "addr1q802wxt6cg6aw0nl0vdzfxavu65rxu3yzhvgayw7chfxymduzkt66uw9t5kspx5jwjecx80dz4g33htknafhdhkvzd5st4f9xu"
  },
  "scope": {
    "id": "core_development",
    "treasuryAddress": "addr1z…",
    "treasuryUtxos": ["txid#ix", "txid#ix"],
    "treasuryLeftoverLovelace": 47000000,
    "treasuryLeftoverUsdm": 0,
    "treasuryLeftoverOtherAssets": {},
    "treasuryScriptHash": "f3ab64b0f97dcf0f91232754603283df5d75a1201337432c04d23e2e",
    "permissionsRewardAccount": "stake1u…",
    "scopesDeployedAt": "txid#ix",
    "permissionsDeployedAt": "txid#ix",
    "treasuryDeployedAt": "txid#ix",
    "registryDeployedAt": "txid#ix",
    "registryPolicyId": "fa3f2c7e2c8d4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a"
  },
  "disburse": {
    "unit": "ada",
    "amount": 50000000,
    "beneficiaryAddress": "addr1q9vendor…",
    "usdmPolicy": "fa3f2c7e2c8d4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a",
    "usdmToken": "55534444"
  },
  "signers": [
    "core_owner_keyhash_28b…",
    "ops_owner_keyhash_28b…"
  ],
  "validityUpperBoundSlot": 156789012,
  "rationale": {
    "event": "disburse",
    "label": "Disburse ADA",
    "description": "Q2 vendor invoice — translation services",
    "justification": "Per CIP-1694 budget allocation for the period",
    "destinationLabel": "ACME Translations Ltd."
  }
}
```

## 2. Field reference

### 2.1 `network`

String, one of `"mainnet"`, `"preprod"`, `"preview"`. Used by the
build path to choose ledger network parameters.

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
| `treasuryUtxos[]` | strings | inputs to spend; selection is wizard's responsibility |
| `treasuryLeftoverLovelace` | integer | lovelace on the leftover output |
| `treasuryLeftoverUsdm` | integer | USDM smallest-unit on the leftover output (0 for `unit=ada`) |
| `treasuryLeftoverOtherAssets` | nested object | `{policyHex: {assetNameHex: integer}}` for any non-ADA, non-USDM assets present on the inputs; forwarded verbatim onto the leftover |
| `treasuryScriptHash` | hex 28 bytes | scope's treasury validator hash |
| `permissionsRewardAccount` | bech32 stake | withdraw-zero target |
| `scopesDeployedAt` | `"txid#ix"` | scope-owners NFT reference UTxO |
| `permissionsDeployedAt` | `"txid#ix"` | deployed permissions script reference |
| `treasuryDeployedAt` | `"txid#ix"` | deployed treasury script reference |
| `registryDeployedAt` | `"txid#ix"` | registry NFT reference |
| `registryPolicyId` | hex 28 bytes | registry NFT policy id |

### 2.4 `disburse`

| Field | Type | Notes |
|---|---|---|
| `unit` | enum string | `"ada"` \| `"usdm"` |
| `amount` | integer | lovelace (for `ada`) or smallest USDM unit (for `usdm`) |
| `beneficiaryAddress` | bech32 `addr…` | payee output address |
| `usdmPolicy` | hex 28 bytes | always present in the JSON for stability; ignored when `unit = "ada"` |
| `usdmToken` | hex | always present; ignored when `unit = "ada"` |

### 2.5 `signers[]`

Array of 28-byte hex keyhashes. Order is significant: the scope
owner's keyhash is always first, followed by extra signers in the
order they were declared on the CLI. Duplicates are removed in the
wizard.

### 2.6 `validityUpperBoundSlot`

Absolute Cardano slot. The build path uses this as
`invalid_hereafter`.

### 2.7 `rationale`

| Field | Type | Default |
|---|---|---|
| `event` | string | `"disburse"` |
| `label` | string | `"Disburse ADA"` for `unit=ada`, `"Disburse USDM"` for `unit=usdm` |
| `description` | string | required |
| `justification` | string | required |
| `destinationLabel` | string | required |

These fields render into the on-chain
[`auxiliary_data`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/lib/treasury_instance_metadata.sh)
via the existing
[`Amaru.Treasury.AuxData`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/lib/Amaru/Treasury/AuxData.hs)
builder.

## 3. Round-trip guarantee

For any `DisburseAnswers` and any `DisburseEnv` that the resolver
produces, the following must hold:

```haskell
disburseToIntentJSON env answers
  >>= (decodeDisburseIntent . encodeDisburseIntent)
  >>= translateDisburseIntent
  ≡  Right (some TranslatedDisburseIntent)
```

Failure of this property is a P0 regression and breaks the wizard +
build pipeline contract.

## 4. Encoder shape

Encoded with `aeson-pretty`:

- Two-space indent.
- Fixed key order matching the field listing in §2 (top-level
  `network`, `wallet`, `scope`, `disburse`, `signers`,
  `validityUpperBoundSlot`, `rationale`; nested keys in record-source
  order).
- Trailing newline.

This is the same encoder strategy used for `SwapIntentJSON`.

## 5. Out of scope for v0

- A schema-validator (`json-schema`) representation. The contract is
  prose plus the Haskell record + the round-trip property.
- Versioning the schema (e.g. a top-level `"schema": 1` field). When
  v1 changes are required, this file is amended in lockstep with the
  Haskell record and the goldens are re-recorded.
