{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

{- |
Module      : Amaru.Treasury.IntentJSON
Description : Unified TreasuryIntent JSON contract — types
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

The unified intent JSON is a tagged union over the four
treasury actions. This phase-2 cut introduces the
type-level scaffolding: the action enum, its singleton,
and the type families that project per-action types.

The 'TreasuryIntent' GADT, 'SomeTreasuryIntent'
existential, FromJSON / ToJSON instances,
encoder / decoder, and 'translateIntent' land in
T005–T020 (later patches).
-}
module Amaru.Treasury.IntentJSON
    ( -- * Action discriminator
      Action (..)
    , SAction (..)
    , actionToText

      -- * Type families projecting per-action types
    , Payload
    , Translated

      -- * Shared structural blocks
    , WalletJSON (..)
    , ScopeJSON (..)
    , RationaleJSON (..)

      -- * Per-action input records
    , SwapInputs (..)
    , DisburseInputs (..)
    , WithdrawInputs (..)
    , ReorganizeInputs (..)

      -- * Top-level intent
    , TreasuryIntent (..)
    , SomeTreasuryIntent (..)

      -- * Schema
    , allowedSchemas

      -- * Encoding / decoding
    , decodeTreasuryIntent
    , decodeTreasuryIntentFile
    , encodeSomeTreasuryIntent

      -- * Translation
    , TranslatedShared (..)
    , translateIntent
    ) where

import Control.Monad (unless)
import Data.Aeson
    ( FromJSON (..)
    , ToJSON (..)
    , Value
    , eitherDecode
    , eitherDecodeFileStrict
    , object
    , withObject
    , withText
    , (.:)
    , (.=)
    )
import Data.Aeson.Encode.Pretty
    ( Config (..)
    , Indent (..)
    , NumberFormat (..)
    , encodePretty'
    )
import Data.ByteString.Lazy (ByteString)
import Data.Kind (Type)
import Data.Map.Strict (Map)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word64)

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Metadata (Metadatum)
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Slotting.Slot (SlotNo (..))

import Amaru.Treasury.AuxData
    ( RationaleBody (..)
    , rationaleMetadatum
    )
import Amaru.Treasury.IntentJSON.Common
    ( decodeHexBytes
    , decodeHexBytesAny
    , parseAddr
    , parseGuardKeyHash
    , parseRewardAccount
    , parseTxIn
    )
import Amaru.Treasury.Tx.Disburse
    ( DisburseAdaPayload (..)
    , DisburseIntent (..)
    , DisburseIntentFields (..)
    )
import Amaru.Treasury.Tx.Reorganize (ReorganizeIntent)
import Amaru.Treasury.Tx.Swap
    ( SwapIntent (..)
    , SwapOrderDatumParams (..)
    , SwapOrderOut (..)
    , swapOrderDatum
    )
import Amaru.Treasury.Tx.Withdraw (WithdrawIntent)

-- ----------------------------------------------------
-- Action enum + singleton
-- ----------------------------------------------------

{- | The four treasury actions. Promoted to the type
level via @-XDataKinds@ so it can index 'TreasuryIntent'
in T007.
-}
data Action = Swap | Disburse | Withdraw | Reorganize
    deriving stock (Eq, Show)

{- | Runtime singleton witnessing the type-level action.
Pattern-matching brings the index into scope and selects
the right type-family rows downstream.
-}
data SAction (a :: Action) where
    SSwap :: SAction 'Swap
    SDisburse :: SAction 'Disburse
    SWithdraw :: SAction 'Withdraw
    SReorganize :: SAction 'Reorganize

deriving stock instance Show (SAction a)

deriving stock instance Eq (SAction a)

-- ----------------------------------------------------
-- Type families
-- ----------------------------------------------------

{- | Per-action input payload — the JSON block under the
discriminator-keyed object. Each row names one of the
per-action input records defined below.
-}
type family Payload (a :: Action) :: Type where
    Payload 'Swap = SwapInputs
    Payload 'Disburse = DisburseInputs
    Payload 'Withdraw = WithdrawInputs
    Payload 'Reorganize = ReorganizeInputs

