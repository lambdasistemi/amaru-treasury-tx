# Phase 1 Data Model: Unified intent JSON + tx-build

**Plan**: [plan.md](./plan.md) · **Spec**: [spec.md](./spec.md)
**Date**: 2026-05-06

This file fixes the Haskell types that cross module boundaries on
the unified intent and the build dispatcher. Internal helper
signatures land with the implementation PR; what's here is the
contract between the wizard, the JSON layer, the typed lift, and
the build dispatcher.

## 1. Action enum + singleton

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

module Amaru.Treasury.IntentJSON where

-- | The four treasury actions. Promoted to the type level via
-- @-XDataKinds@ so it can index 'TreasuryIntent'.
data Action = Swap | Disburse | Withdraw | Reorganize
    deriving stock (Eq, Show)

-- | Runtime singleton witnessing the type-level action.
-- Pattern-matching brings the index into scope and selects the
-- right type-family rows downstream.
data SAction (a :: Action) where
    SSwap :: SAction 'Swap
    SDisburse :: SAction 'Disburse
    SWithdraw :: SAction 'Withdraw
    SReorganize :: SAction 'Reorganize

deriving stock instance Show (SAction a)
deriving stock instance Eq (SAction a)
```

JSON discriminator: lower-cased identifier (`"swap"`,
`"disburse"`, `"withdraw"`, `"reorganize"`). The parser maps the
string to the matching `SAction` constructor.

## 2. Top-level intent (GADT indexed by Action)

```haskell
-- | Per-action input payload — the JSON block under the
-- discriminator-keyed object. See §4 for the per-action records.
type family Payload (a :: Action) :: Type where
    Payload 'Swap = SwapInputs
    Payload 'Disburse = DisburseInputs
    Payload 'Withdraw = WithdrawInputs
    Payload 'Reorganize = ReorganizeInputs

-- | Per-action translated form — the typed lift consumed by the
-- build path. See §7.
type family Translated (a :: Action) :: Type where
    Translated 'Swap = SwapIntent
    Translated 'Disburse = DisburseIntent
    Translated 'Withdraw = WithdrawIntent
    Translated 'Reorganize = ReorganizeIntent

-- | The parsed intent. 'a' is the type-level action; 'tiSAction'
-- is its runtime witness; 'tiPayload' projects to the matching
-- per-action record via the 'Payload' family.
data TreasuryIntent (a :: Action) = TreasuryIntent
    { tiSAction :: !(SAction a)
    , tiSchema :: !Int
    -- ^ schema version. v0 allow-list = [1].
    , tiNetwork :: !Text
    -- ^ "mainnet" | "preprod" | "preview"
    , tiWallet :: !WalletJSON
    , tiScope :: !ScopeJSON
    , tiSigners :: ![Text]
    -- ^ 28-byte hex keyhashes; scope owner first
    , tiValidityUpperBoundSlot :: !Word64
    , tiRationale :: !RationaleJSON
    , tiPayload :: !(Payload a)
    }

-- | Existential wrapper at the parser boundary. The parser
-- returns 'SomeTreasuryIntent' so it has one return type
-- regardless of which discriminator it read; consumers
-- unwrap and pattern-match on the 'SAction' once at entry.
data SomeTreasuryIntent where
    SomeTreasuryIntent
        :: !(SAction a)
        -> !(TreasuryIntent a)
        -> SomeTreasuryIntent
```

The action ↔ payload pairing is now a **compile-time** invariant:
a value of type `TreasuryIntent 'Swap` cannot carry a disburse
payload — the GADT erases that bug class. See research §R1 for the
trade-off discussion.

## 3. Shared structural blocks

