{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}

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
    ) where

import Data.Aeson
    ( FromJSON (..)
    , ToJSON (..)
    , object
    , withObject
    , (.:)
    , (.=)
    )
import Data.Kind (Type)
import Data.Map.Strict (Map)
import Data.Text (Text)

import Amaru.Treasury.Tx.Disburse (DisburseIntent)
import Amaru.Treasury.Tx.Reorganize (ReorganizeIntent)
import Amaru.Treasury.Tx.Swap (SwapIntent)
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

{- | Swap-action payload. Identical fields to today's
'Amaru.Treasury.Tx.SwapIntentJSON.SwapInputs'.
-}
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
            [ "swapOrderAddress" .= siSwapOrderAddress
            , "chunkSizeLovelace" .= siChunkSizeLovelace
            , "amountLovelace" .= siAmountLovelace
            , "extraPerChunkLovelace"
                .= siExtraPerChunkLovelace
            , "rateNumerator" .= siRateNumerator
            , "rateDenominator" .= siRateDenominator
            , "poolId" .= siPoolId
            , "coreOwner" .= siCoreOwner
            , "opsOwner" .= siOpsOwner
            , "networkComplianceOwner"
                .= siNetworkComplianceOwner
            , "middlewareOwner" .= siMiddlewareOwner
            , "sundaeProtocolFeeLovelace"
                .= siSundaeProtocolFeeLovelace
            , "usdmPolicy" .= siUsdmPolicy
            , "usdmToken" .= siUsdmToken
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