{- | Per-action translated form — the typed lift consumed
by the build path. Names the existing per-action typed
intent records.
-}
type family Translated (a :: Action) :: Type where
    Translated 'Swap = SwapIntent
    Translated 'Disburse = DisburseIntent
    Translated 'Withdraw = WithdrawIntent
    Translated 'Reorganize = ReorganizeIntent

-- ----------------------------------------------------
-- Shared structural blocks
-- ----------------------------------------------------

-- | Wallet block: the fuel + collateral input.
data WalletJSON = WalletJSON
    { wjTxIn :: !Text
    -- ^ @\<txid hex\>#\<ix\>@
    , wjAddress :: !Text
    -- ^ bech32 @addr1…@
    }
    deriving stock (Eq, Show)

instance FromJSON WalletJSON where
    parseJSON = withObject "WalletJSON" $ \o ->
        WalletJSON
            <$> o .: "txIn"
            <*> o .: "address"

instance ToJSON WalletJSON where
    toJSON WalletJSON{..} =
        object
            [ "txIn" .= wjTxIn
            , "address" .= wjAddress
            ]

{- | Scope block: the treasury inputs, leftover totals,
deployed-script references, and registry pointer for the
chosen scope. Shared across all four actions; the
disburse-only @treasuryLeftoverUsdm@ /
@treasuryLeftoverOtherAssets@ fields are present
unconditionally and default to @0@ / @{}@ on actions
that do not carry USDM.
-}
data ScopeJSON = ScopeJSON
    { sjId :: !Text
    -- ^ canonical scope name (@core_development@ etc.)
    , sjTreasuryAddress :: !Text
    , sjTreasuryUtxos :: ![Text]
    , sjTreasuryLeftoverLovelace :: !Integer
    , sjTreasuryLeftoverUsdm :: !Integer
    , sjTreasuryLeftoverOtherAssets
        :: !(Map Text (Map Text Integer))
    -- ^ outer key: policy hex; inner key:
    --     asset-name hex
    , sjTreasuryScriptHash :: !Text
    , sjPermissionsRewardAccount :: !Text
    , sjScopesDeployedAt :: !Text
    , sjPermissionsDeployedAt :: !Text
    , sjTreasuryDeployedAt :: !Text
    , sjRegistryDeployedAt :: !Text
    , sjRegistryPolicyId :: !Text
    }
    deriving stock (Eq, Show)

instance FromJSON ScopeJSON where
    parseJSON = withObject "ScopeJSON" $ \o ->
        ScopeJSON
            <$> o .: "id"
            <*> o .: "treasuryAddress"
            <*> o .: "treasuryUtxos"
            <*> o .: "treasuryLeftoverLovelace"
            <*> o .: "treasuryLeftoverUsdm"
            <*> o .: "treasuryLeftoverOtherAssets"
            <*> o .: "treasuryScriptHash"
            <*> o .: "permissionsRewardAccount"
            <*> o .: "scopesDeployedAt"
            <*> o .: "permissionsDeployedAt"
            <*> o .: "treasuryDeployedAt"
            <*> o .: "registryDeployedAt"
            <*> o .: "registryPolicyId"

instance ToJSON ScopeJSON where
    toJSON ScopeJSON{..} =
        object
            [ "id" .= sjId
            , "treasuryAddress" .= sjTreasuryAddress
            , "treasuryUtxos" .= sjTreasuryUtxos
            , "treasuryLeftoverLovelace"
                .= sjTreasuryLeftoverLovelace
            , "treasuryLeftoverUsdm"
                .= sjTreasuryLeftoverUsdm
            , "treasuryLeftoverOtherAssets"
                .= sjTreasuryLeftoverOtherAssets
            , "treasuryScriptHash" .= sjTreasuryScriptHash
            , "permissionsRewardAccount"
                .= sjPermissionsRewardAccount
            , "scopesDeployedAt" .= sjScopesDeployedAt
            , "permissionsDeployedAt"
                .= sjPermissionsDeployedAt
            , "treasuryDeployedAt" .= sjTreasuryDeployedAt
            , "registryDeployedAt" .= sjRegistryDeployedAt
            , "registryPolicyId" .= sjRegistryPolicyId
            ]