```haskell
data WalletJSON = WalletJSON
    { wjTxIn :: !Text
    -- ^ "<txid hex>#<ix>"
    , wjAddress :: !Text
    -- ^ bech32 addr1...
    }

data ScopeJSON = ScopeJSON
    { sjId :: !Text
    -- ^ canonical scope name
    , sjTreasuryAddress :: !Text
    , sjTreasuryUtxos :: ![Text]
    , sjTreasuryLeftoverLovelace :: !Integer
    , sjTreasuryLeftoverUsdm :: !Integer
    -- ^ 0 unless the action carries USDM (disburse usdm,
    --     reorganize usdm, withdraw); zero on swap.
    , sjTreasuryLeftoverOtherAssets
        :: !(Map Text (Map Text Integer))
    -- ^ outer key: policy hex; inner key: asset-name hex.
    --     `mempty` unless the action preserves non-ADA, non-USDM
    --     assets on the leftover (currently disburse only).
    , sjTreasuryScriptHash :: !Text
    , sjPermissionsRewardAccount :: !Text
    , sjScopesDeployedAt :: !Text
    , sjPermissionsDeployedAt :: !Text
    , sjTreasuryDeployedAt :: !Text
    , sjRegistryDeployedAt :: !Text
    , sjRegistryPolicyId :: !Text
    }

data RationaleJSON = RationaleJSON
    { rjEvent :: !Text
    , rjLabel :: !Text
    , rjDescription :: !Text
    , rjJustification :: !Text
    , rjDestinationLabel :: !Text
    }
```

Note: `sjTreasuryLeftoverUsdm` and `sjTreasuryLeftoverOtherAssets`
are present **for every action** even though swap and (current)
withdraw do not populate them. They default to `0` and `mempty`
respectively in the wizard. Keeping the shape uniform is what
makes a single tagged-union viable; per-action gating of these
fields would force the parser to peek at `tiAction` before reading
the scope block.

## 4. Action-specific payload records

The per-action records are addressed by the `Payload` type family
in §2; downstream helpers parameterised by `a` get the right
record at each call site without duplicating the per-action code.

```haskell
-- | Swap-action payload. Identical fields to today's
-- 'Tx.SwapIntentJSON.SwapInputs'.
data SwapInputs = SwapInputs
    { siSwapOrderAddress :: !Text
    , siChunkSizeLovelace :: !Integer
    , siAmountLovelace :: !Integer
    , siExtraPerChunkLovelace :: !Integer
    , siRateNumerator :: !Integer
    , siRateDenominator :: !Integer
    , siPoolId :: !Text
    , siCoreOwner :: !Text
    , siOpsOwner :: !Text
    , siNetworkComplianceOwner :: !Text
    , siMiddlewareOwner :: !Text
    , siSundaeProtocolFeeLovelace :: !Integer
    , siUsdmPolicy :: !Text
    , siUsdmToken :: !Text
    }

-- | Disburse-action payload. Mirrors feature 004's
-- 'Tx.DisburseIntentJSON.DisburseInputsJSON'.
data DisburseInputs = DisburseInputs
    { diUnit :: !Text
    -- ^ "ada" | "usdm"
    , diAmount :: !Integer
    , diBeneficiaryAddress :: !Text
    , diUsdmPolicy :: !Text
    , diUsdmToken :: !Text
    }

-- | Withdraw-action payload (placeholder until #45 ships).
data WithdrawInputs = WithdrawInputs
    { wiPlaceholder :: !()
    }

-- | Reorganize-action payload (placeholder until #46 ships).
data ReorganizeInputs = ReorganizeInputs
    { riPlaceholder :: !()
    }
```

The withdraw and reorganize payload types are placeholders so the
ADT is closed (no `Maybe` per-field gymnastics) and so the parser
can produce a clear "feature not yet shipped" error if an intent
declares `action: "withdraw"` before #45 lands.

## 5. JSON shape

```jsonc
{
    "schema": 1,
    "action": "disburse",
    "network": "mainnet",
    "wallet": {
        "txIn": "abc…#0",
        "address": "addr1q…"
    },
    "scope": {
        "id": "core_development",
        "treasuryAddress": "addr1x…",
        "treasuryUtxos": ["64f…#0"],
        "treasuryLeftoverLovelace": 1449950000000,
        "treasuryLeftoverUsdm": 0,
        "treasuryLeftoverOtherAssets": {},
        "treasuryScriptHash": "32201d…",
        "permissionsRewardAccount": "a64d1b…",
        "scopesDeployedAt": "11ace…#0",
        "permissionsDeployedAt": "810bf…#0",
        "treasuryDeployedAt": "25ba9…#2",
        "registryDeployedAt": "e7b39…#2",
        "registryPolicyId": "38c62…"
    },
    "signers": ["7095…", "f3ab…"],
    "validityUpperBoundSlot": 186468259,
    "rationale": {
        "event": "disburse",
        "label": "Disburse ADA",
        "description": "...",
        "justification": "...",
        "destinationLabel": "..."
    },
    "disburse": {
        "unit": "ada",
        "amount": 50000000,
        "beneficiaryAddress": "addr1q…",
        "usdmPolicy": "c48cb…",
        "usdmToken": "0014df105553444d"
    }
}
```

