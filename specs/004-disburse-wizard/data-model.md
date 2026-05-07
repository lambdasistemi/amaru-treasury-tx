# Phase 1 Data Model: Disburse Wizard

**Plan**: [plan.md](./plan.md) · **Spec**: [spec.md](./spec.md)
**Date**: 2026-05-06

This file fixes the Haskell types that cross module boundaries on the
disburse-wizard side. Internal helper signatures land with the
implementation PR; what's here is the contract between the CLI parser,
the resolver, the pure translation, the JSON schema, and the build
pipeline.

**Post-#52 update**: the public JSON contract is now the unified
`TreasuryIntent` shape from feature 005. Feature 004's pure wizard
translation produces `TreasuryIntent 'Disburse`; `tx-build` decodes
`SomeTreasuryIntent` and dispatches through
`Amaru.Treasury.TreasuryBuild.runFromIntent`.

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
    , deCurrentTip :: !Word64
    , deNetworkConstants :: !NetworkConstants
    -- ^ Reused from Amaru.Treasury.Tx.SwapWizard for the USDM
    --   policy/token rows; swap-only rows are simply unread on
    --   this code path.
    , deRegistry :: !RegistryView
    , deScopeView :: !ScopeView
    -- ^ Projection of `deRegistry` for the chosen scope.
    , deTreasurySelection :: !DisburseTreasurySelection
    , deWalletSelection :: !WalletSelection
    , deBeneficiaryAddrBech32 :: !Text
    -- ^ The bech32 string carried verbatim through to the
    --   JSON intent. Parsed and network-checked by the resolver
    --   before this record is built; the pure translation does
    --   not re-parse it.
    }

data DisburseTreasurySelection = DisburseTreasurySelection
    { dtsInputs :: ![Text]
    -- ^ "txid#ix"
    , dtsLeftoverLovelace :: !Integer
    -- ^ Σ lovelace on inputs − beneficiary lovelace
    --   (precomputed by the resolver; pure translation does
    --   not redo the arithmetic).
    , dtsLeftoverUsdm :: !Integer
    -- ^ Σ USDM on inputs − beneficiary USDM.
    --   For `--unit ada` the beneficiary takes 0 USDM, so this
    --   equals the total USDM on the selected treasury inputs
    --   (often zero in practice, but non-zero whenever a
    --   selected treasury UTxO happens to carry USDM).
    , dtsLeftoverOtherAssets :: !(Map Text (Map Text Integer))
    -- ^ All non-ADA / non-USDM assets present on inputs;
    --   forwarded verbatim onto the leftover output. Outer
    --   key: policy hex; inner key: asset-name hex.
    }