{- | Rationale block. Defaults are applied upstream by
the wizard's pure translation; the JSON parser requires
every field to be present (the wizard never emits an
intent with a missing rationale field).
-}
data RationaleJSON = RationaleJSON
    { rjEvent :: !Text
    , rjLabel :: !Text
    , rjDescription :: !Text
    , rjJustification :: !Text
    , rjDestinationLabel :: !Text
    }
    deriving stock (Eq, Show)

instance FromJSON RationaleJSON where
    parseJSON = withObject "RationaleJSON" $ \o ->
        RationaleJSON
            <$> o .: "event"
            <*> o .: "label"
            <*> o .: "description"
            <*> o .: "justification"
            <*> o .: "destinationLabel"

instance ToJSON RationaleJSON where
    toJSON RationaleJSON{..} =
        object
            [ "event" .= rjEvent
            , "label" .= rjLabel
            , "description" .= rjDescription
            , "justification" .= rjJustification
            , "destinationLabel" .= rjDestinationLabel
            ]

-- ----------------------------------------------------
-- Per-action input records
-- ----------------------------------------------------

{- | Swap-action payload — the per-chunk SundaeSwap V3
order parameters plus the four scope owner key hashes
that authorise the swap redeemer.
-}
data SwapInputs = SwapInputs
    { swiSwapOrderAddress :: !Text
    , swiChunkSizeLovelace :: !Integer
    , swiAmountLovelace :: !Integer
    , swiExtraPerChunkLovelace :: !Integer
    , swiRateNumerator :: !Integer
    , swiRateDenominator :: !Integer
    , swiPoolId :: !Text
    , swiCoreOwner :: !Text
    , swiOpsOwner :: !Text
    , swiNetworkComplianceOwner :: !Text
    , swiMiddlewareOwner :: !Text
    , swiSundaeProtocolFeeLovelace :: !Integer
    , swiUsdmPolicy :: !Text
    , swiUsdmToken :: !Text
    }
    deriving stock (Eq, Show)

instance FromJSON SwapInputs where
    parseJSON = withObject "SwapInputs" $ \o ->
        SwapInputs
            <$> o .: "swapOrderAddress"
            <*> o .: "chunkSizeLovelace"
            <*> o .: "amountLovelace"
            <*> o .: "extraPerChunkLovelace"
            <*> o .: "rateNumerator"
            <*> o .: "rateDenominator"
            <*> o .: "poolId"
            <*> o .: "coreOwner"
            <*> o .: "opsOwner"
            <*> o .: "networkComplianceOwner"
            <*> o .: "middlewareOwner"
            <*> o .: "sundaeProtocolFeeLovelace"
            <*> o .: "usdmPolicy"
            <*> o .: "usdmToken"

instance ToJSON SwapInputs where
    toJSON SwapInputs{..} =
        object
            [ "swapOrderAddress" .= swiSwapOrderAddress
            , "chunkSizeLovelace" .= swiChunkSizeLovelace
            , "amountLovelace" .= swiAmountLovelace
            , "extraPerChunkLovelace"
                .= swiExtraPerChunkLovelace
            , "rateNumerator" .= swiRateNumerator
            , "rateDenominator" .= swiRateDenominator
            , "poolId" .= swiPoolId
            , "coreOwner" .= swiCoreOwner
            , "opsOwner" .= swiOpsOwner
            , "networkComplianceOwner"
                .= swiNetworkComplianceOwner
            , "middlewareOwner" .= swiMiddlewareOwner
            , "sundaeProtocolFeeLovelace"
                .= swiSundaeProtocolFeeLovelace
            , "usdmPolicy" .= swiUsdmPolicy
            , "usdmToken" .= swiUsdmToken
            ]

{- | Disburse-action payload. Mirrors feature 004's
'Amaru.Treasury.Tx.DisburseIntentJSON.DisburseInputsJSON'
on the same JSON keys.
-}
data DisburseInputs = DisburseInputs
    { diUnit :: !Text
    -- ^ @"ada"@ or @"usdm"@
    , diAmount :: !Integer
    , diBeneficiaryAddress :: !Text
    , diUsdmPolicy :: !Text
    , diUsdmToken :: !Text
    }
    deriving stock (Eq, Show)

