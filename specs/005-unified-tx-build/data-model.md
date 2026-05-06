# Phase 1 Data Model: Unified intent JSON + tx-build

**Plan**: [plan.md](./plan.md) · **Spec**: [spec.md](./spec.md)
**Date**: 2026-05-06

This file fixes the Haskell types that cross module boundaries on
the unified intent and the build dispatcher. Internal helper
signatures land with the implementation PR; what's here is the
contract between the wizard, the JSON layer, the typed lift, and
the build dispatcher.

## 1. Action discriminator

```haskell
module Amaru.Treasury.IntentJSON where

-- | The four treasury actions.
data Action
    = Swap
    | Disburse
    | Withdraw
    | Reorganize
    deriving stock (Eq, Show)
```

JSON: lower-cased identifier (`"swap"`, `"disburse"`, `"withdraw"`,
`"reorganize"`).

## 2. Top-level intent record

```haskell
data TreasuryIntent = TreasuryIntent
    { tiSchema :: !Int
    -- ^ schema version. v0 allow-list = [1].
    , tiAction :: !Action
    , tiNetwork :: !Text
    -- ^ "mainnet" | "preprod" | "preview"
    , tiWallet :: !WalletJSON
    , tiScope :: !ScopeJSON
    , tiSigners :: ![Text]
    -- ^ 28-byte hex keyhashes; scope owner first
    , tiValidityUpperBoundSlot :: !Word64
    , tiRationale :: !RationaleJSON
    , tiPayload :: !ActionPayload
    }
    deriving stock (Eq, Show)
```

The `tiAction` and `tiPayload` fields are kept separate so the
parser can validate the discriminator independently of the payload
(R1 of [research.md](./research.md)). The FromJSON instance enforces
that `tiAction = Swap` ↔ `tiPayload = SwapPayload …` (and similarly
for the other three) — see §6.

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

## 4. Action-specific payloads

```haskell
data ActionPayload
    = SwapPayload !SwapInputs
    | DisbursePayload !DisburseInputs
    | WithdrawPayload !WithdrawInputs
    | ReorganizePayload !ReorganizeInputs
    deriving stock (Eq, Show)

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

## 6. Parser invariant

```haskell
instance FromJSON TreasuryIntent where
    parseJSON = withObject "TreasuryIntent" $ \o -> do
        schema <- o .: "schema"
        when (schema `notElem` allowedSchemas)
            (fail $ "unknown intent schema: " <> show schema)
        action <- o .: "action"
        network <- o .: "network"
        wallet <- o .: "wallet"
        scope <- o .: "scope"
        signers <- o .: "signers"
        ub <- o .: "validityUpperBoundSlot"
        rat <- o .: "rationale"
        payload <- case action of
            Swap -> SwapPayload <$> o .: "swap"
            Disburse -> DisbursePayload <$> o .: "disburse"
            Withdraw -> WithdrawPayload <$> o .: "withdraw"
            Reorganize -> ReorganizePayload <$> o .: "reorganize"
        pure
            TreasuryIntent
                { tiSchema = schema
                , tiAction = action
                , tiNetwork = network
                , tiWallet = wallet
                , tiScope = scope
                , tiSigners = signers
                , tiValidityUpperBoundSlot = ub
                , tiRationale = rat
                , tiPayload = payload
                }

allowedSchemas :: [Int]
allowedSchemas = [1]
```

This enforces FR-007 (action ↔ payload key match) and FR-008
(schema allow-list). An intent with `action: "disburse"` but no
`disburse` block fails at the `o .: "disburse"` step with a clear
"key not found" error from `aeson`.

The corresponding `ToJSON` writes the discriminator and the payload
under matching keys, so round-trip is identity.

## 7. Translated form

```haskell
data TranslatedTreasuryIntent = TranslatedTreasuryIntent
    { ttNetwork :: !Text
    , ttWalletTxIn :: !TxIn
    , ttWalletAddr :: !Addr
    , ttRationale :: !Metadatum
    , ttPayload :: !TranslatedPayload
    }

data TranslatedPayload
    = TranslatedSwap !SwapIntent
    | TranslatedDisburseAda !DisburseIntentFields !DisburseAdaPayload
    | TranslatedDisburseUsdm !DisburseIntentFields !DisburseUsdmPayload
    -- TranslatedWithdraw / TranslatedReorganize land in #45/#46
```

The lift functions:

```haskell
translateTreasuryIntent
    :: TreasuryIntent
    -> Either String TranslatedTreasuryIntent
```

Internally this calls action-specific translators (`translateSwap`,
`translateDisburse`, …) that share the parser helpers in
`IntentJSON.Common`.

## 8. Build dispatcher

```haskell
module Amaru.Treasury.TreasuryBuild where

data TreasuryBuildInputs = TreasuryBuildInputs
    { tbiPayload :: !TranslatedPayload
    , tbiRationale :: !Metadatum
    , tbiWalletAddr :: !Addr
    }

data TreasuryBuildResult = TreasuryBuildResult
    { tbrCborBytes :: !ByteString.Lazy
    , tbrFeeLovelace :: !Coin
    , tbrTotalCollateralLovelace :: !Coin
    , tbrScriptResults :: ![ScriptResult]
    }

runTreasuryBuild
    :: ChainContext
    -> TreasuryBuildInputs
    -> IO TreasuryBuildResult
runTreasuryBuild ctx tbi = case tbiPayload tbi of
    TranslatedSwap si ->
        runSwap ctx tbi si
    TranslatedDisburseAda fields payload ->
        runDisburseAda ctx tbi fields payload
    TranslatedDisburseUsdm fields payload ->
        runDisburseUsdm ctx tbi fields payload
```

The `runSwap` / `runDisburseAda` / `runDisburseUsdm` helpers are
the existing per-action build pipelines, refactored to take
`TreasuryBuildInputs` instead of their own per-action input record.
The bodies are unchanged.

## 9. Boundary tables

### 9.1 Swap action: `(WizardEnv, SwapWizardQ)` → `TreasuryIntent`

For `tiAction = Swap`, all shared blocks come from `WizardEnv`'s
existing field set (mirrors today's swap wizard), and `tiPayload =
SwapPayload (mkSwap …)` per existing field-by-field translation in
[`Tx.SwapWizard.mkSwap`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/lib/Amaru/Treasury/Tx/SwapWizard.hs).

The swap wizard now writes `tiSchema = 1`, `tiAction = Swap`, and
`tiNetwork = weNetwork env` into the unified intent — three new
top-level fields. Everything else moves verbatim.

### 9.2 Disburse action: same shape as feature 004 §7.1

Per [feature 004 data-model §7.1](https://github.com/lambdasistemi/amaru-treasury-tx/blob/004-disburse-wizard/specs/004-disburse-wizard/data-model.md#71-disburseanswers--disburseenv--disburseintentjson),
with `tiPayload = DisbursePayload (mkDisburse …)` and the
disburse-specific fields (`tiAction = Disburse`, `tiNetwork`)
sourced from the env.

The disburse wizard's translator becomes:

```haskell
disburseToTreasuryIntent
    :: DisburseEnv
    -> DisburseAnswers
    -> Either DisburseError TreasuryIntent
```

## 10. State transitions

The intent JSON has no state — it's a single deterministic
artifact written by a wizard run.

The build dispatcher is also stateless across invocations:

```
intent.json
    -> decodeTreasuryIntent
    -> translateTreasuryIntent
    -> TreasuryBuildInputs
    -> runTreasuryBuild
    -> unsigned hex CBOR + summary.json
```

There are no retries, no resumable sessions, no in-progress files.
A failed build run leaves no partial CBOR.