```

`WalletSelection` is re-exported unchanged from
[`Amaru.Treasury.Tx.SwapWizard`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/lib/Amaru/Treasury/Tx/SwapWizard.hs)
(`wsTxIn :: Text`, `wsAddress :: Text`).

Notes:

- `NetworkConstants`, `RegistryView`, `ScopeOwners`, `TreasuryRefs`,
  `ScopeView`, `WalletSelection` are imported and re-exported from
  the swap wizard; see research [§R7](./research.md#r7-networkconstants-reuse).
- The disburse-side `DisburseTreasurySelection` is a sibling of the
  swap-side `TreasurySelection`: disburse must preserve every asset
  present on the selected inputs (USDM and any other native assets)
  on the leftover output, so the leftover triple is materialised in
  the env. The resolver computes per-input values internally; only
  the precomputed leftover totals enter `DisburseEnv`.
- The bech32 strings (txin / addr / policy / asset name) are kept as
  `Text` until the build path lifts them to ledger types via
  `translateIntent SDisburse`. This matches the existing swap-wizard
  pattern.

## 3. The pure translation

```haskell
disburseToTreasuryIntent
    :: DisburseEnv
    -> DisburseAnswers
    -> Either DisburseError (TreasuryIntent 'Disburse)
```

Rules:

- **Total**: every successful path produces a
  `TreasuryIntent 'Disburse` that passes
  `decodeTreasuryIntent + translateIntent SDisburse` and validates
  against `docs/assets/intent-schema.json`.
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
`disburseToTreasuryIntent`:

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

## 4. TreasuryIntent 'Disburse — the JSON contract

The full JSON schema lives in
[`docs/assets/intent-schema.json`](../../docs/assets/intent-schema.json)
and is described for the disburse branch in
[`contracts/disburse-intent-json.md`](./contracts/disburse-intent-json.md).
Here is the corresponding Haskell record:

```haskell
module Amaru.Treasury.IntentJSON where

data TreasuryIntent (a :: Action) = TreasuryIntent
    { tiSAction :: !(SAction a)
    , tiSchema :: !Int
    , tiNetwork :: !Text
    , tiWallet :: !WalletJSON
    , tiScope :: !ScopeJSON
    , tiSigners :: ![Text]
    , tiValidityUpperBoundSlot :: !Word64
    , tiRationale :: !RationaleJSON
    , tiPayload :: !(Payload a)
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

data DisburseInputs = DisburseInputs
    { diUnit :: !Text                            -- "ada" | "usdm"
    , diAmount :: !Integer                       -- lovelace OR smallest USDM unit
    , diBeneficiaryAddress :: !Text              -- bech32
    , diUsdmPolicy :: !Text                      -- 28-byte hex (only used for "usdm")
    , diUsdmToken :: !Text                       -- hex (only used for "usdm")
    }

data RationaleJSON = RationaleJSON
    { rjEvent :: !Text                           -- defaults: "disburse"
    , rjLabel :: !Text                           -- "Disburse ADA" / "Disburse USDM"
    , rjDescription :: !Text
    , rjJustification :: !Text
    , rjDestinationLabel :: !Text
    }
```

The encoded JSON adds top-level `schema` and `action` fields, where
`action = "disburse"` selects `Payload 'Disburse = DisburseInputs`.
The `usdmPolicy` / `usdmToken` fields are present unconditionally in
the JSON shape so the contract stays flat; the build path ignores them
when `diUnit = "ada"`.

## 5. translateIntent SDisburse — the typed lift

```haskell
data TranslatedShared = TranslatedShared
    { tsNetwork :: !Text
    , tsWalletTxIn :: !TxIn
    , tsWalletAddr :: !Addr
    , tsRationale :: !Metadatum
    }

translateIntent
    :: SAction 'Disburse
    -> TreasuryIntent 'Disburse
    -> Either String (TranslatedShared, DisburseIntent)
```

The pure builder's
[`DisburseIntent`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/lib/Amaru/Treasury/Tx/Disburse.hs)
type is split per unit. The shared chain-state lives in
`DisburseIntentFields`; each unit carries its own payload record:

```haskell
data DisburseIntent
    = DisburseAdaIntent
        !DisburseIntentFields
        !DisburseAdaPayload
    -- USDM constructor lands in T038:
    -- | DisburseUsdmIntent
    --     !DisburseIntentFields
    --     !DisburseUsdmPayload
    deriving stock (Show, Eq)

data DisburseAdaPayload = DisburseAdaPayload
    { dapAmountLovelace :: !Coin
    , dapLeftoverLovelace :: !Coin
    }
    deriving stock (Show, Eq)
```

Per-unit pure builders take the field record and the payload
separately so a future build dispatcher can pattern-match on the
`DisburseIntent` ADT and call the matching builder:

```haskell
disburseAdaProgram
    :: DisburseIntentFields -> DisburseAdaPayload -> TxBuild q e ()
-- T038:
-- disburseUsdmProgram
--     :: DisburseIntentFields -> DisburseUsdmPayload -> TxBuild q e ()
```

## 6. TreasuryBuildResult / runDisburse

```haskell
module Amaru.Treasury.TreasuryBuild where

data TreasuryBuildResult = TreasuryBuildResult
    { tbrCborBytes :: !ByteString.Lazy
    , tbrFeeLovelace :: !Coin
    , tbrTotalCollateralLovelace :: !Coin
    , tbrScriptResults :: ![ScriptResult]
    -- ^ One entry per redeemer; mirrors SwapBuild.ScriptResult.
    }

runFromIntent
    :: ChainContext
    -> SomeTreasuryIntent
    -> IO TreasuryBuildResult

runDisburse
    :: ChainContext
    -> DisburseIntent
    -> Metadatum
    -> Addr
    -> IO TreasuryBuildResult
```

`ScriptResult`, `TreasuryBuildResult`, `runFromIntent`, and
`runDisburse` live in the unified dispatcher. The older
`Tx.DisburseBuild` module is compatibility scaffolding while the
branch is finalised.

## 7. Boundary tables

### 7.1 DisburseAnswers + DisburseEnv → TreasuryIntent 'Disburse

| `TreasuryIntent 'Disburse` field | Source |
|---|---|
| `schema` | fixed `1` |
| `action` | fixed `"disburse"` via `SDisburse` |
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

### 7.2 TreasuryIntent 'Disburse → TranslatedShared + DisburseIntent

| translated field | Source |
|---|---|
| `tsNetwork` | `tiNetwork` |
| `tsWalletTxIn` | `parseTxIn tiWallet.txIn` |
| `tsWalletAddr` | `parseAddr tiWallet.address` |
| `tsRationale` | `tiRationale` + `scope.registryPolicyId`, folded into CIP-1694 metadata |
| `DisburseAdaIntent` | when `tiPayload.unit = "ada"` |
| `DisburseUsdmIntent` | when `tiPayload.unit = "usdm"` (Phase 5) |

## 8. State transitions

The wizard has no persistent state. Conceptually it is a single
deterministic pass:

```
flags → DisburseAnswers ────┐
                            ├── disburseToTreasuryIntent
Provider IO + verifyRegistry├──── → TreasuryIntent 'Disburse
→ DisburseEnv ──────────────┘                              → write file
```

The build path is also stateless across invocations:

```
intent.json → decodeTreasuryIntent → translateIntent
            → runFromIntent / runDisburse
            → unsigned hex CBOR + summary.json
```

There are no retries, no resumable sessions, no in-progress files. A
failed wizard run leaves no partial JSON; a failed build run leaves
no partial CBOR.