instance FromJSON DisburseInputs where
    parseJSON = withObject "DisburseInputs" $ \o ->
        DisburseInputs
            <$> o .: "unit"
            <*> o .: "amount"
            <*> o .: "beneficiaryAddress"
            <*> o .: "usdmPolicy"
            <*> o .: "usdmToken"

instance ToJSON DisburseInputs where
    toJSON DisburseInputs{..} =
        object
            [ "unit" .= diUnit
            , "amount" .= diAmount
            , "beneficiaryAddress" .= diBeneficiaryAddress
            , "usdmPolicy" .= diUsdmPolicy
            , "usdmToken" .= diUsdmToken
            ]

{- | Withdraw-action payload (placeholder until
[#45](https://github.com/lambdasistemi/amaru-treasury-tx/issues/45)
ships). Empty record so the parser can still produce a
typed value; real shape lands when withdraw ships.
-}
data WithdrawInputs = WithdrawInputs
    deriving stock (Eq, Show)

instance FromJSON WithdrawInputs where
    parseJSON = withObject "WithdrawInputs" $ \_ ->
        pure WithdrawInputs

instance ToJSON WithdrawInputs where
    toJSON WithdrawInputs = object []

{- | Reorganize-action payload (placeholder until
[#46](https://github.com/lambdasistemi/amaru-treasury-tx/issues/46)
ships).
-}
data ReorganizeInputs = ReorganizeInputs
    deriving stock (Eq, Show)

instance FromJSON ReorganizeInputs where
    parseJSON = withObject "ReorganizeInputs" $ \_ ->
        pure ReorganizeInputs

instance ToJSON ReorganizeInputs where
    toJSON ReorganizeInputs = object []

-- ----------------------------------------------------
-- Top-level intent (GADT indexed by Action)
-- ----------------------------------------------------

{- | The parsed unified intent. @a@ is the type-level
action; @tiSAction@ is its runtime witness; @tiPayload@
projects to the matching per-action input record via the
'Payload' family.

The action ↔ payload pairing is enforced at compile
time: a value of type @TreasuryIntent \'Swap@ cannot
carry a disburse payload — the type family rules out
that bug class entirely.

FromJSON / ToJSON instances and the encoder / decoder /
'translateIntent' land in T014–T016.
-}
data TreasuryIntent (a :: Action) = TreasuryIntent
    { tiSAction :: !(SAction a)
    , tiSchema :: !Int
    -- ^ schema version. v0 allow-list = [1].
    , tiNetwork :: !Text
    -- ^ "mainnet" | "preprod" | "preview"
    , tiWallet :: !WalletJSON
    , tiScope :: !ScopeJSON
    , tiSigners :: ![Text]
    -- ^ 28-byte hex keyhashes; scope owner first.
    , tiValidityUpperBoundSlot :: !Word64
    , tiRationale :: !RationaleJSON
    , tiPayload :: !(Payload a)
    }

deriving stock instance (Show (Payload a)) => Show (TreasuryIntent a)

deriving stock instance (Eq (Payload a)) => Eq (TreasuryIntent a)

{- | Existential wrapper at the parser boundary. The
parser returns 'SomeTreasuryIntent' so it has one return
type regardless of which discriminator it read;
consumers unwrap and pattern-match on the 'SAction' once
at entry.
-}
data SomeTreasuryIntent where
    SomeTreasuryIntent
        :: !(SAction a)
        -> !(TreasuryIntent a)
        -> SomeTreasuryIntent

instance Show SomeTreasuryIntent where
    showsPrec p (SomeTreasuryIntent sa ti) =
        showParen (p > 10) $
            showString "SomeTreasuryIntent "
                . case sa of
                    SSwap -> showsPrec 11 ti
                    SDisburse -> showsPrec 11 ti
                    SWithdraw -> showsPrec 11 ti
                    SReorganize -> showsPrec 11 ti

instance Eq SomeTreasuryIntent where
    SomeTreasuryIntent sa ti == SomeTreasuryIntent sb tj =
        case (sa, sb) of
            (SSwap, SSwap) -> ti == tj
            (SDisburse, SDisburse) -> ti == tj
            (SWithdraw, SWithdraw) -> ti == tj
            (SReorganize, SReorganize) -> ti == tj
            _ -> False

-- ----------------------------------------------------
-- Schema versioning
-- ----------------------------------------------------

{- | The set of schema versions this binary accepts.
This is the **single source of truth** for the wire
contract on the @schema@ top-level field of an intent
JSON; the parser ('decodeTreasuryIntent') gates the
incoming @schema@ value against this list and rejects
anything outside it.

== Bump protocol

A future schema change /adds/ a new integer to this
list; the old number stays so old intents keep being
accepted. The compatibility matrix is therefore:

* /old binary, new intent/: rejected (schema not in
  the binary's allow-list — fail fast with a typed
  parse error).
* /new binary, old intent/: accepted iff the old
  schema is still in the list (the bump policy says
  it stays).
* /new binary, new intent/: accepted (new schema is
  in the list).

Removing a schema from the list is a breaking change
for already-archived intents; reserve it for genuinely
incompatible structural breaks and announce it in the
release notes.

The wire field itself is required (no default) so a
silently-missing @schema@ key always becomes a parse
error — never a silent acceptance against an implicit
default version.
-}
allowedSchemas :: [Int]
allowedSchemas = [1]

-- ----------------------------------------------------
-- Action <-> Text bijection
-- ----------------------------------------------------

{- | Render an 'Action' as its lower-case JSON
discriminator string.
-}
actionToText :: Action -> Text
actionToText = \case
    Swap -> "swap"
    Disburse -> "disburse"
    Withdraw -> "withdraw"
    Reorganize -> "reorganize"

instance FromJSON Action where
    parseJSON = withText "Action" $ \t -> case T.toLower t of
        "swap" -> pure Swap
        "disburse" -> pure Disburse
        "withdraw" -> pure Withdraw
        "reorganize" -> pure Reorganize
        other ->
            fail $
                "unknown action: "
                    <> T.unpack other
                    <> " (expected one of "
                    <> "swap | disburse | withdraw | reorganize)"

instance ToJSON Action where
    toJSON = toJSON . actionToText

-- ----------------------------------------------------
-- TreasuryIntent JSON
-- ----------------------------------------------------

{- | Parse to the existential. Validates schema +
action ↔ payload pairing in one pass.
-}
instance FromJSON SomeTreasuryIntent where
    parseJSON = withObject "TreasuryIntent" $ \o -> do
        schema <- o .: "schema"
        unless
            (schema `elem` allowedSchemas)
            ( fail $
                "unknown intent schema version: "
                    <> show schema
                    <> " (allowed: "
                    <> show allowedSchemas
                    <> ")"
            )
        action <- o .: "action"
        network <- o .: "network"
        wallet <- o .: "wallet"
        scope <- o .: "scope"
        signers <- o .: "signers"
        ub <- o .: "validityUpperBoundSlot"
        rationale <- o .: "rationale"
        case action of
            Swap -> do
                payload <- o .: "swap"
                pure $
                    SomeTreasuryIntent SSwap $
                        TreasuryIntent
                            SSwap
                            schema
                            network
                            wallet
                            scope
                            signers
                            ub
                            rationale
                            payload
            Disburse -> do
                payload <- o .: "disburse"
                pure $
                    SomeTreasuryIntent SDisburse $
                        TreasuryIntent
                            SDisburse
                            schema
                            network
                            wallet
                            scope
                            signers
                            ub
                            rationale
                            payload
            Withdraw -> do
                payload <- o .: "withdraw"
                pure $
                    SomeTreasuryIntent SWithdraw $
                        TreasuryIntent
                            SWithdraw
                            schema
                            network
                            wallet
                            scope
                            signers
                            ub
                            rationale
                            payload
            Reorganize -> do
                payload <- o .: "reorganize"
                pure $
                    SomeTreasuryIntent SReorganize $
                        TreasuryIntent
                            SReorganize
                            schema
                            network
                            wallet
                            scope
                            signers
                            ub
                            rationale
                            payload

{- | Emit the unified intent as JSON. Action discriminator
and the matching action-keyed payload object.
-}
instance ToJSON SomeTreasuryIntent where
    toJSON (SomeTreasuryIntent sa ti) =
        toJSONIntent sa ti

{- | Build the JSON 'Value' for a typed intent. Pure;
pattern matches the singleton to write the matching
action-keyed payload key.
-}
toJSONIntent :: SAction a -> TreasuryIntent a -> Value
toJSONIntent sa ti =
    let actionName = case sa of
            SSwap -> "swap" :: Text
            SDisburse -> "disburse"
            SWithdraw -> "withdraw"
            SReorganize -> "reorganize"
        payloadEntry = case sa of
            SSwap -> "swap" .= tiPayload ti
            SDisburse -> "disburse" .= tiPayload ti
            SWithdraw -> "withdraw" .= tiPayload ti
            SReorganize -> "reorganize" .= tiPayload ti
    in  object
            [ "schema" .= tiSchema ti
            , "action" .= actionName
            , "network" .= tiNetwork ti
            , "wallet" .= tiWallet ti
            , "scope" .= tiScope ti
            , "signers" .= tiSigners ti
            , "validityUpperBoundSlot"
                .= tiValidityUpperBoundSlot ti
            , "rationale" .= tiRationale ti
            , payloadEntry
            ]

-- ----------------------------------------------------
-- Decoding / encoding
-- ----------------------------------------------------

-- | Parse a 'SomeTreasuryIntent' from a UTF-8 byte string.
decodeTreasuryIntent
    :: ByteString -> Either String SomeTreasuryIntent
decodeTreasuryIntent = eitherDecode

-- | 'decodeTreasuryIntent' over a file path.
decodeTreasuryIntentFile
    :: FilePath -> IO (Either String SomeTreasuryIntent)
decodeTreasuryIntentFile = eitherDecodeFileStrict

{- | Stable pretty-printed encoder for
'SomeTreasuryIntent'. Fixed config: 4-space indent,
alphabetical key ordering, no unicode escapes for ASCII
text, decimals for numbers, trailing newline.
-}
encodeSomeTreasuryIntent :: SomeTreasuryIntent -> ByteString
encodeSomeTreasuryIntent = encodePretty' cfg
  where
    cfg =
        Config
            { confIndent = Spaces 4
            , confCompare = compare
            , confNumFormat = Generic
            , confTrailingNewline = True
            }

-- ----------------------------------------------------
-- Translation
-- ----------------------------------------------------

{- | Shared translated boundary fields — the part of the
intent that doesn't depend on the action variant. The
typed lift consumed by 'TreasuryBuild.runBuild' is
@(TranslatedShared, Translated a)@.
-}
data TranslatedShared = TranslatedShared
    { tsNetwork :: !Text
    , tsWalletTxIn :: !TxIn
    , tsWalletAddr :: !Addr
    , tsRationale :: !Metadatum
    }

{- | Action-polymorphic translator. Dispatches on the
singleton; each branch produces the matching
@Translated a@ via the type family.
-}
translateIntent
    :: SAction a
    -> TreasuryIntent a
    -> Either String (TranslatedShared, Translated a)
translateIntent sa ti = case sa of
    SSwap -> translateSwap ti
    SDisburse -> translateDisburse ti
    SWithdraw ->
        Left
            "translateIntent: 'withdraw' not yet shipped (#45)"
    SReorganize ->
        Left
            "translateIntent: 'reorganize' not yet shipped (#46)"

{- | Swap-action translator. Body lifts the existing
'Tx.SwapIntentJSON.translateIntent' verbatim, retyped
to read directly from the unified 'TreasuryIntent'.
-}
translateSwap
    :: TreasuryIntent 'Swap
    -> Either String (TranslatedShared, SwapIntent)
translateSwap ti = do
    let wallet = tiWallet ti
        scope = tiScope ti
        sw = tiPayload ti
        rat = tiRationale ti
    walletAddr <- parseAddr (wjAddress wallet)
    walletTxIn <- parseTxIn (wjTxIn wallet)
    treasuryAddr <- parseAddr (sjTreasuryAddress scope)
    swapOrderAddr <- parseAddr (swiSwapOrderAddress sw)
    treasuryUtxos <-
        traverse parseTxIn (sjTreasuryUtxos scope)
    permissionsAcct <-
        parseRewardAccount (sjPermissionsRewardAccount scope)
    scopesRef <- parseTxIn (sjScopesDeployedAt scope)
    permissionsRef <-
        parseTxIn (sjPermissionsDeployedAt scope)
    treasuryRef <- parseTxIn (sjTreasuryDeployedAt scope)
    registryRef <- parseTxIn (sjRegistryDeployedAt scope)
    registryPolicy <-
        decodeHexBytes 28 (sjRegistryPolicyId scope)
    signers <- traverse parseGuardKeyHash (tiSigners ti)
    poolId <- decodeHexBytes 28 (swiPoolId sw)
    coreOwner <- decodeHexBytes 28 (swiCoreOwner sw)
    opsOwner <- decodeHexBytes 28 (swiOpsOwner sw)
    netcOwner <-
        decodeHexBytes 28 (swiNetworkComplianceOwner sw)
    midOwner <-
        decodeHexBytes 28 (swiMiddlewareOwner sw)
    treasurySh <-
        decodeHexBytes 28 (sjTreasuryScriptHash scope)
    usdmPol <- decodeHexBytesAny (swiUsdmPolicy sw)
    usdmTok <- decodeHexBytesAny (swiUsdmToken sw)
    let dp =
            SwapOrderDatumParams
                { sodPoolId = poolId
                , sodCoreOwner = coreOwner
                , sodOpsOwner = opsOwner
                , sodNetworkComplianceOwner = netcOwner
                , sodMiddlewareOwner = midOwner
                , sodSundaeProtocolFeeLovelace =
                    swiSundaeProtocolFeeLovelace sw
                , sodTreasuryScriptHash = treasurySh
                , sodUsdmPolicy = usdmPol
                , sodUsdmToken = usdmTok
                }
        chunks =
            mkChunks
                (swiChunkSizeLovelace sw)
                (swiAmountLovelace sw)
                ( swiRateNumerator sw
                , swiRateDenominator sw
                )
                dp
        intent =
            SwapIntent
                { siWalletUtxo = walletTxIn
                , siSwapOrderAddress = swapOrderAddr
                , siSwapOrders = chunks
                , siSwapOrderExtraLovelace =
                    Coin (swiExtraPerChunkLovelace sw)
                , siTreasuryUtxos = treasuryUtxos
                , siTreasuryAddress = treasuryAddr
                , siTreasuryLeftoverLovelace =
                    Coin (sjTreasuryLeftoverLovelace scope)
                , siTreasuryLeftoverAsset = Nothing
                , siRedeemerAmountLovelace =
                    Coin (swiAmountLovelace sw)
                , siPermissionsRewardAccount =
                    permissionsAcct
                , siScopesDeployedAt = scopesRef
                , siPermissionsDeployedAt = permissionsRef
                , siTreasuryDeployedAt = treasuryRef
                , siRegistryDeployedAt = registryRef
                , siSigners = signers
                , siUpperBound =
                    SlotNo (tiValidityUpperBoundSlot ti)
                }
        body =
            RationaleBody
                { rbEvent = rjEvent rat
                , rbLabel = rjLabel rat
                , rbDescription = [rjDescription rat]
                , rbDestinationLabel = rjDestinationLabel rat
                , rbJustification = [rjJustification rat]
                }
        shared =
            TranslatedShared
                { tsNetwork = tiNetwork ti
                , tsWalletTxIn = walletTxIn
                , tsWalletAddr = walletAddr
                , tsRationale =
                    rationaleMetadatum body registryPolicy
                }
    pure (shared, intent)

{- | Disburse-action translator. Reads the unified
'TreasuryIntent' disburse payload and produces the typed
'DisburseIntent' consumed by the build dispatcher.
-}
translateDisburse
    :: TreasuryIntent 'Disburse
    -> Either String (TranslatedShared, DisburseIntent)
translateDisburse ti = do
    let wallet = tiWallet ti
        scope = tiScope ti
        disb = tiPayload ti
        rat = tiRationale ti
    walletAddr <- parseAddr (wjAddress wallet)
    walletTxIn <- parseTxIn (wjTxIn wallet)
    treasuryAddr <- parseAddr (sjTreasuryAddress scope)
    treasuryUtxos <-
        traverse parseTxIn (sjTreasuryUtxos scope)
    permissionsAcct <-
        parseRewardAccount (sjPermissionsRewardAccount scope)
    scopesRef <- parseTxIn (sjScopesDeployedAt scope)
    permissionsRef <-
        parseTxIn (sjPermissionsDeployedAt scope)
    treasuryRef <- parseTxIn (sjTreasuryDeployedAt scope)
    registryRef <- parseTxIn (sjRegistryDeployedAt scope)
    registryPolicy <-
        decodeHexBytes 28 (sjRegistryPolicyId scope)
    beneficiaryAddr <-
        parseAddr (diBeneficiaryAddress disb)
    signers <- traverse parseGuardKeyHash (tiSigners ti)
    let fields =
            DisburseIntentFields
                { difWalletUtxo = walletTxIn
                , difBeneficiaryAddress = beneficiaryAddr
                , difTreasuryUtxos = treasuryUtxos
                , difTreasuryAddress = treasuryAddr
                , difPermissionsRewardAccount =
                    permissionsAcct
                , difScopesDeployedAt = scopesRef
                , difPermissionsDeployedAt = permissionsRef
                , difTreasuryDeployedAt = treasuryRef
                , difRegistryDeployedAt = registryRef
                , difSigners = signers
                , difUpperBound =
                    SlotNo (tiValidityUpperBoundSlot ti)
                }
    intent <- case T.toLower (diUnit disb) of
        "ada" ->
            Right $
                DisburseAdaIntent
                    fields
                    DisburseAdaPayload
                        { dapAmountLovelace =
                            Coin (diAmount disb)
                        , dapLeftoverLovelace =
                            Coin
                                ( sjTreasuryLeftoverLovelace
                                    scope
                                )
                        }
        "usdm" ->
            Left
                "USDM disburse JSON parsed; pure builder lands in T038"
        other ->
            Left ("unknown disburse unit: " <> T.unpack other)
    let body =
            RationaleBody
                { rbEvent = rjEvent rat
                , rbLabel = rjLabel rat
                , rbDescription = [rjDescription rat]
                , rbDestinationLabel = rjDestinationLabel rat
                , rbJustification = [rjJustification rat]
                }
        shared =
            TranslatedShared
                { tsNetwork = tiNetwork ti
                , tsWalletTxIn = walletTxIn
                , tsWalletAddr = walletAddr
                , tsRationale =
                    rationaleMetadatum body registryPolicy
                }
    pure (shared, intent)

{- | Per-chunk swap-order builder. Lifted verbatim from
'Tx.SwapIntentJSON.mkChunks'; that copy is deleted in
T028 alongside the rest of the per-action JSON module.
-}
mkChunks
    :: Integer
    -- ^ chunkSize
    -> Integer
    -- ^ totalAmount
    -> (Integer, Integer)
    -- ^ (rateNum, rateDen)
    -> SwapOrderDatumParams
    -> [SwapOrderOut]
mkChunks chunkSize totalAmount (rNum, rDen) dp =
    let full = totalAmount `div` chunkSize
        rem' = totalAmount `mod` chunkSize
        usdm n = (n * rNum + rDen - 1) `div` rDen
        fullChunk =
            SwapOrderOut
                (Coin chunkSize)
                (swapOrderDatum dp chunkSize (usdm chunkSize))
        remChunk =
            SwapOrderOut
                (Coin rem')
                (swapOrderDatum dp rem' (usdm rem'))
        fulls = replicate (fromInteger full) fullChunk
    in  if rem' > 0 then fulls ++ [remChunk] else fulls