The same shape with `"action": "swap"` substitutes a `"swap": {…}`
block instead of `"disburse": {…}` — the rest of the document is
identical.

## 6. Parser shape

```haskell
instance FromJSON SomeTreasuryIntent where
    parseJSON = withObject "TreasuryIntent" $ \o -> do
        schema <- o .: "schema"
        when (schema `notElem` allowedSchemas)
            (fail $ "unknown intent schema: " <> show schema)
        action <- o .: "action"
        let parseShared = do
                network <- o .: "network"
                wallet <- o .: "wallet"
                scope <- o .: "scope"
                signers <- o .: "signers"
                ub <- o .: "validityUpperBoundSlot"
                rat <- o .: "rationale"
                pure (network, wallet, scope, signers, ub, rat)
        case action of
            Swap -> do
                (n, w, s, sig, ub, r) <- parseShared
                payload <- o .: "swap"
                pure $ SomeTreasuryIntent SSwap $
                    TreasuryIntent SSwap schema n w s sig ub r payload
            Disburse -> do
                (n, w, s, sig, ub, r) <- parseShared
                payload <- o .: "disburse"
                pure $ SomeTreasuryIntent SDisburse $
                    TreasuryIntent SDisburse schema n w s sig ub r payload
            Withdraw -> do
                (n, w, s, sig, ub, r) <- parseShared
                payload <- o .: "withdraw"
                pure $ SomeTreasuryIntent SWithdraw $
                    TreasuryIntent SWithdraw schema n w s sig ub r payload
            Reorganize -> do
                (n, w, s, sig, ub, r) <- parseShared
                payload <- o .: "reorganize"
                pure $ SomeTreasuryIntent SReorganize $
                    TreasuryIntent SReorganize schema n w s sig ub r payload

allowedSchemas :: [Int]
allowedSchemas = [1]

-- | Parse the JSON discriminator into the value-level 'Action'.
instance FromJSON Action where
    parseJSON = withText "Action" $ \t -> case T.toLower t of
        "swap" -> pure Swap
        "disburse" -> pure Disburse
        "withdraw" -> pure Withdraw
        "reorganize" -> pure Reorganize
        other -> fail ("unknown action: " <> T.unpack other)
```

This enforces FR-007 (action ↔ payload key match — the GADT means
each branch parses the matching payload type) and FR-008 (schema
allow-list). An intent with `action: "disburse"` but no
`disburse` block fails at the `o .: "disburse"` step with a clear
"key not found" error from `aeson`.

The corresponding `ToJSON` instance writes via `toJSONIntent ::
SAction a -> TreasuryIntent a -> Value` (a regular function, since
`ToJSON` for an existential needs an external dispatcher). Round-
trip is identity:

```haskell
encodeSomeTreasuryIntent :: SomeTreasuryIntent -> ByteString
encodeSomeTreasuryIntent (SomeTreasuryIntent sa intent) =
    encodePretty (toJSONIntent sa intent)
```

## 7. Translated form

The translated intent is also indexed by the action; the
`Translated a` family from §2 names the per-action ledger-typed
record. The shared boundary fields (network, wallet TxIn + Addr,
rationale Metadatum) are kept in a separate `TranslatedShared`
record so the per-action `Translated a` only carries the action-
specific shape.

```haskell
data TranslatedShared = TranslatedShared
    { tsNetwork :: !Text
    , tsWalletTxIn :: !TxIn
    , tsWalletAddr :: !Addr
    , tsRationale :: !Metadatum
    }

-- The 'Translated' family from §2:
--   Translated 'Swap       = SwapIntent
--   Translated 'Disburse   = DisburseIntent
--   Translated 'Withdraw   = WithdrawIntent
--   Translated 'Reorganize = ReorganizeIntent

-- Action-polymorphic translator. Returns 'Translated a' under
-- the right type-family equation per branch.
translateIntent
    :: SAction a
    -> TreasuryIntent a
    -> Either String (TranslatedShared, Translated a)

-- Convenience for callers that have a 'SomeTreasuryIntent' in
-- hand (the parser's output shape).
translateSome
    :: SomeTreasuryIntent
    -> Either String (TranslatedShared, SomeTranslated)

data SomeTranslated where
    SomeTranslated
        :: !(SAction a)
        -> !(Translated a)
        -> SomeTranslated
```

