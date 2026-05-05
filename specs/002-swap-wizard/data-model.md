# Phase 1 Data Model: Swap Wizard

**Plan**: [plan.md](./plan.md) · **Spec**: [spec.md](./spec.md)
**Date**: 2026-05-05

This file fixes the Haskell types that cross module boundaries inside
`Amaru.Treasury.Tx.SwapWizard`. Internal helper signatures land with
the implementation PR; what's here is the *contract* between the
prompt loop, the resolver, the pure translation, and the existing
`SwapIntentJSON`.

## 1. SwapWizardQ — the typed answers

```haskell
module Amaru.Treasury.Tx.SwapWizard where

-- Real intent — the fields the human decides.
data SwapWizardQ = SwapWizardQ
    { wqScope :: !ScopeId
    -- ^ Core / Ops / NetworkCompliance / Middleware
    , wqAmountLovelace :: !Integer
    -- ^ total ADA to swap, in lovelace
    , wqChunkSizeLovelace :: !Integer
    -- ^ size of each swap-order chunk (lovelace)
    , wqRateNumerator :: !Integer
    -- ^ minimum acceptable USDM-per-ADA, numerator
    , wqRateDenominator :: !Integer
    -- ^ minimum acceptable USDM-per-ADA, denominator
    , wqValidityHours :: !Word8
    -- ^ validity window from now, hours (range 1..48)
    , wqRationale :: !RationaleAnswers
    , wqSignersOverride :: !(Maybe [Hex28])
    -- ^ Nothing = use the scope's default owners; Just = explicit
    --   list of 28-byte hex key hashes
    }

data RationaleAnswers = RationaleAnswers
    { raDescription :: !Text
    , raJustification :: !Text
    , raDestinationLabel :: !Text
    , raEvent :: !(Maybe Text)
    -- ^ defaults to "disburse"
    , raLabel :: !(Maybe Text)
    -- ^ defaults to "Swap ADA<->USDM"
    }
```

Notes:
- `Hex28` is a thin newtype around `Text` validated as
  28-byte-hex. Defined in this module; not exported beyond the
  wizard.
- `ScopeId` is reused from `Amaru.Treasury.Scope`.
- `RationaleAnswers` mirrors the existing
  `Amaru.Treasury.Tx.SwapIntentJSON.RationaleInputs`.

## 2. WizardEnv — the resolved environment

```haskell
data WizardEnv = WizardEnv
    { weNetwork :: !Network
    -- ^ Mainnet / Testnet
    , weCurrentTip :: !SlotNo
    , weNetworkConstants :: !NetworkConstants
    , weRegistry :: !RegistryView
    , weScopeView :: !ScopeView
    -- ^ Projection of `weRegistry` for the chosen scope
    , weTreasurySelection :: !TreasurySelection
    , weWalletSelection :: !WalletSelection
    }

data NetworkConstants = NetworkConstants
    { ncSwapOrderAddress :: !Addr
    , ncUsdmPolicy :: !Hex
    , ncUsdmToken :: !Hex
    , ncSundaeProtocolFeeLovelace :: !Integer
    , ncExtraPerChunkLovelace :: !Integer
    , ncSlotsPerHour :: !Word64
    , ncDefaultPoolId :: !Hex28
    }

data RegistryView = RegistryView
    { rvScopesDeployedAt :: !TxIn
    , rvPermissionsDeployedAt :: !TxIn
    , rvTreasuryDeployedAt :: !TxIn
    , rvRegistryDeployedAt :: !TxIn
    , rvRegistryPolicyId :: !Hex28
    , rvOwners :: !ScopeOwners
    , rvTreasuryByScope :: !(Map ScopeId TreasuryRefs)
    }

data ScopeOwners = ScopeOwners
    { soCore :: !Hex28
    , soOps :: !Hex28
    , soNetworkCompliance :: !Hex28
    , soMiddleware :: !Hex28
    }

data TreasuryRefs = TreasuryRefs
    { trAddress :: !Addr
    , trScriptHash :: !Hex28
    , trPermissionsRewardAccount :: !AccountAddress
    }

data ScopeView = ScopeView
    { svScope :: !ScopeId
    , svRefs :: !TreasuryRefs
    , svDefaultSigners :: ![Hex28]
    }

data TreasurySelection = TreasurySelection
    { tsInputs :: ![TxIn]
    , tsLeftoverLovelace :: !Integer
    -- ^ Σ inputs − wqAmountLovelace
    }

data WalletSelection = WalletSelection
    { wsTxIn :: !TxIn
    , wsAddress :: !Addr
    }
```

