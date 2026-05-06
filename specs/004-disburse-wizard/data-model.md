# Phase 1 Data Model: Disburse Wizard

**Plan**: [plan.md](./plan.md) · **Spec**: [spec.md](./spec.md)
**Date**: 2026-05-06

This file fixes the Haskell types that cross module boundaries on the
disburse-wizard side. Internal helper signatures land with the
implementation PR; what's here is the contract between the CLI parser,
the resolver, the pure translation, the JSON schema, and the build
pipeline.

## 1. DisburseAnswers — the typed answers

```haskell
module Amaru.Treasury.Tx.DisburseWizard where

-- The fields the operator decides.
data DisburseAnswers = DisburseAnswers
    { daScope :: !ScopeId
    -- ^ core_development | ops_and_use_cases |
    --   network_compliance | middleware | contingency
    , daUnit :: !Unit
    -- ^ ADA | USDM, reused from Amaru.Treasury.Constants
    , daAmount :: !Integer
    -- ^ For Unit=ADA: amount in lovelace.
    --   For Unit=USDM: amount in smallest USDM unit
    --   (USDM has 6 decimal places).
    , daBeneficiaryAddrBech32 :: !Text
    -- ^ Validated bech32 'addr…' string
    , daValidityHours :: !Word8
    -- ^ Validity window in hours, range [1, 48]
    , daRationale :: !RationaleAnswers
    , daExtraSigners :: ![Text]
    -- ^ Extra signer tokens. Each token is either a scope name
    --   (lowercased, e.g. "ops_and_use_cases") resolved through
    --   the registry owners, or a raw 28-byte hex keyhash.
    --   The selected scope's owner is inferred and always added.
    }

data RationaleAnswers = RationaleAnswers
    { raDescription :: !Text
    , raJustification :: !Text
    , raDestinationLabel :: !Text
    , raEvent :: !(Maybe Text)
    -- ^ defaults to "disburse"
    , raLabel :: !(Maybe Text)
    -- ^ defaults to "Disburse <unit>"
    }
```

Notes:

- `Unit` and the USDM policy/asset constants come from
  [`Amaru.Treasury.Constants`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/lib/Amaru/Treasury/Constants.hs).
- `RationaleAnswers` is structurally identical to the swap-wizard
  variant; the default `raLabel` is the only difference.
- `daBeneficiaryAddrBech32` is parsed once by the wizard and then
  carried as a typed `Addr` inside `DisburseEnv`; the raw string is
  preserved here only for the JSON layer.

## 2. DisburseEnv — the resolved environment

```haskell
data DisburseEnv = DisburseEnv
    { deNetwork :: !Text
    -- ^ "mainnet" | "preprod" | "preview"
    , deCurrentTip :: !SlotNo
    , deNetworkConstants :: !NetworkConstants
    -- ^ Reused from Amaru.Treasury.Tx.SwapWizard for the USDM
    --   policy/token rows; swap-only rows are simply unread on
    --   this code path.
    , deRegistry :: !RegistryView
    , deScopeView :: !ScopeView
    -- ^ Projection of `deRegistry` for the chosen scope.
    , deTreasurySelection :: !TreasurySelection
    , deWalletSelection :: !WalletSelection
    , deBeneficiaryAddr :: !Addr
    -- ^ The parsed-and-validated beneficiary address.
    }

data TreasurySelection = TreasurySelection
    { tsInputs :: ![TxIn]
    , tsInputValues :: ![MaryValue]
    -- ^ Per-input value, parallel to tsInputs. Used to compute
    --   the leftover output's full asset map.
    , tsLeftoverLovelace :: !Integer
    -- ^ Σ lovelace on inputs − beneficiary lovelace
    --   (precomputed by the resolver; pure translation does
    --   not redo the arithmetic).
    , tsLeftoverUsdm :: !Integer
    -- ^ Σ USDM on inputs − beneficiary USDM.
    --   For `--unit ada` the beneficiary takes 0 USDM, so this
    --   equals the total USDM on the selected treasury inputs
    --   (often zero in practice, but non-zero whenever a
    --   selected treasury UTxO happens to carry USDM).
    , tsLeftoverOtherAssets :: !MultiAsset
    -- ^ All non-ADA / non-USDM assets present on inputs;
    --   forwarded verbatim onto the leftover output.
    }

data WalletSelection = WalletSelection
    { wsTxIn :: !TxIn
    , wsAddress :: !Addr
    }
```