Internally `translateIntent` dispatches once on the singleton and
calls the matching action-specific translator. Each translator is
its own function (`translateSwap`, `translateDisburse`, etc.) so
they can be tested independently; the dispatcher is a 4-line case.

The disburse branch is *itself* a sum at the typed-intent level
(`DisburseIntent = DisburseAdaIntent … | DisburseUsdmIntent …`)
because the on-chain shape differs between ADA and USDM disburses.
That sum stays inside `Tx.Disburse` and doesn't surface in the
unified type-family.

## 8. Build dispatcher

```haskell
module Amaru.Treasury.Build where

-- | Action-polymorphic build entry. The type-family makes 'a'
-- pick the right translated record at each call site.
runBuild
    :: ChainContext
    -> TranslatedShared
    -> SAction a
    -> Translated a
    -> IO BuildResult
runBuild ctx shared sa translated = case sa of
    SSwap        -> runSwap ctx shared translated
    SDisburse    -> runDisburse ctx shared translated
    SWithdraw    -> runWithdraw ctx shared translated
    SReorganize  -> runReorganize ctx shared translated

-- | Caller-friendly wrapper for the parser's existential.
runFromIntent
    :: ChainContext
    -> SomeTreasuryIntent
    -> IO BuildResult
runFromIntent ctx (SomeTreasuryIntent sa intent) = do
    (shared, translated) <- case translateIntent sa intent of
        Right v -> pure v
        Left e -> throwIO (userError ("translate: " <> e))
    runBuild ctx shared sa translated

-- The per-action runners. Each is its own function, refactored
-- from the existing per-action build pipelines (Tx.SwapBuild's
-- runSwapBuild, the in-flight runDisburseBuild). Bodies are
-- unchanged; only the input/output records are unified.
runSwap
    :: ChainContext
    -> TranslatedShared
    -> Translated 'Swap
    -> IO BuildResult

runDisburse
    :: ChainContext
    -> TranslatedShared
    -> Translated 'Disburse
    -> IO BuildResult
-- Internally: case translated of
--   DisburseAdaIntent  fields payload -> runDisburseAda  ctx shared fields payload
--   DisburseUsdmIntent fields payload -> runDisburseUsdm ctx shared fields payload

-- Withdraw and reorganize: stub bodies that throw 'feature not
-- shipped' until #45 / #46 land.
runWithdraw   :: ChainContext -> TranslatedShared -> Translated 'Withdraw   -> IO BuildResult
runReorganize :: ChainContext -> TranslatedShared -> Translated 'Reorganize -> IO BuildResult

data BuildResult = BuildResult
    { brCborBytes :: !ByteString.Lazy
    , brFeeLovelace :: !Coin
    , brTotalCollateralLovelace :: !Coin
    , brScriptResults :: ![ScriptResult]
    }
```

The dispatcher's case on `SAction a` is the only place a runtime
selection appears; once inside a branch the type family pins down
the per-action `Translated a` and the runner is fully type-safe.
Adding a fifth action means adding the row to the type families,
the constructor to `Action`/`SAction`, the runner, and the parser
case — helpers parameterised by `a` (e.g. summary writers, trace
projection) need no changes.

## 9. Boundary tables

### 9.1 Swap action: `(WizardEnv, SwapWizardQ)` → `TreasuryIntent 'Swap`

