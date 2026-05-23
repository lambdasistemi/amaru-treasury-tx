# Data Model — Swap wizard pure intent producer

## Types introduced

### `FieldId`

A closed sum type naming every form field the operator may have supplied. Used in `Input*` failure variants so a UI can highlight the offending input.

```haskell
data FieldId
    = FieldScope
    | FieldWalletAddr
    | FieldUsdm
    | FieldAllAda
    | FieldSplit
    | FieldRate
    | FieldSlippageBps
    | FieldValidityHours
    | FieldDescription
    | FieldJustification
    | FieldDestinationLabel
    | FieldEvent
    | FieldLabel
    | FieldExtraSigner
    | FieldMetadataPath
    | FieldExcludeUtxo
    | FieldForceUtxo
    deriving (Eq, Show, Generic, ToJSON, FromJSON)
```

Stable identifiers — the JSON encoding is the constructor name without the `Field` prefix, lowercased with underscores. Adding a new field is a non-breaking superset; renaming or removing one is breaking.

### `WizardEvent`

Typed informational events the wizard emits during its run. Loaded into the existing CLI text tracer via `contramap renderWizardEvent`; passed transparently to HTTP request-scope capture.

```haskell
data WizardEvent
    = WeNetwork NetworkName Word32
    | WeMetadataPath FilePath
    | WeRegistryView ScopeId RegistryView
    | WeResolverEnv ResolverEnvSnapshot
    | WeChunksComputed Lovelace Lovelace Word32 Lovelace
    | WeUpperBoundResolved SlotNo
    | WeIntentReady (Maybe FilePath)
    | WeExclusionApplied [OutRef] [OutRef]
    deriving (Eq, Show)
```

(Mirrors today's `WizardEvent` if the existing CLI already has a typed event; otherwise consolidates today's free-text traces into the named events the spec calls out.)

### `WizardFailure`

The typed failure value `buildSwapIntent` returns in the `Left` branch.

```haskell
data WizardFailure
    = -- Input failures: operator-supplied data
      InputMalformed       FieldId Text
    | InputOutOfRange      FieldId Text
    | InputInputControlBad Text                    -- many fields at once
      -- Resolve failures: chain / registry / environment
    | ResolveNetworkUnknown        Text
    | ResolveMetadataMissing       FilePath
    | ResolveRegistryVerifyFailed  RegistryVerifyDetail
    | ResolveRegistryProjectFailed ScopeId Text
    | ResolveSwapParameters        Text
    | ResolveEnv                   ResolveEnvDetail
    | ResolveWalletShortfall       Lovelace Lovelace -- avail, required
    | ResolveValidityBound         Text
    | ResolveExclusionAbsent       [OutRef]
      -- Internal: invariant the wizard never expects
    | InternalTranslateError       Text
    | InternalEncodeError          Text
    deriving (Eq, Show, Generic, ToJSON, FromJSON)
```

Constructor count is provisional — the discovery task in tasks.md collapses duplicates and confirms the final list against the 21 `abortTr` sites.

`Eq` enables golden testing on failures. `Generic + ToJSON/FromJSON` is for the HTTP layer's serialisation (the follow-up vertical reuses the same encoding).

### `BuildEvent` and `BuildFailure`

Same shape rules as `WizardEvent` / `WizardFailure`. `BuildEvent` carries informational events from the `tx-build` step. `BuildFailure` includes:

```haskell
data BuildFailure
    = -- Input: intent payload incoherent
      BuildInputMalformed     FieldId Text
      -- Resolve: chain query / param fetch
    | BuildResolveParams      Text
    | BuildResolveTip         Text
    | BuildResolveUtxo        [OutRef] Text
      -- Build: TxBuild DSL refused
    | BuildMinUtxoViolation   Lovelace Lovelace -- have, need
    | BuildOverflowFees       Lovelace
    | BuildScriptRefMissing   ScriptHash
    | BuildRedeemerInvalid    Text
      -- Internal
    | BuildInternalError      Text
    deriving (Eq, Show, Generic, ToJSON, FromJSON)
```

### `ChainEnv`

A small record passed to `buildSwapTx` carrying live chain data the builder needs.

```haskell
data ChainEnv = ChainEnv
    { ceTipSlot     :: SlotNo
    , ceParams      :: PParams
    , ceEra         :: Era
    , ceSlotConfig  :: SlotConfig
    , ceBackend     :: Backend
    -- ^ for live UTxO + script-ref lookups during the build
    }
```

Existing `Backend` typeclass from `lib/Amaru/Treasury/Backend.hs` is reused.

## Type relationships

```text
buildSwapIntent
    :: GlobalOpts            -- existing CLI record (re-used)
    -> WizardOpts            -- existing CLI record (re-used)
    -> Backend               -- pre-opened handle; caller owns lifetime
    -> Tracer IO WizardEvent -- per-call, may be nullTracer
    -> IO (Either WizardFailure SwapIntent)

buildSwapTx
    :: ChainEnv              -- live chain context (carries Backend); caller owns lifetime
    -> SwapIntent            -- output of buildSwapIntent
    -> Tracer IO BuildEvent  -- per-call, may be nullTracer
    -> IO (Either BuildFailure (CborHex, Report))
```

Both functions are in `IO` because chain queries remain in IO. "Pure-ish" here means "no process exits on error".

The existing types `SwapIntent`, `Report`, `CborHex`, `SwapPayload`, `Backend`, `Lovelace`, `ScopeId`, `OutRef`, `RegistryView`, `ResolverEnvSnapshot`, `SlotNo`, `PParams`, `Era`, `SlotConfig`, `ScriptHash`, `NetworkName`, `RegistryVerifyDetail`, `ResolveEnvDetail` come from the existing modules under `lib/Amaru/Treasury/` and are not re-defined here.

## Module layout

```text
lib/Amaru/Treasury/Wizard/
├── Failure.hs              -- WizardFailure + BuildFailure + FieldId types
│                              + helpers: isInput, fieldOf, renderWizardFailure
├── Event.hs                -- WizardEvent + BuildEvent types
│                              + renderWizardEvent :: WizardEvent -> Text  (for the CLI text-tracer adapter)
└── Swap.hs                 -- buildSwapIntent + buildSwapTx
                               + ChainEnv record
                               + the IO sequence today owned by runWizard, minus the wrapper concerns
```

## Validation rules

- `FieldId` constructors MUST mirror form fields in the `swap-wizard` CLI flag list 1:1. Adding a CLI flag without a matching `FieldId` constructor is a regression.
- Every `Input*` variant MUST name exactly one `FieldId`.
- Every `Resolve*` variant MUST carry a structured detail record (no bare `Text` reasons).
- Every `Internal*` variant carries `Text` only — these mark invariants the wizard does not expect to hit; UI shows a "report a bug" prompt rather than a per-field hint.
- `WizardFailure` and `BuildFailure` `ToJSON`/`FromJSON` are derived via Generic + JSON options that tag constructors with `tag` (Aeson default `taggedObject`). The schema is the source of truth for the HTTP follow-up.