Notes:

- `NetworkConstants`, `RegistryView`, `ScopeOwners`, `TreasuryRefs`,
  `ScopeView` are imported from
  [`Amaru.Treasury.Tx.SwapWizard`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/lib/Amaru/Treasury/Tx/SwapWizard.hs);
  see research [§R7](./research.md#r7-networkconstants-reuse).
- `tsInputValues` is *new* relative to feature 002. The swap path only
  spends ADA, so the leftover is a single lovelace number; disburse
  must preserve every asset present on the inputs and so the resolver
  carries the full per-input value.
- `deBeneficiaryAddr` is the parsed `Addr`; the resolver rejects any
  bech32 whose network does not match `deNetwork`.

## 3. The pure translation

```haskell
disburseToIntentJSON
    :: DisburseEnv
    -> DisburseAnswers
    -> Either DisburseError DisburseIntentJSON
```

Rules:

- **Total**: every successful path produces a `DisburseIntentJSON`
  that passes `decodeDisburseIntent + translateDisburseIntent`.
- **No IO**: no chain queries, no protocol-parameter fetches, no
  current-time reads. Everything must be in `DisburseEnv`.
- **Errors are domain errors**: `DisburseError` enumerates the failure
  modes the translation can detect locally. Resolver-level failures
  (empty UTxO set, address parse failure, network mismatch) are caught
  earlier and never reach this function.

```haskell
data DisburseError
    = DisburseAmountNotPositive
    | DisburseValidityHoursOutOfRange Word8
    | DisburseSignerNotScopeOrHex28 Text
    | DisburseInsufficientTreasuryAda
    | DisburseInsufficientTreasuryUsdm
    | DisburseUsdmRequestedOnAdaOnlyScope
```

`ResolverError` is a sibling type owned by the IO resolver — it
covers failures the pure translation cannot detect because the raw
inputs (bech32 strings, on-chain UTxOs, registry anchors) never reach
`disburseToIntentJSON`:

```haskell
data ResolverError
    = ResolverEmptyWalletUtxos
    | ResolverEmptyTreasuryUtxos
    | ResolverRegistryWalkFailed Text
    | ResolverNetworkNotSupported Text
    | ResolverShortfall { rsRequired :: Integer, rsAvailable :: Integer }
    | ResolverWalletNetworkMismatch
    | ResolverBeneficiaryNetworkMismatch
    | ResolverBeneficiaryAddressUnparseable Text
```

The two error families are kept disjoint by design: `DisburseError`
enumerates only what the pure translation can witness from a typed
`(DisburseEnv, DisburseAnswers)` pair, while `ResolverError` covers
chain-state and bech32-parse failures.

## 4. DisburseIntentJSON — the JSON contract

The full JSON schema lives in
[`contracts/disburse-intent-json.md`](./contracts/disburse-intent-json.md).
Here is the corresponding Haskell record:

```haskell
module Amaru.Treasury.Tx.DisburseIntentJSON where

data DisburseIntentJSON = DisburseIntentJSON
    { dijNetwork :: !Text
    , dijWallet :: !WalletJSON
    , dijScope :: !ScopeJSON
    , dijDisburse :: !DisburseJSON
    , dijSigners :: !SignersJSON
    , dijValidityUpperBoundSlot :: !Integer
    , dijRationale :: !RationaleJSON
    }

data WalletJSON = WalletJSON
    { wjTxIn :: !Text         -- "txid#ix"
    , wjAddress :: !Text      -- bech32
    }

data ScopeJSON = ScopeJSON
    { sjId :: !Text                              -- "core_development" etc.
    , sjTreasuryAddress :: !Text                 -- bech32
    , sjTreasuryUtxos :: ![Text]                 -- ["txid#ix", ...]
    , sjTreasuryLeftoverLovelace :: !Integer
    , sjTreasuryLeftoverUsdm :: !Integer
    , sjTreasuryLeftoverOtherAssets :: !(Map Text (Map Text Integer))
    , sjTreasuryScriptHash :: !Text              -- 28-byte hex
    , sjPermissionsRewardAccount :: !Text        -- stake bech32
    , sjScopesDeployedAt :: !Text
    , sjPermissionsDeployedAt :: !Text
    , sjTreasuryDeployedAt :: !Text
    , sjRegistryDeployedAt :: !Text
    , sjRegistryPolicyId :: !Text
    }

data DisburseJSON = DisburseJSON
    { djUnit :: !Text                            -- "ada" | "usdm"
    , djAmount :: !Integer                       -- lovelace OR smallest USDM unit
    , djBeneficiaryAddress :: !Text              -- bech32
    , djUsdmPolicy :: !Text                      -- 28-byte hex (only used for "usdm")
    , djUsdmToken :: !Text                       -- hex (only used for "usdm")
    }

data SignersJSON = SignersJSON
    { sigList :: ![Text]                         -- 28-byte hex keyhashes,
                                                 -- scope owner first
    }

data RationaleJSON = RationaleJSON
    { rjEvent :: !Text                           -- defaults: "disburse"
    , rjLabel :: !Text                           -- "Disburse ADA" / "Disburse USDM"
    , rjDescription :: !Text
    , rjJustification :: !Text
    , rjDestinationLabel :: !Text
    }
```

The `usdmPolicy` / `usdmToken` fields are present unconditionally in
the JSON shape so the contract stays flat; the build path ignores them
when `djUnit = "ada"`.

## 5. TranslatedDisburseIntent — the typed lift

```haskell
data TranslatedDisburseIntent = TranslatedDisburseIntent
    { tdNetwork :: !Text
    , tdWalletTxIn :: !TxIn
    , tdWalletAddr :: !Addr
    , tdDisburseIntent :: !DisburseIntent
    -- ^ Reused from the pure builder
    --   Amaru.Treasury.Tx.Disburse, extended for USDM in this
    --   feature.
    , tdRationale :: !RationaleAnswers
    }

translateDisburseIntent
    :: DisburseIntentJSON
    -> Either String TranslatedDisburseIntent
```

The pure builder's
[`DisburseIntent`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/lib/Amaru/Treasury/Tx/Disburse.hs)
record is extended in this feature with two additional cases:

```haskell
data DisburseIntent
    = DisburseAdaIntent !DisburseIntentFields !Coin
    | DisburseUsdmIntent !DisburseIntentFields !Integer
    -- ^ Integer = USDM smallest-unit amount; the field record holds
    --   the shared seven references + two leftover quantities.
```

The exact split between `DisburseIntentFields` and the per-unit case
is fixed in the implementation PR; the contract here is that
`disburseAdaProgram` consumes the `Ada` constructor and a new
`disburseUsdmProgram` consumes the `Usdm` constructor.

## 6. DisburseBuildInputs / DisburseBuildResult

```haskell
module Amaru.Treasury.Tx.DisburseBuild where

data DisburseBuildInputs = DisburseBuildInputs
    { dbiIntent :: !DisburseIntent
    , dbiRationale :: !RationaleAnswers
    , dbiWalletTxIn :: !TxIn
    , dbiWalletAddr :: !Addr
    }

data DisburseBuildResult = DisburseBuildResult
    { dbrCborBytes :: !ByteString.Lazy
    , dbrFeeLovelace :: !Coin
    , dbrTotalCollateralLovelace :: !Coin
    , dbrScriptResults :: ![ScriptResult]
    -- ^ One entry per redeemer; mirrors SwapBuild.ScriptResult.
    }

runDisburseBuild
    :: ChainContext
    -> DisburseBuildInputs
    -> IO DisburseBuildResult
```

`ScriptResult` and `ChainContext` are imported from
[`Amaru.Treasury.Tx.SwapBuild`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/lib/Amaru/Treasury/Tx/SwapBuild.hs)
and
[`Amaru.Treasury.ChainContext`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/lib/Amaru/Treasury/ChainContext.hs)
respectively; this feature does not introduce new types for them.

## 7. Boundary tables

### 7.1 DisburseAnswers + DisburseEnv → DisburseIntentJSON

| `DisburseIntentJSON` field | Source |
|---|---|
| `network` | `deNetwork` |
| `wallet.txIn`, `wallet.address` | `deWalletSelection` |
| `scope.id` | `daScope` (rendered via `Scope.scopeText`) |
| `scope.treasuryAddress` | `deScopeView.svRefs.trAddress` |
| `scope.treasuryUtxos` | `deTreasurySelection.tsInputs` |
| `scope.treasuryLeftoverLovelace` | `deTreasurySelection.tsLeftoverLovelace` |
| `scope.treasuryLeftoverUsdm` | `deTreasurySelection.tsLeftoverUsdm` |
| `scope.treasuryLeftoverOtherAssets` | `deTreasurySelection.tsLeftoverOtherAssets` |
| `scope.treasuryScriptHash` | `deScopeView.svRefs.trScriptHash` |
| `scope.permissionsRewardAccount` | `deScopeView.svRefs.trPermissionsRewardAccount` |
| `scope.scopesDeployedAt` etc. | `deRegistry` |
| `scope.registryPolicyId` | `deRegistry.rvRegistryPolicyId` |
| `disburse.unit` | `daUnit` |
| `disburse.amount` | `daAmount` |
| `disburse.beneficiaryAddress` | `deBeneficiaryAddr` |
| `disburse.usdmPolicy` | `deNetworkConstants.ncUsdmPolicy` |
| `disburse.usdmToken` | `deNetworkConstants.ncUsdmToken` |
| `signers` | scope owner inferred from `daScope` ++ resolved `daExtraSigners`, de-duplicated in order |
| `validityUpperBoundSlot` | `deCurrentTip + ncSlotsPerHour × daValidityHours` |
| `rationale.*` | `daRationale` (with defaults applied) |

This table is the contract; the implementation PR may not deviate
without updating this file.

### 7.2 DisburseIntentJSON → TranslatedDisburseIntent

| `TranslatedDisburseIntent` field | Source |
|---|---|
| `tdNetwork` | `dijNetwork` |
| `tdWalletTxIn` | `parseTxIn dijWallet.txIn` |
| `tdWalletAddr` | `parseAddr dijWallet.address` |
| `tdRationale` | `dijRationale` (re-folded into `RationaleAnswers`) |
| `tdDisburseIntent` (`DisburseAdaIntent`) | when `dijDisburse.unit = "ada"` |
| `tdDisburseIntent` (`DisburseUsdmIntent`) | when `dijDisburse.unit = "usdm"` |

## 8. State transitions

The wizard has no persistent state. Conceptually it is a single
deterministic pass:

```
flags → DisburseAnswers ────┐
                            ├── disburseToIntentJSON
Provider IO + verifyRegistry├──── → DisburseIntentJSON
→ DisburseEnv ──────────────┘                              → write file
```

The build path is also stateless across invocations:

```
intent.json → decodeDisburseIntent → translateDisburseIntent
            → DisburseBuildInputs → runDisburseBuild
            → unsigned hex CBOR + summary.json
```

There are no retries, no resumable sessions, no in-progress files. A
failed wizard run leaves no partial JSON; a failed build run leaves
no partial CBOR.