For the swap wizard, all shared blocks come from `WizardEnv`'s
existing field set (mirrors today's swap wizard), and `tiPayload`
is the result of `mkSwap` per existing field-by-field translation
in [`Tx.SwapWizard.mkSwap`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/lib/Amaru/Treasury/Tx/SwapWizard.hs).

The swap wizard now writes `tiSchema = 1`, `tiSAction = SSwap`,
and `tiNetwork = weNetwork env` into the unified intent — three
new top-level fields. Everything else moves verbatim. The wizard's
return type becomes:

```haskell
wizardToTreasuryIntent
    :: WizardEnv
    -> SwapWizardQ
    -> Either WizardError (TreasuryIntent 'Swap)
```

### 9.2 Disburse action: same shape as feature 004 §7.1

Per [feature 004 data-model §7.1](https://github.com/lambdasistemi/amaru-treasury-tx/blob/004-disburse-wizard/specs/004-disburse-wizard/data-model.md#71-disburseanswers--disburseenv--disburseintentjson),
with `tiPayload` populated by `mkDisburse` and the
disburse-specific fields (`tiSAction = SDisburse`, `tiNetwork`)
sourced from the env.

The disburse wizard's translator becomes:

```haskell
disburseToTreasuryIntent
    :: DisburseEnv
    -> DisburseAnswers
    -> Either DisburseError (TreasuryIntent 'Disburse)
```

### 9.3 Wrapping into `SomeTreasuryIntent`

Each wizard's CLI runner wraps its typed intent into the
existential before encoding to JSON:

```haskell
runWizardCli env answers = do
    intent <- ... :: TreasuryIntent 'Swap
    let some = SomeTreasuryIntent SSwap intent
    BSL.putStr (encodeSomeTreasuryIntent some)
```

`tx-build` parses to `SomeTreasuryIntent`, hands the existential to
`runFromIntent`, which dispatches once on the singleton and runs
the action-specific build pipeline.

## 10. State transitions

The intent JSON has no state — it's a single deterministic
artifact written by a wizard run.

The build dispatcher is also stateless across invocations:

```
intent.json
    -> decode :: ByteString -> Either String SomeTreasuryIntent
    -> SomeTreasuryIntent SAction (TreasuryIntent a)
    -> translateIntent  ::  Either String (TranslatedShared, Translated a)
    -> runBuild ctx shared sa translated
    -> unsigned hex CBOR + summary.json
```

There are no retries, no resumable sessions, no in-progress files.
A failed build run leaves no partial CBOR.

## 11. JSON Schema projection

The machine-readable contract is:

```haskell
intentJsonSchema :: Aeson.Value
encodeIntentJsonSchema :: ByteString
```

from `Amaru.Treasury.IntentJSON.Schema`.

The projection is deliberately manual rather than generically derived:
`TreasuryIntent` is a GADT and the on-disk shape is a tagged union
whose branch is selected by the top-level `action` value. The schema
therefore uses a top-level `oneOf`, one branch per `SAction`, with
each branch requiring the matching action-specific payload block and
forbidding the other top-level action blocks.

`docs/assets/intent-schema.json` is generated by
`amaru-treasury-intent-schema`. Tests validate the swap build
fixture, the swap-wizard golden fixture, and fresh
`wizardToTreasuryIntent` output against the generated schema.

## 12. Why this shape pays off downstream

Concrete code-sharing wins from the GADT + type-family design,
versus the plain-sum design that was the earlier draft:

- **Single trace event type.** `data BuildEvent = … | BuildEventBuilt … |
  BuildEventReevaluated … | BuildEventAborted …` is uniform — events that carry
  per-action data (e.g. `BuildEventIntentParsed (Some SAction)
  Network`) carry the singleton, but the trace module isn't
  duplicated per action. With a plain sum, helpers that project
  `ActionPayload` to a trace would have one branch per action.
- **Single summary writer.** `summaryOf :: SAction a -> Translated
  a -> BuildResult -> Summary` has one body that uses
  type-class methods (`SummaryFor a`) to project per-action
  details. Plain sum needs a separate body per action.
- **Single validator.** `validateIntent :: SAction a ->
  TreasuryIntent a -> Either String ()` runs cross-action checks
  (signers shape, validity bound positivity, leftover
  non-negativity) once with a uniform body, while delegating
  action-specific checks (e.g. swap chunk-size invariants) via a
  type-class.
- **Adding a 5th action** = `Action` enum + `SAction` constructor
  + `Payload` row + `Translated` row + per-action runner + parser
  case. Helpers parameterised by `a` need no edits.

These wins compound across features 005 and 006 (withdraw and
reorganize). The plain-sum design would re-pay this cost twice.
