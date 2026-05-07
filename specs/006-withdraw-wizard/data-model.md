# Phase 1 Data Model: Withdraw Wizard

**Plan**: [plan.md](./plan.md) · **Spec**: [spec.md](./spec.md)
**Date**: 2026-05-07

This document fixes the cross-module contract for the withdraw action.
Implementation details can choose helper names, but the public JSON and
module boundaries should follow this shape.

## 1. Unified intent payload

`WithdrawInputs` replaces the empty placeholder in
`Amaru.Treasury.IntentJSON`:

```haskell
data WithdrawInputs = WithdrawInputs
    { wiTreasuryRewardAccount :: !Text
    -- ^ 28-byte treasury stake script hash, hex-encoded.
    , wiRewardsLovelace :: !Integer
    -- ^ Positive reward amount to withdraw and pay back to treasury.
    }
```

JSON block:

```json
{
  "withdraw": {
    "treasuryRewardAccount": "32201dc1...",
    "rewardsLovelace": 12500000000
  }
}
```

Validation:

- `treasuryRewardAccount` is exactly 28 bytes of hex.
- `rewardsLovelace` is a positive integer.
- The parser rejects zero; the wizard handles zero rewards by not
  emitting an intent.

## 2. Full intent shape

```jsonc
{
  "schema": 1,
  "action": "withdraw",
  "network": "preprod",
  "wallet": {
    "txIn": "<fuel txid>#0",
    "address": "addr_test1..."
  },
  "scope": {
    "id": "core_development",
    "treasuryAddress": "addr_test1...",
    "treasuryUtxos": [],
    "treasuryLeftoverLovelace": 0,
    "treasuryLeftoverUsdm": 0,
    "treasuryLeftoverOtherAssets": {},
    "treasuryScriptHash": "<28-byte hex>",
    "permissionsRewardAccount": "<28-byte hex>",
    "scopesDeployedAt": "<txid>#0",
    "permissionsDeployedAt": "<txid>#0",
    "treasuryDeployedAt": "<txid>#0",
    "registryDeployedAt": "<txid>#0",
    "registryPolicyId": "<28-byte hex>"
  },
  "signers": [],
  "validityUpperBoundSlot": 186796799,
  "rationale": {
    "event": "withdraw",
    "label": "Withdraw treasury rewards",
    "description": "Withdraw accumulated rewards for core_development",
    "destinationLabel": "core_development treasury",
    "justification": "Move rewards back under treasury contract control"
  },
  "withdraw": {
    "treasuryRewardAccount": "<28-byte hex>",
    "rewardsLovelace": 12500000000
  }
}
```

Notes:

- `scope.treasuryUtxos` is empty because withdraw does not spend a
  treasury script UTxO.
- `scope.treasuryLeftover*` values are zero/empty because there is no
  treasury-input leftover. The output paid by the withdraw transaction
  is represented by `withdraw.rewardsLovelace`.
- `signers` is empty unless future oracle evidence proves a required
  signer hash belongs in the body.

## 3. Wizard answers

```haskell
data WithdrawAnswers = WithdrawAnswers
    { waScope :: !ScopeId
    , waValidityHours :: !Word8
    , waDescription :: !(Maybe Text)
    , waJustification :: !(Maybe Text)
    , waDestinationLabel :: !(Maybe Text)
    , waEvent :: !(Maybe Text)
    , waLabel :: !(Maybe Text)
    }
```

The CLI also carries operational flags outside the pure answers:

- `--wallet-addr ADDR`
- `--metadata PATH`
- `--out PATH`
- `--log PATH`

Defaults:

- `event`: `withdraw`
- `label`: `Withdraw treasury rewards`
- `description`: `Withdraw accumulated rewards for <scope>`
- `destinationLabel`: `<scope> treasury`
- `justification`: `Move rewards back under treasury contract control`

## 4. Wizard environment

```haskell
data WithdrawEnv = WithdrawEnv
    { weNetwork :: !Text
    , weCurrentTip :: !SlotNo
    , weWallet :: !WalletSelection
    , weScope :: !ScopeView
    , weTreasuryRewardAccount :: !Text
    , weRewardsLovelace :: !Integer
    }
```

`ScopeView` is the verified registry projection shared with existing
wizards. `WalletSelection` is the same "fuel/collateral UTxO plus
wallet address" concept used by swap/disburse.

## 5. Pure translation

```haskell
withdrawToTreasuryIntent
    :: WithdrawEnv
    -> WithdrawAnswers
    -> Either WithdrawError (TreasuryIntent 'Withdraw)
```

Validation:

- `weRewardsLovelace > 0`.
- `waValidityHours` is in the project-wide accepted range.
- Scope in answers matches the resolved scope view.
- Reward account and treasury address belong to the selected network.

Mapping:

- `tiSchema = 1`.
- `tiSAction = SWithdraw`.
- `tiNetwork = weNetwork`.
- `tiWallet = weWallet`.
- `tiScope` is populated from the verified scope view; treasury UTxO
  and leftover fields are empty/zero.
- `tiSigners = []`.
- `tiValidityUpperBoundSlot = weCurrentTip + validityHours`.
- `tiRationale` is built from answer overrides/defaults.
- `tiPayload = WithdrawInputs weTreasuryRewardAccount weRewardsLovelace`.

## 6. Translation to ledger intent

`translateIntent SWithdraw` maps the unified JSON to the existing
ledger-level `WithdrawIntent`:

```haskell
Translated 'Withdraw = WithdrawIntent
```

Field mapping:

| `WithdrawIntent` field | Source |
|---|---|
| `wiWalletUtxo` | `wallet.txIn` |
| `wiTreasuryRewardAccount` | `withdraw.treasuryRewardAccount` plus intent network |
| `wiTreasuryAddress` | `scope.treasuryAddress` |
| `wiTreasuryDeployedAt` | `scope.treasuryDeployedAt` |
| `wiRegistryDeployedAt` | `scope.registryDeployedAt` |
| `wiRewardsAmount` | `withdraw.rewardsLovelace` |
| `wiUpperBound` | `validityUpperBoundSlot` |

The shared translation result keeps:

- `tsWalletTxIn = wallet.txIn`
- `tsWalletAddr = wallet.address`
- `tsRationale = rationale`

## 7. Build result

`TreasuryBuild.runWithdraw` mirrors `runSwap` and `runDisburse`:

```haskell
runWithdraw
    :: ChainContext
    -> WithdrawIntent
    -> Metadatum
    -> Addr
    -> IO TreasuryBuildResult
```

Required context:

- wallet fuel/collateral UTxO
- treasury deployed-script reference
- registry reference
- protocol parameters
- evaluator results for the withdrawal redeemer

The body must contain:

- one wallet input
- wallet collateral
- two reference inputs: treasury and registry
- one withdrawal from the treasury reward account
- one output to the treasury contract address for `rewardsLovelace`
- validity upper bound
- rationale metadata label 1694

## 8. Fixture model

`test/fixtures/withdraw/synthetic/` contains:

- `intent.json`
- `utxos.json`
- `pparams.json`
- `exunits.json`
- `expected.cbor`
- `provenance.md`

`test/fixtures/withdraw/zero-rewards/` contains resolver fixtures for
the no-op wizard behavior and must not contain `intent.json`.