Notes:
- `Hex` and `Hex28` are validated newtypes around `Text` (28 bytes
  for hashes, arbitrary length for asset names).
- `weRegistry` carries the *raw* projection; `weScopeView` is the
  picked-by-scope view that the translation actually consumes. Both
  are kept so the verbose log can show the operator everything that
  was resolved.
- `tsLeftoverLovelace` is precomputed in the resolver. The pure
  translation does not redo the arithmetic.

## 3. The pure translation

```haskell
wizardToIntentJSON
    :: WizardEnv
    -> SwapWizardQ
    -> Either WizardError SwapIntentJSON
```

Rules:

- **Total**: every successful path produces a `SwapIntentJSON` that
  passes `decodeSwapIntent + translateIntent`.
- **No IO**: no chain queries, no protocol-parameter fetches, no
  current-time reads. Everything must be in `WizardEnv`.
- **Errors are domain errors**: `WizardError` enumerates the failure
  modes the translation can detect locally (e.g. signer hex not 28
  bytes, validity hours out of range). Resolver-level failures
  (empty UTxO set, unknown network) are caught earlier and never
  reach this function.

```haskell
data WizardError
    = WizardChunkSizeNotPositive
    | WizardChunkSizeExceedsAmount
    | WizardValidityHoursOutOfRange Word8
    | WizardSignerNotHex28 Text
    | WizardRateDenominatorZero
```

## 4. Boundary with `SwapIntentJSON`

The output type is `Amaru.Treasury.Tx.SwapIntentJSON.SwapIntentJSON`
unchanged. Field-by-field mapping:

| `SwapIntentJSON` field | Source |
|---|---|
| `wallet.txIn`, `wallet.address` | `weWalletSelection` |
| `scope.treasuryAddress` | `weScopeView.svRefs.trAddress` |
| `scope.treasuryUtxos` | `weTreasurySelection.tsInputs` |
| `scope.treasuryLeftoverLovelace` | `weTreasurySelection.tsLeftoverLovelace` |
| `scope.treasuryScriptHash` | `weScopeView.svRefs.trScriptHash` |
| `scope.permissionsRewardAccount` | `weScopeView.svRefs.trPermissionsRewardAccount` |
| `scope.scopesDeployedAt` etc. | `weRegistry` |
| `scope.registryPolicyId` | `weRegistry.rvRegistryPolicyId` |
| `swap.swapOrderAddress` | `weNetworkConstants.ncSwapOrderAddress` |
| `swap.chunkSizeLovelace` | `wqChunkSizeLovelace` |
| `swap.amountLovelace` | `wqAmountLovelace` |
| `swap.extraPerChunkLovelace` | `weNetworkConstants.ncExtraPerChunkLovelace` |
| `swap.rateNumerator` / `rateDenominator` | `wqRateNumerator` / `wqRateDenominator` |
| `swap.poolId` | `weNetworkConstants.ncDefaultPoolId` |
| `swap.{core,ops,networkCompliance,middleware}Owner` | `weRegistry.rvOwners` |
| `swap.sundaeProtocolFeeLovelace` | `weNetworkConstants.ncSundaeProtocolFeeLovelace` |
| `swap.usdmPolicy`, `swap.usdmToken` | `weNetworkConstants` |
| `signers` | `wqSignersOverride` ?: `weScopeView.svDefaultSigners` |
| `validityUpperBoundSlot` | `weCurrentTip + ncSlotsPerHour * wqValidityHours` |
| `rationale.*` | `wqRationale` (with defaults applied) |

This table is the contract; the implementation PR may not deviate
without updating this file.

## 5. State transitions

The wizard has no persistent state. Conceptually it is a single
deterministic pass:

```
prompts → SwapWizardQ ────┐
                          ├── wizardToIntentJSON → SwapIntentJSON → write file
Provider IO → WizardEnv ──┘
```

There are no retries, no resumable sessions, no in-progress files.
A failed run leaves no partial JSON.
