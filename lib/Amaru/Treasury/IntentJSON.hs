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
    , RationaleJSON
        ( RationaleJSON
        , rjEvent
        , rjLabel
        , rjDescription
        , rjJustification
        , rjDestinationLabel
        , rjReferences
        )
    , RationaleReferenceJSON (..)
    , fromJSONReference
    , rationaleDescriptionLines
    , rationaleJustificationLines

      -- * Per-action input records
    , SwapInputs (..)
    , DisburseInputs (..)
    , WithdrawInputs (..)
    , ReorganizeInputs (..)
    , RegistryInitSeedSplitInputs (..)
    , RegistryInitMintInputs (..)
    , RegistryInitReferenceScriptsInputs (..)
    , StakeRewardInitScriptAccountInputs (..)
    , StakeRewardInitPlainAccountInputs (..)
    , GovernanceWithdrawalInitProposalInputs (..)
    , GovernanceWithdrawalInitMaterializationInputs (..)

      -- * Per-action translated records (registry-init)
    , RegistryInitSeedSplitTx (..)
    , RegistryInitMintTx (..)
    , RegistryInitReferenceScriptsTx (..)

      -- * Per-action translated records (stake-reward-init)
    , StakeRewardInitScriptAccountTx (..)
    , StakeRewardInitPlainAccountTx (..)

      -- * Per-action translated records (governance-withdrawal-init)
    , GovernanceWithdrawalInitProposalTx (..)
    , GovernanceWithdrawalInitMaterializationTx (..)

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

      -- * Chunk shape
    , chunkLovelaces
    , mkChunks
    ) where

import Control.Monad (unless)
import Data.Aeson
    ( FromJSON (..)
    , ToJSON (..)
    , Value (..)
    , eitherDecode
    , eitherDecodeFileStrict
    , object
    , withObject
    , withText
    , (.!=)
    , (.:)
    , (.:?)
    , (.=)
    )
import Data.Aeson.Encode.Pretty
    ( Config (..)
    , Indent (..)
    , NumberFormat (..)
    , encodePretty'
    )
import Data.Aeson.Types (Parser, typeMismatch)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy (ByteString)
import Data.ByteString.Short qualified as SBS
import Data.Foldable (toList)
import Data.Kind (Type)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word64)

import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Ledger.Address
    ( AccountAddress (..)
    , AccountId (..)
    , Addr (..)
    , deserialiseAccountAddress
    , getNetwork
    , serialiseAccountAddress
    , serialiseAddr
    )
import Cardano.Ledger.BaseTypes
    ( Network (..)
    , textToUrl
    , txIxToInt
    )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway.Governance (Anchor (..))
import Cardano.Ledger.Credential
    ( Credential (..)
    , StakeReference (..)
    )
import Cardano.Ledger.Hashes
    ( KeyHash (..)
    , ScriptHash (..)
    , extractHash
    , unsafeMakeSafeHash
    )
import Cardano.Ledger.Keys
    ( KeyRole (DRepRole, Guard, Payment, Staking)
    )
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.Metadata (Metadatum (..))
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Cardano.Slotting.Slot (SlotNo (..))
import Codec.Binary.Bech32 qualified as Bech32

import Amaru.Treasury.AuxData
    ( RationaleBody (..)
    , RationaleReference (..)
    , rationaleMetadatum
    )
import Amaru.Treasury.IntentJSON.Common
    ( decodeHexBytes
    , decodeHexBytesAny
    , mkHash28
    , parseAddr
    , parseGuardKeyHash
    , parseNetwork
    , parseRewardAccount
    , parseRewardAccountForNetwork
    , parseTxIn
    )
import Amaru.Treasury.Tx.Disburse
    ( DisburseAdaPayload (..)
    , DisburseIntent (..)
    , DisburseIntentFields (..)
    , DisburseUsdmPayload (..)
    )
import Amaru.Treasury.Tx.Reorganize (ReorganizeIntent (..))
import Amaru.Treasury.Tx.Swap
    ( SwapIntent (..)
    , SwapOrderDatumParams (..)
    , SwapOrderOut (..)
    , swapOrderDatum
    )
import Amaru.Treasury.Tx.Withdraw (WithdrawIntent (..))

-- ----------------------------------------------------
-- Action enum + singleton
-- ----------------------------------------------------

{- | The four treasury actions. Promoted to the type
level via @-XDataKinds@ so it can index 'TreasuryIntent'
in T007.
-}
data Action
    = Swap
    | Disburse
    | Withdraw
    | Reorganize
    | RegistryInitSeedSplit
    | RegistryInitMint
    | RegistryInitReferenceScripts
    | StakeRewardInitScriptAccount
    | StakeRewardInitPlainAccount
    | GovernanceWithdrawalInitProposal
    | GovernanceWithdrawalInitMaterialization
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
    SRegistryInitSeedSplit :: SAction 'RegistryInitSeedSplit
    SRegistryInitMint :: SAction 'RegistryInitMint
    SRegistryInitReferenceScripts
        :: SAction 'RegistryInitReferenceScripts
    SStakeRewardInitScriptAccount
        :: SAction 'StakeRewardInitScriptAccount
    SStakeRewardInitPlainAccount
        :: SAction 'StakeRewardInitPlainAccount
    SGovernanceWithdrawalInitProposal
        :: SAction 'GovernanceWithdrawalInitProposal
    SGovernanceWithdrawalInitMaterialization
        :: SAction 'GovernanceWithdrawalInitMaterialization

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
    Payload 'RegistryInitSeedSplit =
        RegistryInitSeedSplitInputs
    Payload 'RegistryInitMint = RegistryInitMintInputs
    Payload 'RegistryInitReferenceScripts =
        RegistryInitReferenceScriptsInputs
    Payload 'StakeRewardInitScriptAccount =
        StakeRewardInitScriptAccountInputs
    Payload 'StakeRewardInitPlainAccount =
        StakeRewardInitPlainAccountInputs
    Payload 'GovernanceWithdrawalInitProposal =
        GovernanceWithdrawalInitProposalInputs
    Payload 'GovernanceWithdrawalInitMaterialization =
        GovernanceWithdrawalInitMaterializationInputs

{- | Per-action translated form — the typed lift consumed
by the build path. Names the existing per-action typed
intent records.
-}
type family Translated (a :: Action) :: Type where
    Translated 'Swap = SwapIntent
    Translated 'Disburse = DisburseIntent
    Translated 'Withdraw = WithdrawIntent
    Translated 'Reorganize = ReorganizeIntent
    -- Slices 3a–3c ship all seven init rows as the typed
    -- input records consumed by the extracted construction
    -- cores under @lib/Amaru/Treasury/Devnet/*Init.hs@.
    Translated 'RegistryInitSeedSplit = RegistryInitSeedSplitTx
    Translated 'RegistryInitMint = RegistryInitMintTx
    Translated 'RegistryInitReferenceScripts =
        RegistryInitReferenceScriptsTx
    Translated 'StakeRewardInitScriptAccount =
        StakeRewardInitScriptAccountTx
    Translated 'StakeRewardInitPlainAccount =
        StakeRewardInitPlainAccountTx
    Translated 'GovernanceWithdrawalInitProposal =
        GovernanceWithdrawalInitProposalTx
    Translated 'GovernanceWithdrawalInitMaterialization =
        GovernanceWithdrawalInitMaterializationTx

-- ----------------------------------------------------
-- Shared structural blocks
-- ----------------------------------------------------

-- | Wallet block: the fuel + collateral input.
data WalletJSON = WalletJSON
    { wjTxIn :: !Text
    -- ^ @\<txid hex\>#\<ix\>@ — the head wallet UTxO that
    -- doubles as collateral.
    , wjAddress :: !Text
    -- ^ bech32 @addr1…@
    , wjExtraTxIns :: ![Text]
    -- ^ Additional pure-ADA wallet UTxOs aggregated as fuel
    -- alongside @wjTxIn@. Empty for legacy intents and for
    -- swaps whose head UTxO already covers the wallet target;
    -- non-empty when the wizard had to top up from smaller
    -- wallet UTxOs.
    }
    deriving stock (Eq, Show)

instance FromJSON WalletJSON where
    parseJSON = withObject "WalletJSON" $ \o ->
        WalletJSON
            <$> o .: "txIn"
            <*> o .: "address"
            <*> o .:? "extraTxIns" .!= []

instance ToJSON WalletJSON where
    toJSON WalletJSON{..} =
        object
            [ "txIn" .= wjTxIn
            , "address" .= wjAddress
            , "extraTxIns" .= wjExtraTxIns
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
intent with a missing rationale field) except
@references@, which is optional and defaults to @[]@
for back-compat with pre-S2 intents.
-}
data RationaleJSON = RationaleJSONInternal
    { rjiEvent :: !Text
    , rjiLabel :: !Text
    , rjiDescription :: !RationaleText
    , rjiJustification :: !RationaleText
    , rjiDestinationLabel :: !Text
    , rjiReferences :: ![RationaleReferenceJSON]
    }
    deriving stock (Eq, Show)

pattern RationaleJSON
    :: Text
    -> Text
    -> Text
    -> Text
    -> Text
    -> [RationaleReferenceJSON]
    -> RationaleJSON
pattern RationaleJSON
    { rjEvent
    , rjLabel
    , rjDescription
    , rjJustification
    , rjDestinationLabel
    , rjReferences
    } <-
    RationaleJSONInternal
        { rjiEvent = rjEvent
        , rjiLabel = rjLabel
        , rjiDescription = (rationaleTextToText -> rjDescription)
        , rjiJustification = (rationaleTextToText -> rjJustification)
        , rjiDestinationLabel = rjDestinationLabel
        , rjiReferences = rjReferences
        }
    where
        RationaleJSON
            event
            label
            description
            justification
            destinationLabel
            references =
                RationaleJSONInternal
                    { rjiEvent = event
                    , rjiLabel = label
                    , rjiDescription = RationaleTextScalar description
                    , rjiJustification = RationaleTextScalar justification
                    , rjiDestinationLabel = destinationLabel
                    , rjiReferences = references
                    }

{-# COMPLETE RationaleJSON #-}

{- | Backwards-compatible internal rationale text field.

Legacy wizard intents emit scalar JSON strings. Historical
chain-shaped rationale metadata can carry multiple paragraph chunks,
so the decoder also accepts an array of strings and preserves that
shape on re-encode.
-}
data RationaleText
    = RationaleTextScalar !Text
    | RationaleTextLines ![Text]
    deriving stock (Eq, Show)

{- | JSON-side projection of 'RationaleReference'. Wire
shape: @{ "uri", "@type", "label" }@. The @"@type"@
field is optional on parse (defaults to @"Other"@); on
emit it is always present.
-}
data RationaleReferenceJSON = RationaleReferenceJSON
    { rjrUri :: !Text
    , rjrType :: !Text
    , rjrLabel :: !Text
    }
    deriving stock (Eq, Show)

instance FromJSON RationaleText where
    parseJSON value = case value of
        String t -> pure (RationaleTextScalar t)
        Array xs ->
            RationaleTextLines
                <$> traverse parseJSON (toList xs)
        _ -> typeMismatch "string or array of strings" value

instance ToJSON RationaleText where
    toJSON (RationaleTextScalar t) = toJSON t
    toJSON (RationaleTextLines ts) = toJSON ts

-- | Project a rationale text value to metadatum text chunks.
rationaleTextLines :: RationaleText -> [Text]
rationaleTextLines (RationaleTextScalar t) = [t]
rationaleTextLines (RationaleTextLines ts) = ts

-- | Render rationale text for human-facing summaries.
rationaleTextToText :: RationaleText -> Text
rationaleTextToText =
    T.intercalate " " . rationaleTextLines

-- | Project the description field to metadatum text chunks.
rationaleDescriptionLines :: RationaleJSON -> [Text]
rationaleDescriptionLines =
    rationaleTextLines . rjiDescription

-- | Project the justification field to metadatum text chunks.
rationaleJustificationLines :: RationaleJSON -> [Text]
rationaleJustificationLines =
    rationaleTextLines . rjiJustification

instance FromJSON RationaleJSON where
    parseJSON = withObject "RationaleJSON" $ \o ->
        RationaleJSONInternal
            <$> o .: "event"
            <*> o .: "label"
            <*> o .: "description"
            <*> o .: "justification"
            <*> o .: "destinationLabel"
            <*> o .:? "references" .!= []

instance ToJSON RationaleJSON where
    toJSON RationaleJSONInternal{..} =
        object
            [ "event" .= rjiEvent
            , "label" .= rjiLabel
            , "description" .= rjiDescription
            , "justification" .= rjiJustification
            , "destinationLabel" .= rjiDestinationLabel
            , "references" .= rjiReferences
            ]

instance FromJSON RationaleReferenceJSON where
    parseJSON =
        withObject "RationaleReferenceJSON" $ \o ->
            RationaleReferenceJSON
                <$> o .: "uri"
                <*> o .:? "@type" .!= "Other"
                <*> o .: "label"

instance ToJSON RationaleReferenceJSON where
    toJSON RationaleReferenceJSON{..} =
        object
            [ "uri" .= rjrUri
            , "@type" .= rjrType
            , "label" .= rjrLabel
            ]

{- | Project a 'RationaleReferenceJSON' (wire shape) into
the typed 'RationaleReference' consumed by the
metadatum builder.
-}
fromJSONReference :: RationaleReferenceJSON -> RationaleReference
fromJSONReference r =
    RationaleReference
        { rrUri = rjrUri r
        , rrType = rjrType r
        , rrLabel = rjrLabel r
        }

-- ----------------------------------------------------
-- Per-action input records
-- ----------------------------------------------------

{- | Swap-action payload — the per-chunk SundaeSwap V3
order parameters plus the scope owner key hashes available to the
order-datum builder.
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

{- | Withdraw-action payload. Carries the treasury stake
script hash plus the positive reward balance the wizard
resolved before emitting the intent.
-}
data WithdrawInputs = WithdrawInputs
    { wdiTreasuryRewardAccount :: !Text
    -- ^ 28-byte hex stake-script hash
    , wdiRewardsLovelace :: !Integer
    -- ^ strictly positive reward balance
    }
    deriving stock (Eq, Show)

instance FromJSON WithdrawInputs where
    parseJSON = withObject "WithdrawInputs" $ \o ->
        WithdrawInputs
            <$> o .: "treasuryRewardAccount"
            <*> o .: "rewardsLovelace"

instance ToJSON WithdrawInputs where
    toJSON WithdrawInputs{..} =
        object
            [ "treasuryRewardAccount"
                .= wdiTreasuryRewardAccount
            , "rewardsLovelace" .= wdiRewardsLovelace
            ]

{- | Reorganize-action payload. Carries the ledger-shaped
inputs needed to merge one or more treasury UTxOs into a
single continuing treasury output.
-}
data ReorganizeInputs = ReorganizeInputs
    { riWalletUtxo :: !TxIn
    -- ^ wallet UTxO used as both fuel and collateral
    , riTreasuryUtxos :: !(NonEmpty TxIn)
    -- ^ treasury UTxOs to merge; parser rejects an empty array
    , riTreasuryAddress :: !Addr
    -- ^ destination treasury contract address
    , riTreasuryDeployedAt :: !TxIn
    -- ^ deployed treasury-script reference UTxO
    , riRegistryDeployedAt :: !TxIn
    -- ^ registry NFT reference UTxO
    , riPermissionsRewardAccount :: !AccountAddress
    -- ^ permissions reward account for the withdraw-zero entry
    , riPermissionsDeployedAt :: !TxIn
    -- ^ deployed permissions withdrawal-script reference UTxO
    , riScopeOwnerSigner :: !(KeyHash Guard)
    -- ^ scope-owner key hash required as signer
    , riUpperBound :: !SlotNo
    -- ^ @invalid_hereafter@ slot
    }
    deriving stock (Eq, Show)

instance FromJSON ReorganizeInputs where
    parseJSON = withObject "ReorganizeInputs" $ \o -> do
        walletUtxoText <- o .: "walletUtxo"
        treasuryUtxoTexts <- o .: "treasuryUtxos"
        treasuryUtxos <-
            case NE.nonEmpty (treasuryUtxoTexts :: [Text]) of
                Nothing -> fail "treasuryUtxos must be non-empty"
                Just txIns ->
                    traverse
                        (parseLedgerField "treasuryUtxos" . parseTxIn)
                        txIns
        treasuryAddressText <- o .: "treasuryAddress"
        treasuryDeployedAtText <- o .: "treasuryDeployedAt"
        registryDeployedAtText <- o .: "registryDeployedAt"
        permissionsRewardAccountText <-
            o .: "permissionsRewardAccount"
        permissionsDeployedAtText <- o .: "permissionsDeployedAt"
        scopeOwnerSignerText <- o .: "scopeOwnerSigner"
        upperBound <- o .: "upperBound"
        ReorganizeInputs
            <$> parseLedgerField
                "walletUtxo"
                (parseTxIn walletUtxoText)
            <*> pure treasuryUtxos
            <*> parseLedgerField
                "treasuryAddress"
                (parseAddr treasuryAddressText)
            <*> parseLedgerField
                "treasuryDeployedAt"
                (parseTxIn treasuryDeployedAtText)
            <*> parseLedgerField
                "registryDeployedAt"
                (parseTxIn registryDeployedAtText)
            <*> parseLedgerField
                "permissionsRewardAccount"
                ( parseRewardAccountBech32
                    permissionsRewardAccountText
                )
            <*> parseLedgerField
                "permissionsDeployedAt"
                (parseTxIn permissionsDeployedAtText)
            <*> parseLedgerField
                "scopeOwnerSigner"
                (parseGuardKeyHash scopeOwnerSignerText)
            <*> pure (SlotNo (upperBound :: Word64))

instance ToJSON ReorganizeInputs where
    toJSON ReorganizeInputs{..} =
        object
            [ "walletUtxo" .= renderTxIn riWalletUtxo
            , "treasuryUtxos"
                .= fmap renderTxIn (NE.toList riTreasuryUtxos)
            , "treasuryAddress" .= renderAddr riTreasuryAddress
            , "treasuryDeployedAt"
                .= renderTxIn riTreasuryDeployedAt
            , "registryDeployedAt"
                .= renderTxIn riRegistryDeployedAt
            , "permissionsRewardAccount"
                .= renderRewardAccount riPermissionsRewardAccount
            , "permissionsDeployedAt"
                .= renderTxIn riPermissionsDeployedAt
            , "scopeOwnerSigner"
                .= renderGuardKeyHash riScopeOwnerSigner
            , "upperBound" .= renderSlotNo riUpperBound
            ]

parseLedgerField :: String -> Either String a -> Parser a
parseLedgerField fieldName =
    either
        (fail . ((fieldName <> ": ") <>))
        pure

parseRewardAccountBech32 :: Text -> Either String AccountAddress
parseRewardAccountBech32 t = do
    (hrp, dataPart) <-
        case Bech32.decodeLenient t of
            Left e -> Left ("bech32: " <> show e)
            Right decoded -> Right decoded
    let hrpText = Bech32.humanReadablePartToText hrp
    case hrpText of
        "stake" -> pure ()
        "stake_test" -> pure ()
        _ ->
            Left
                "reward account must use stake or stake_test bech32 prefix"
    raw <-
        maybe
            (Left "bech32 data-part decode")
            Right
            (Bech32.dataPartToBytes dataPart)
    account <-
        maybe
            (Left "reward account: decode failed")
            Right
            (deserialiseAccountAddress raw)
    case (hrpText, account) of
        ("stake", AccountAddress Mainnet _) -> Right account
        ("stake_test", AccountAddress Testnet _) -> Right account
        _ -> Left "reward account bech32 prefix/network mismatch"

renderTxIn :: TxIn -> Text
renderTxIn (TxIn (TxId txIdHash) txIx) =
    hexBytes (hashToBytes (extractHash txIdHash))
        <> "#"
        <> T.pack (show (txIxToInt txIx))

renderAddr :: Addr -> Text
renderAddr addr =
    renderBech32 (addrPrefix addr) (serialiseAddr addr)

addrPrefix :: Addr -> Text
addrPrefix addr = case getNetwork addr of
    Mainnet -> "addr"
    Testnet -> "addr_test"

renderRewardAccount :: AccountAddress -> Text
renderRewardAccount account =
    renderBech32
        (rewardAccountPrefix account)
        (serialiseAccountAddress account)

rewardAccountPrefix :: AccountAddress -> Text
rewardAccountPrefix (AccountAddress network _) = case network of
    Mainnet -> "stake"
    Testnet -> "stake_test"

renderBech32 :: Text -> BS.ByteString -> Text
renderBech32 prefix raw =
    Bech32.encodeLenient hrp (Bech32.dataPartFromBytes raw)
  where
    hrp =
        either
            ( errorWithoutStackTrace
                . ("renderBech32: " <>)
                . show
            )
            id
            (Bech32.humanReadablePartFromText prefix)

renderGuardKeyHash :: KeyHash Guard -> Text
renderGuardKeyHash (KeyHash h) = hexBytes (hashToBytes h)

renderSlotNo :: SlotNo -> Word64
renderSlotNo (SlotNo slot) = slot

hexBytes :: BS.ByteString -> Text
hexBytes = TE.decodeUtf8 . B16.encode

-- ----------------------------------------------------
-- DevNet init sub-action payloads (slice 2 / #157)
-- ----------------------------------------------------
--
-- The three @registry-init-*@ payloads are populated by
-- slice 3a; the remaining four ship as empty placeholders
-- until slices 3b / 3c extract their construction cores.
-- Adding a field later is a non-breaking change at the
-- JSON layer because old empty objects keep parsing.

{- | Registry-init seed-split sub-action payload.

The wallet block carries the funding seed TxIn and
funding address; this payload is intentionally empty
because the construction core reads everything else from
the top-level fields (wallet, network,
@validityUpperBoundSlot@).
-}
data RegistryInitSeedSplitInputs = RegistryInitSeedSplitInputs
    deriving stock (Eq, Show)

instance FromJSON RegistryInitSeedSplitInputs where
    parseJSON =
        withObject "RegistryInitSeedSplitInputs" $ \_ ->
            pure RegistryInitSeedSplitInputs

instance ToJSON RegistryInitSeedSplitInputs where
    toJSON RegistryInitSeedSplitInputs = object []

{- | Registry-init mint sub-action payload.

The two seed TxIns are the outputs of the seed-split
sub-transaction and double as the script-derivation
parameters for the scopes and registry NFT policies.
@ownerKeyHash@ is the scope owner baked into the scopes
NFT datum.
-}
data RegistryInitMintInputs = RegistryInitMintInputs
    { rimiScopesSeedTxIn :: !Text
    -- ^ scopes seed TxIn (@\<txid hex\>#\<ix\>@); first
    --     output of the seed-split sub-transaction
    , rimiRegistrySeedTxIn :: !Text
    -- ^ registry seed TxIn (@\<txid hex\>#\<ix\>@); second
    --     output of the seed-split sub-transaction
    , rimiOwnerKeyHash :: !Text
    -- ^ 28-byte hex; scope owner key hash baked into the
    --     scopes datum
    }
    deriving stock (Eq, Show)

instance FromJSON RegistryInitMintInputs where
    parseJSON =
        withObject "RegistryInitMintInputs" $ \o ->
            RegistryInitMintInputs
                <$> o .: "scopesSeedTxIn"
                <*> o .: "registrySeedTxIn"
                <*> o .: "ownerKeyHash"

instance ToJSON RegistryInitMintInputs where
    toJSON RegistryInitMintInputs{..} =
        object
            [ "scopesSeedTxIn" .= rimiScopesSeedTxIn
            , "registrySeedTxIn" .= rimiRegistrySeedTxIn
            , "ownerKeyHash" .= rimiOwnerKeyHash
            ]

{- | Registry-init reference-scripts sub-action payload.

The two seed TxIns reproduce the script derivation that
the mint sub-transaction performed; the wallet block
carries the funding seed TxIn that this sub-transaction
spends.
-}
data RegistryInitReferenceScriptsInputs
    = RegistryInitReferenceScriptsInputs
    { rirsiScopesSeedTxIn :: !Text
    -- ^ scopes seed TxIn (@\<txid hex\>#\<ix\>@) used for
    --     script derivation
    , rirsiRegistrySeedTxIn :: !Text
    -- ^ registry seed TxIn (@\<txid hex\>#\<ix\>@) used for
    --     script derivation
    }
    deriving stock (Eq, Show)

instance FromJSON RegistryInitReferenceScriptsInputs where
    parseJSON =
        withObject "RegistryInitReferenceScriptsInputs" $ \o ->
            RegistryInitReferenceScriptsInputs
                <$> o .: "scopesSeedTxIn"
                <*> o .: "registrySeedTxIn"

instance ToJSON RegistryInitReferenceScriptsInputs where
    toJSON RegistryInitReferenceScriptsInputs{..} =
        object
            [ "scopesSeedTxIn" .= rirsiScopesSeedTxIn
            , "registrySeedTxIn" .= rirsiRegistrySeedTxIn
            ]

-- ----------------------------------------------------
-- Translated records (registry-init)
-- ----------------------------------------------------

{- | Typed seed-split inputs consumed by the construction
core 'Amaru.Treasury.Devnet.RegistryInit.buildSeedSplitCore'.
-}
data RegistryInitSeedSplitTx = RegistryInitSeedSplitTx
    { risstFundingAddress :: !Addr
    , risstSeedTxIn :: !TxIn
    , risstUpperBoundSlot :: !SlotNo
    }
    deriving stock (Eq, Show)

{- | Typed registry-NFT mint inputs consumed by
'Amaru.Treasury.Devnet.RegistryInit.buildRegistryNftsCore'.
Carries the raw seed TxIns; script derivation runs at
dispatch time so the same construction core sees the same
'DevnetScriptSet' regardless of caller.
-}
data RegistryInitMintTx = RegistryInitMintTx
    { rimtFundingAddress :: !Addr
    , rimtNetwork :: !Network
    , rimtOwnerKeyHash :: !(KeyHash Payment)
    , rimtScopesSeedTxIn :: !TxIn
    , rimtRegistrySeedTxIn :: !TxIn
    , rimtUpperBoundSlot :: !SlotNo
    }
    deriving stock (Eq, Show)

{- | Typed reference-script publication inputs consumed by
'Amaru.Treasury.Devnet.RegistryInit.buildReferenceScriptsCore'.
The two seed TxIns reproduce the script derivation that
the mint sub-transaction performed.
-}
data RegistryInitReferenceScriptsTx = RegistryInitReferenceScriptsTx
    { rirstFundingAddress :: !Addr
    , rirstNetwork :: !Network
    , rirstSeedTxIn :: !TxIn
    , rirstScopesSeedTxIn :: !TxIn
    , rirstRegistrySeedTxIn :: !TxIn
    , rirstUpperBoundSlot :: !SlotNo
    }
    deriving stock (Eq, Show)

-- ----------------------------------------------------
-- Translated records (stake-reward-init)
-- ----------------------------------------------------

{- | Typed script-account inputs consumed by
'Amaru.Treasury.Devnet.StakeRewardInit.buildStakeRewardScriptAccountCore'.
-}
data StakeRewardInitScriptAccountTx
    = StakeRewardInitScriptAccountTx
    { srisatFundingAddress :: !Addr
    , srisatSeedTxIn :: !TxIn
    , srisatTreasuryRefTxIn :: !TxIn
    , srisatTreasuryCredential :: !(Credential Staking)
    , srisatUpperBoundSlot :: !SlotNo
    }
    deriving stock (Eq, Show)

{- | Typed plain-account inputs consumed by
'Amaru.Treasury.Devnet.StakeRewardInit.buildStakeRewardPlainAccountCore'.
-}
data StakeRewardInitPlainAccountTx
    = StakeRewardInitPlainAccountTx
    { srispatFundingAddress :: !Addr
    , srispatSeedTxIn :: !TxIn
    , srispatPermissionsCredential :: !(Credential Staking)
    , srispatUpperBoundSlot :: !SlotNo
    }
    deriving stock (Eq, Show)

-- ----------------------------------------------------
-- Translated records (governance-withdrawal-init)
-- ----------------------------------------------------

{- | Typed proposal inputs consumed by
'Amaru.Treasury.Devnet.GovernanceWithdrawalInit.buildGovernanceWithdrawalProposalCore'.
-}
data GovernanceWithdrawalInitProposalTx
    = GovernanceWithdrawalInitProposalTx
    { gwiptFundingAddress :: !Addr
    , gwiptSeedTxIn :: !TxIn
    , gwiptFundingCredential :: !(Credential Staking)
    , gwiptVoterCredential :: !(Credential Staking)
    , gwiptDrepCredential :: !(Credential DRepRole)
    , gwiptDrepKey :: !(KeyHash DRepRole)
    , gwiptVoterBaseAddr :: !Addr
    , gwiptReturnAccount :: !AccountAddress
    , gwiptTreasuryAccount :: !AccountAddress
    , gwiptAmount :: !Coin
    , gwiptUpperBoundSlot :: !SlotNo
    , gwiptAnchor :: !Anchor
    }
    deriving stock (Eq, Show)

{- | Typed materialization inputs consumed by
'Amaru.Treasury.Devnet.GovernanceWithdrawalInit.buildGovernanceWithdrawalMaterializationCore'.
-}
data GovernanceWithdrawalInitMaterializationTx
    = GovernanceWithdrawalInitMaterializationTx
    { gwimtFundingAddress :: !Addr
    , gwimtSeedTxIn :: !TxIn
    , gwimtTreasuryRewardAccount :: !AccountAddress
    , gwimtTreasuryAddress :: !Addr
    , gwimtTreasuryRefTxIn :: !TxIn
    , gwimtRegistryRefTxIn :: !TxIn
    , gwimtRewardsAmount :: !Coin
    , gwimtUpperBoundSlot :: !SlotNo
    }
    deriving stock (Eq, Show)

{- | Stake-reward-init script-account sub-action payload.

The wallet block carries the funding seed TxIn (also used
as collateral) and funding address. The payload supplies
the treasury reference-script anchor and the treasury
stake-script hash registered by this sub-transaction; the
stake-key deposit is read from protocol parameters at
build time.
-}
data StakeRewardInitScriptAccountInputs
    = StakeRewardInitScriptAccountInputs
    { srisaiTreasuryRefTxIn :: !Text
    -- ^ treasury reference-script TxIn
    -- (@\<txid hex\>#\<ix\>@); published by the
    -- @registry-init-reference-scripts@ sub-transaction
    , srisaiTreasuryScriptHash :: !Text
    -- ^ 28-byte hex; treasury stake-script hash whose
    -- credential the registration certificate carries
    }
    deriving stock (Eq, Show)

instance FromJSON StakeRewardInitScriptAccountInputs where
    parseJSON =
        withObject "StakeRewardInitScriptAccountInputs" $ \o ->
            StakeRewardInitScriptAccountInputs
                <$> o .: "treasuryRefTxIn"
                <*> o .: "treasuryScriptHash"

instance ToJSON StakeRewardInitScriptAccountInputs where
    toJSON StakeRewardInitScriptAccountInputs{..} =
        object
            [ "treasuryRefTxIn" .= srisaiTreasuryRefTxIn
            , "treasuryScriptHash" .= srisaiTreasuryScriptHash
            ]

{- | Stake-reward-init plain-account sub-action payload.

The wallet block carries the funding seed TxIn and
funding address. The payload supplies the permissions
stake-script hash registered by this sub-transaction; the
registration certificate is key-witnessed (@ConwayRegCert@
with no deposit override) so no reference inputs or
collateral are required.
-}
newtype StakeRewardInitPlainAccountInputs
    = StakeRewardInitPlainAccountInputs
    { srispiPermissionsScriptHash :: Text
    -- ^ 28-byte hex; permissions stake-script hash whose
    -- credential the registration certificate carries
    }
    deriving stock (Eq, Show)

instance FromJSON StakeRewardInitPlainAccountInputs where
    parseJSON =
        withObject "StakeRewardInitPlainAccountInputs" $ \o ->
            StakeRewardInitPlainAccountInputs
                <$> o .: "permissionsScriptHash"

instance ToJSON StakeRewardInitPlainAccountInputs where
    toJSON StakeRewardInitPlainAccountInputs{..} =
        object
            [ "permissionsScriptHash"
                .= srispiPermissionsScriptHash
            ]

{- | Governance-withdrawal-init proposal sub-action
payload.

The wallet block carries the funding seed TxIn (also used
as collateral) and funding address. The payload supplies
the treasury stake-script hash whose reward account the
proposal targets, the requested withdrawal amount, the
funding stake key hash (used as the proposal's reward
return account on rejection), the single voter signing
key hash (the production submitter derives the voter
staking, voter payment, and DRep key hashes from one
@SignKeyDSIGN@; the JSON keeps a single field for the
common case), and the CIP-1694 governance anchor URL +
content hash. Per-cert stake / DRep / governance deposits
are read from module-level constants matching the live
DevNet submitter.
-}
data GovernanceWithdrawalInitProposalInputs
    = GovernanceWithdrawalInitProposalInputs
    { gwipiTreasuryRewardAccountHash :: !Text
    -- ^ 28-byte hex; treasury stake-script hash whose
    -- reward account receives the withdrawal
    , gwipiWithdrawalAmountLovelace :: !Integer
    -- ^ strictly positive proposed withdrawal amount
    , gwipiFundingStakeKeyHash :: !Text
    -- ^ 28-byte hex; funding stake key hash —
    -- registered and used as the proposal's reward
    -- return account
    , gwipiVoterKeyHash :: !Text
    -- ^ 28-byte hex; voter signing key hash, reused for
    -- voter stake credential, voter payment credential,
    -- and DRep credential (matches the production
    -- submitter's single-key derivation)
    , gwipiAnchorUrl :: !Text
    -- ^ CIP-1694 governance anchor URL (UTF-8, up to 128
    -- bytes)
    , gwipiAnchorHash :: !Text
    -- ^ 32-byte hex; CIP-1694 governance anchor content
    -- hash
    }
    deriving stock (Eq, Show)

instance FromJSON GovernanceWithdrawalInitProposalInputs where
    parseJSON =
        withObject
            "GovernanceWithdrawalInitProposalInputs"
            $ \o ->
                GovernanceWithdrawalInitProposalInputs
                    <$> o .: "treasuryRewardAccountHash"
                    <*> o .: "withdrawalAmountLovelace"
                    <*> o .: "fundingStakeKeyHash"
                    <*> o .: "voterKeyHash"
                    <*> o .: "anchorUrl"
                    <*> o .: "anchorHash"

instance ToJSON GovernanceWithdrawalInitProposalInputs where
    toJSON GovernanceWithdrawalInitProposalInputs{..} =
        object
            [ "treasuryRewardAccountHash"
                .= gwipiTreasuryRewardAccountHash
            , "withdrawalAmountLovelace"
                .= gwipiWithdrawalAmountLovelace
            , "fundingStakeKeyHash"
                .= gwipiFundingStakeKeyHash
            , "voterKeyHash" .= gwipiVoterKeyHash
            , "anchorUrl" .= gwipiAnchorUrl
            , "anchorHash" .= gwipiAnchorHash
            ]

{- | Governance-withdrawal-init materialization
sub-action payload.

The wallet block carries the funding seed TxIn (also used
as collateral) and funding address. The payload supplies
the treasury stake-script hash that authorizes the
withdrawal, the treasury contract address that receives
the rewards, the two reference-script TxIns (treasury +
registry) that resolve the witness scripts, and the
already-observed reward balance to withdraw.
-}
data GovernanceWithdrawalInitMaterializationInputs
    = GovernanceWithdrawalInitMaterializationInputs
    { gwimiTreasuryRewardAccountHash :: !Text
    -- ^ 28-byte hex; treasury stake-script hash
    , gwimiTreasuryAddress :: !Text
    -- ^ Bech32 treasury contract address
    , gwimiTreasuryRefTxIn :: !Text
    -- ^ treasury reference-script TxIn
    -- (@\<txid hex\>#\<ix\>@)
    , gwimiRegistryRefTxIn :: !Text
    -- ^ registry reference-script TxIn
    , gwimiRewardsLovelace :: !Integer
    -- ^ strictly positive observed rewards balance
    }
    deriving stock (Eq, Show)

instance FromJSON GovernanceWithdrawalInitMaterializationInputs where
    parseJSON =
        withObject
            "GovernanceWithdrawalInitMaterializationInputs"
            $ \o ->
                GovernanceWithdrawalInitMaterializationInputs
                    <$> o .: "treasuryRewardAccountHash"
                    <*> o .: "treasuryAddress"
                    <*> o .: "treasuryRefTxIn"
                    <*> o .: "registryRefTxIn"
                    <*> o .: "rewardsLovelace"

instance ToJSON GovernanceWithdrawalInitMaterializationInputs where
    toJSON GovernanceWithdrawalInitMaterializationInputs{..} =
        object
            [ "treasuryRewardAccountHash"
                .= gwimiTreasuryRewardAccountHash
            , "treasuryAddress"
                .= gwimiTreasuryAddress
            , "treasuryRefTxIn"
                .= gwimiTreasuryRefTxIn
            , "registryRefTxIn"
                .= gwimiRegistryRefTxIn
            , "rewardsLovelace" .= gwimiRewardsLovelace
            ]

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
                    SRegistryInitSeedSplit -> showsPrec 11 ti
                    SRegistryInitMint -> showsPrec 11 ti
                    SRegistryInitReferenceScripts ->
                        showsPrec 11 ti
                    SStakeRewardInitScriptAccount ->
                        showsPrec 11 ti
                    SStakeRewardInitPlainAccount ->
                        showsPrec 11 ti
                    SGovernanceWithdrawalInitProposal ->
                        showsPrec 11 ti
                    SGovernanceWithdrawalInitMaterialization ->
                        showsPrec 11 ti

instance Eq SomeTreasuryIntent where
    SomeTreasuryIntent sa ti == SomeTreasuryIntent sb tj =
        case (sa, sb) of
            (SSwap, SSwap) -> ti == tj
            (SDisburse, SDisburse) -> ti == tj
            (SWithdraw, SWithdraw) -> ti == tj
            (SReorganize, SReorganize) -> ti == tj
            (SRegistryInitSeedSplit, SRegistryInitSeedSplit) ->
                ti == tj
            (SRegistryInitMint, SRegistryInitMint) ->
                ti == tj
            ( SRegistryInitReferenceScripts
                , SRegistryInitReferenceScripts
                ) -> ti == tj
            ( SStakeRewardInitScriptAccount
                , SStakeRewardInitScriptAccount
                ) -> ti == tj
            ( SStakeRewardInitPlainAccount
                , SStakeRewardInitPlainAccount
                ) -> ti == tj
            ( SGovernanceWithdrawalInitProposal
                , SGovernanceWithdrawalInitProposal
                ) -> ti == tj
            ( SGovernanceWithdrawalInitMaterialization
                , SGovernanceWithdrawalInitMaterialization
                ) -> ti == tj
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
    RegistryInitSeedSplit -> "registry-init-seed-split"
    RegistryInitMint -> "registry-init-mint"
    RegistryInitReferenceScripts ->
        "registry-init-reference-scripts"
    StakeRewardInitScriptAccount ->
        "stake-reward-init-script-account"
    StakeRewardInitPlainAccount ->
        "stake-reward-init-plain-account"
    GovernanceWithdrawalInitProposal ->
        "governance-withdrawal-init-proposal"
    GovernanceWithdrawalInitMaterialization ->
        "governance-withdrawal-init-materialization"

instance FromJSON Action where
    parseJSON = withText "Action" $ \t -> case T.toLower t of
        "swap" -> pure Swap
        "disburse" -> pure Disburse
        "withdraw" -> pure Withdraw
        "reorganize" -> pure Reorganize
        "registry-init-seed-split" ->
            pure RegistryInitSeedSplit
        "registry-init-mint" -> pure RegistryInitMint
        "registry-init-reference-scripts" ->
            pure RegistryInitReferenceScripts
        "stake-reward-init-script-account" ->
            pure StakeRewardInitScriptAccount
        "stake-reward-init-plain-account" ->
            pure StakeRewardInitPlainAccount
        "governance-withdrawal-init-proposal" ->
            pure GovernanceWithdrawalInitProposal
        "governance-withdrawal-init-materialization" ->
            pure GovernanceWithdrawalInitMaterialization
        other ->
            fail $
                "unknown action: "
                    <> T.unpack other
                    <> " (expected one of "
                    <> "swap | disburse | withdraw | reorganize"
                    <> " | registry-init-seed-split"
                    <> " | registry-init-mint"
                    <> " | registry-init-reference-scripts"
                    <> " | stake-reward-init-script-account"
                    <> " | stake-reward-init-plain-account"
                    <> " | governance-withdrawal-init-proposal"
                    <> " | governance-withdrawal-init-materialization"
                    <> ")"

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
            RegistryInitSeedSplit -> do
                payload <- o .: "registry-init-seed-split"
                pure $
                    SomeTreasuryIntent SRegistryInitSeedSplit $
                        TreasuryIntent
                            SRegistryInitSeedSplit
                            schema
                            network
                            wallet
                            scope
                            signers
                            ub
                            rationale
                            payload
            RegistryInitMint -> do
                payload <- o .: "registry-init-mint"
                pure $
                    SomeTreasuryIntent SRegistryInitMint $
                        TreasuryIntent
                            SRegistryInitMint
                            schema
                            network
                            wallet
                            scope
                            signers
                            ub
                            rationale
                            payload
            RegistryInitReferenceScripts -> do
                payload <-
                    o .: "registry-init-reference-scripts"
                pure
                    $ SomeTreasuryIntent
                        SRegistryInitReferenceScripts
                    $ TreasuryIntent
                        SRegistryInitReferenceScripts
                        schema
                        network
                        wallet
                        scope
                        signers
                        ub
                        rationale
                        payload
            StakeRewardInitScriptAccount -> do
                payload <-
                    o .: "stake-reward-init-script-account"
                pure
                    $ SomeTreasuryIntent
                        SStakeRewardInitScriptAccount
                    $ TreasuryIntent
                        SStakeRewardInitScriptAccount
                        schema
                        network
                        wallet
                        scope
                        signers
                        ub
                        rationale
                        payload
            StakeRewardInitPlainAccount -> do
                payload <-
                    o .: "stake-reward-init-plain-account"
                pure
                    $ SomeTreasuryIntent
                        SStakeRewardInitPlainAccount
                    $ TreasuryIntent
                        SStakeRewardInitPlainAccount
                        schema
                        network
                        wallet
                        scope
                        signers
                        ub
                        rationale
                        payload
            GovernanceWithdrawalInitProposal -> do
                payload <-
                    o .: "governance-withdrawal-init-proposal"
                pure
                    $ SomeTreasuryIntent
                        SGovernanceWithdrawalInitProposal
                    $ TreasuryIntent
                        SGovernanceWithdrawalInitProposal
                        schema
                        network
                        wallet
                        scope
                        signers
                        ub
                        rationale
                        payload
            GovernanceWithdrawalInitMaterialization -> do
                payload <-
                    o
                        .: "governance-withdrawal-init-materialization"
                pure
                    $ SomeTreasuryIntent
                        SGovernanceWithdrawalInitMaterialization
                    $ TreasuryIntent
                        SGovernanceWithdrawalInitMaterialization
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
            SRegistryInitSeedSplit ->
                "registry-init-seed-split"
            SRegistryInitMint -> "registry-init-mint"
            SRegistryInitReferenceScripts ->
                "registry-init-reference-scripts"
            SStakeRewardInitScriptAccount ->
                "stake-reward-init-script-account"
            SStakeRewardInitPlainAccount ->
                "stake-reward-init-plain-account"
            SGovernanceWithdrawalInitProposal ->
                "governance-withdrawal-init-proposal"
            SGovernanceWithdrawalInitMaterialization ->
                "governance-withdrawal-init-materialization"
        payloadEntry = case sa of
            SSwap -> "swap" .= tiPayload ti
            SDisburse -> "disburse" .= tiPayload ti
            SWithdraw -> "withdraw" .= tiPayload ti
            SReorganize -> "reorganize" .= tiPayload ti
            SRegistryInitSeedSplit ->
                "registry-init-seed-split" .= tiPayload ti
            SRegistryInitMint ->
                "registry-init-mint" .= tiPayload ti
            SRegistryInitReferenceScripts ->
                "registry-init-reference-scripts"
                    .= tiPayload ti
            SStakeRewardInitScriptAccount ->
                "stake-reward-init-script-account"
                    .= tiPayload ti
            SStakeRewardInitPlainAccount ->
                "stake-reward-init-plain-account"
                    .= tiPayload ti
            SGovernanceWithdrawalInitProposal ->
                "governance-withdrawal-init-proposal"
                    .= tiPayload ti
            SGovernanceWithdrawalInitMaterialization ->
                "governance-withdrawal-init-materialization"
                    .= tiPayload ti
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
typed lift consumed by 'Build.runBuild' is
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
    SWithdraw -> translateWithdraw ti
    SReorganize -> translateReorganize ti
    SRegistryInitSeedSplit -> translateRegistryInitSeedSplit ti
    SRegistryInitMint -> translateRegistryInitMint ti
    SRegistryInitReferenceScripts ->
        translateRegistryInitReferenceScripts ti
    SStakeRewardInitScriptAccount ->
        translateStakeRewardInitScriptAccount ti
    SStakeRewardInitPlainAccount ->
        translateStakeRewardInitPlainAccount ti
    SGovernanceWithdrawalInitProposal ->
        translateGovernanceWithdrawalInitProposal ti
    SGovernanceWithdrawalInitMaterialization ->
        translateGovernanceWithdrawalInitMaterialization ti

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
    extraWalletTxIns <-
        traverse parseTxIn (wjExtraTxIns wallet)
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
        chunkCount =
            toInteger (length chunks)
        -- FR-001/FR-006: the treasury, not the operator
        -- wallet, funds the per-chunk swap-order overhead.
        -- The redeemer @amount@ is therefore the chunk
        -- total plus @N * extraPerChunkLovelace@ (the
        -- single authoritative overhead source named in
        -- FR-006). The leftover output already shrinks
        -- by the same amount because
        -- 'resolveWizardEnv' raises the treasury
        -- selection target by
        -- @N * ncExtraPerChunkLovelace@ before
        -- 'selectTreasury' computes
        -- 'tsLeftoverLovelace'.
        intent =
            SwapIntent
                { siWalletUtxo = walletTxIn
                , siExtraWalletInputs = extraWalletTxIns
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
                    Coin
                        ( swiAmountLovelace sw
                            + chunkCount
                                * swiExtraPerChunkLovelace sw
                        )
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
                , rbReferences = map fromJSONReference (rjReferences rat)
                , rbDescription = rationaleDescriptionLines rat
                , rbDestinationLabel = rjDestinationLabel rat
                , rbJustification = rationaleJustificationLines rat
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
        parseRewardAccountForNetwork
            (tiNetwork ti)
            (sjPermissionsRewardAccount scope)
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
            DisburseUsdmIntent fields
                <$> translateDisburseUsdm scope disb
        other ->
            Left ("unknown disburse unit: " <> T.unpack other)
    let body =
            RationaleBody
                { rbEvent = rjEvent rat
                , rbLabel = rjLabel rat
                , rbReferences = map fromJSONReference (rjReferences rat)
                , rbDescription = rationaleDescriptionLines rat
                , rbDestinationLabel = rjDestinationLabel rat
                , rbJustification = rationaleJustificationLines rat
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

translateDisburseUsdm
    :: ScopeJSON
    -> DisburseInputs
    -> Either String DisburseUsdmPayload
translateDisburseUsdm scope disb = do
    usdmPolicy <- parsePolicyId (diUsdmPolicy disb)
    usdmAsset <- parseAssetName (diUsdmToken disb)
    otherAssets <-
        parseMultiAsset
            (sjTreasuryLeftoverOtherAssets scope)
    pure
        DisburseUsdmPayload
            { dupUsdmPolicy = usdmPolicy
            , dupUsdmAsset = usdmAsset
            , dupAmountUsdm = diAmount disb
            , dupLeftoverLovelace =
                Coin (sjTreasuryLeftoverLovelace scope)
            , dupLeftoverUsdm =
                sjTreasuryLeftoverUsdm scope
            , dupLeftoverOtherAssets = otherAssets
            }

parsePolicyId :: Text -> Either String PolicyID
parsePolicyId text = do
    bytes <- decodeHexBytes 28 text
    pure (PolicyID (ScriptHash (mkHash28 bytes)))

parseAssetName :: Text -> Either String AssetName
parseAssetName text = do
    bytes <- decodeHexBytesAny text
    pure (AssetName (SBS.toShort bytes))

parseMultiAsset
    :: Map Text (Map Text Integer)
    -> Either String MultiAsset
parseMultiAsset assets =
    MultiAsset . normalizeAssetMap . Map.fromList
        <$> traverse parsePolicy (Map.toList assets)
  where
    parsePolicy (policyText, assetMap) = do
        policy <- parsePolicyId policyText
        parsedAssets <-
            Map.fromList
                <$> traverse parseAsset (Map.toList assetMap)
        pure (policy, parsedAssets)
    parseAsset (assetText, quantity) = do
        asset <- parseAssetName assetText
        pure (asset, quantity)

normalizeAssetMap
    :: Map PolicyID (Map AssetName Integer)
    -> Map PolicyID (Map AssetName Integer)
normalizeAssetMap =
    Map.filter (not . Map.null)
        . Map.map (Map.filter (/= 0))

{- | Withdraw-action translator. Reads the unified
'TreasuryIntent' withdraw payload and produces the typed
'WithdrawIntent' consumed by the build dispatcher.
-}
translateWithdraw
    :: TreasuryIntent 'Withdraw
    -> Either String (TranslatedShared, WithdrawIntent)
translateWithdraw ti = do
    let wallet = tiWallet ti
        scope = tiScope ti
        wd = tiPayload ti
        rat = tiRationale ti
    unless
        (wdiRewardsLovelace wd > 0)
        (Left "withdraw rewardsLovelace must be positive")
    walletAddr <- parseAddr (wjAddress wallet)
    walletTxIn <- parseTxIn (wjTxIn wallet)
    treasuryAddr <- parseAddr (sjTreasuryAddress scope)
    treasuryRewardAccount <-
        parseRewardAccountForNetwork
            (tiNetwork ti)
            (wdiTreasuryRewardAccount wd)
    treasuryRef <- parseTxIn (sjTreasuryDeployedAt scope)
    registryRef <- parseTxIn (sjRegistryDeployedAt scope)
    registryPolicy <-
        decodeHexBytes 28 (sjRegistryPolicyId scope)
    let intent =
            WithdrawIntent
                { wiWalletUtxo = walletTxIn
                , wiTreasuryRewardAccount =
                    treasuryRewardAccount
                , wiTreasuryAddress = treasuryAddr
                , wiTreasuryDeployedAt = treasuryRef
                , wiRegistryDeployedAt = registryRef
                , wiRewardsAmount =
                    Coin (wdiRewardsLovelace wd)
                , wiUpperBound =
                    SlotNo (tiValidityUpperBoundSlot ti)
                }
        body =
            RationaleBody
                { rbEvent = rjEvent rat
                , rbLabel = rjLabel rat
                , rbReferences = map fromJSONReference (rjReferences rat)
                , rbDescription = rationaleDescriptionLines rat
                , rbDestinationLabel = rjDestinationLabel rat
                , rbJustification = rationaleJustificationLines rat
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

{- | Reorganize-action translator. The payload is already
ledger-shaped, so translation mainly preserves the shared rationale
metadata and rejects degenerate duplicate treasury inputs.
-}
translateReorganize
    :: TreasuryIntent 'Reorganize
    -> Either String (TranslatedShared, ReorganizeIntent)
translateReorganize ti = do
    let wallet = tiWallet ti
        scope = tiScope ti
        inputs = tiPayload ti
        rat = tiRationale ti
    walletAddr <- parseAddr (wjAddress wallet)
    walletTxIn <- parseTxIn (wjTxIn wallet)
    registryPolicy <-
        decodeHexBytes 28 (sjRegistryPolicyId scope)
    treasuryUtxos <-
        uniqueReorganizeTreasuryUtxos
            (riTreasuryUtxos inputs)
    let body =
            RationaleBody
                { rbEvent = rjEvent rat
                , rbLabel = rjLabel rat
                , rbReferences = map fromJSONReference (rjReferences rat)
                , rbDescription = rationaleDescriptionLines rat
                , rbDestinationLabel = rjDestinationLabel rat
                , rbJustification = rationaleJustificationLines rat
                }
        shared =
            TranslatedShared
                { tsNetwork = tiNetwork ti
                , tsWalletTxIn = walletTxIn
                , tsWalletAddr = walletAddr
                , tsRationale =
                    rationaleMetadatum body registryPolicy
                }
        intent =
            ReorganizeIntent
                { rgiWalletUtxo = riWalletUtxo inputs
                , rgiTreasuryUtxos = treasuryUtxos
                , rgiTreasuryAddress = riTreasuryAddress inputs
                , rgiTreasuryDeployedAt =
                    riTreasuryDeployedAt inputs
                , rgiRegistryDeployedAt =
                    riRegistryDeployedAt inputs
                , rgiPermissionsRewardAccount =
                    riPermissionsRewardAccount inputs
                , rgiPermissionsDeployedAt =
                    riPermissionsDeployedAt inputs
                , rgiScopeOwnerSigner =
                    riScopeOwnerSigner inputs
                , rgiUpperBound = riUpperBound inputs
                }
    pure (shared, intent)

uniqueReorganizeTreasuryUtxos
    :: NonEmpty TxIn -> Either String (NonEmpty TxIn)
uniqueReorganizeTreasuryUtxos utxos =
    let deduped = NE.nub utxos
    in  if length deduped == length utxos
            then Right deduped
            else Left "ReorganizeInputs.treasuryUtxos: duplicates"

-- ----------------------------------------------------
-- Registry-init translators (slice 3a / #157)
-- ----------------------------------------------------

{- | Shared translator boundary for the three
@registry-init-*@ sub-actions.

Bootstrap intents do not carry a CIP-1694 rationale tree —
the construction cores never call @setMetadata@ — so
'tsRationale' is filled with an empty 'Metadatum' map and
the dispatcher arms ignore it. The other 'TranslatedShared'
fields are pulled from the wallet block exactly as the swap
/ disburse / withdraw translators do.
-}
translateRegistryInitShared
    :: TreasuryIntent a
    -> Either String (TranslatedShared, Addr, TxIn, SlotNo)
translateRegistryInitShared ti = do
    let wallet = tiWallet ti
    walletAddr <- parseAddr (wjAddress wallet)
    walletTxIn <- parseTxIn (wjTxIn wallet)
    let shared =
            TranslatedShared
                { tsNetwork = tiNetwork ti
                , tsWalletTxIn = walletTxIn
                , tsWalletAddr = walletAddr
                , tsRationale = emptyRationale
                }
    pure
        ( shared
        , walletAddr
        , walletTxIn
        , SlotNo (tiValidityUpperBoundSlot ti)
        )

-- | Empty rationale metadatum used by bootstrap init intents.
emptyRationale :: Metadatum
emptyRationale = Map []

-- | Registry-init seed-split translator.
translateRegistryInitSeedSplit
    :: TreasuryIntent 'RegistryInitSeedSplit
    -> Either
        String
        (TranslatedShared, RegistryInitSeedSplitTx)
translateRegistryInitSeedSplit ti = do
    (shared, fundingAddr, fundingTxIn, upperSlot) <-
        translateRegistryInitShared ti
    pure
        ( shared
        , RegistryInitSeedSplitTx
            { risstFundingAddress = fundingAddr
            , risstSeedTxIn = fundingTxIn
            , risstUpperBoundSlot = upperSlot
            }
        )

-- | Registry-init mint translator.
translateRegistryInitMint
    :: TreasuryIntent 'RegistryInitMint
    -> Either
        String
        (TranslatedShared, RegistryInitMintTx)
translateRegistryInitMint ti = do
    (shared, fundingAddr, _walletTxIn, upperSlot) <-
        translateRegistryInitShared ti
    network <- parseNetwork (tiNetwork ti)
    let payload = tiPayload ti
    scopesSeedTxIn <- parseTxIn (rimiScopesSeedTxIn payload)
    registrySeedTxIn <-
        parseTxIn (rimiRegistrySeedTxIn payload)
    ownerKeyHash <-
        parsePaymentKeyHash (rimiOwnerKeyHash payload)
    pure
        ( shared
        , RegistryInitMintTx
            { rimtFundingAddress = fundingAddr
            , rimtNetwork = network
            , rimtOwnerKeyHash = ownerKeyHash
            , rimtScopesSeedTxIn = scopesSeedTxIn
            , rimtRegistrySeedTxIn = registrySeedTxIn
            , rimtUpperBoundSlot = upperSlot
            }
        )

-- | Registry-init reference-scripts translator.
translateRegistryInitReferenceScripts
    :: TreasuryIntent 'RegistryInitReferenceScripts
    -> Either
        String
        ( TranslatedShared
        , RegistryInitReferenceScriptsTx
        )
translateRegistryInitReferenceScripts ti = do
    (shared, fundingAddr, fundingTxIn, upperSlot) <-
        translateRegistryInitShared ti
    network <- parseNetwork (tiNetwork ti)
    let payload = tiPayload ti
    scopesSeedTxIn <-
        parseTxIn (rirsiScopesSeedTxIn payload)
    registrySeedTxIn <-
        parseTxIn (rirsiRegistrySeedTxIn payload)
    pure
        ( shared
        , RegistryInitReferenceScriptsTx
            { rirstFundingAddress = fundingAddr
            , rirstNetwork = network
            , rirstSeedTxIn = fundingTxIn
            , rirstScopesSeedTxIn = scopesSeedTxIn
            , rirstRegistrySeedTxIn = registrySeedTxIn
            , rirstUpperBoundSlot = upperSlot
            }
        )

-- ----------------------------------------------------
-- Stake-reward-init translators (slice 3b / #157)
-- ----------------------------------------------------

{- | Shared translator boundary for the two
@stake-reward-init-*@ sub-actions.

Bootstrap intents do not carry a CIP-1694 rationale tree —
the construction cores never call @setMetadata@ — so
'tsRationale' is filled with an empty 'Metadatum' map and
the dispatcher arms ignore it. The other 'TranslatedShared'
fields are pulled from the wallet block exactly as the swap
/ disburse / withdraw translators do.
-}
translateStakeRewardInitShared
    :: TreasuryIntent a
    -> Either String (TranslatedShared, Addr, TxIn, SlotNo)
translateStakeRewardInitShared ti = do
    let wallet = tiWallet ti
    walletAddr <- parseAddr (wjAddress wallet)
    walletTxIn <- parseTxIn (wjTxIn wallet)
    let shared =
            TranslatedShared
                { tsNetwork = tiNetwork ti
                , tsWalletTxIn = walletTxIn
                , tsWalletAddr = walletAddr
                , tsRationale = emptyRationale
                }
    pure
        ( shared
        , walletAddr
        , walletTxIn
        , SlotNo (tiValidityUpperBoundSlot ti)
        )

-- | Stake-reward-init script-account translator.
translateStakeRewardInitScriptAccount
    :: TreasuryIntent 'StakeRewardInitScriptAccount
    -> Either
        String
        ( TranslatedShared
        , StakeRewardInitScriptAccountTx
        )
translateStakeRewardInitScriptAccount ti = do
    (shared, fundingAddr, fundingTxIn, upperSlot) <-
        translateStakeRewardInitShared ti
    let payload = tiPayload ti
    treasuryRefTxIn <-
        parseTxIn (srisaiTreasuryRefTxIn payload)
    treasuryCredential <-
        parseStakingScriptCredential
            (srisaiTreasuryScriptHash payload)
    pure
        ( shared
        , StakeRewardInitScriptAccountTx
            { srisatFundingAddress = fundingAddr
            , srisatSeedTxIn = fundingTxIn
            , srisatTreasuryRefTxIn = treasuryRefTxIn
            , srisatTreasuryCredential = treasuryCredential
            , srisatUpperBoundSlot = upperSlot
            }
        )

-- | Stake-reward-init plain-account translator.
translateStakeRewardInitPlainAccount
    :: TreasuryIntent 'StakeRewardInitPlainAccount
    -> Either
        String
        ( TranslatedShared
        , StakeRewardInitPlainAccountTx
        )
translateStakeRewardInitPlainAccount ti = do
    (shared, fundingAddr, fundingTxIn, upperSlot) <-
        translateStakeRewardInitShared ti
    let payload = tiPayload ti
    permissionsCredential <-
        parseStakingScriptCredential
            (srispiPermissionsScriptHash payload)
    pure
        ( shared
        , StakeRewardInitPlainAccountTx
            { srispatFundingAddress = fundingAddr
            , srispatSeedTxIn = fundingTxIn
            , srispatPermissionsCredential =
                permissionsCredential
            , srispatUpperBoundSlot = upperSlot
            }
        )

-- ----------------------------------------------------
-- Governance-withdrawal-init translators (slice 3c / #157)
-- ----------------------------------------------------

{- | Shared translator boundary for the two
@governance-withdrawal-init-*@ sub-actions.

Bootstrap intents do not carry a CIP-1694 rationale tree —
the construction cores never call @setMetadata@ — so
'tsRationale' is filled with an empty 'Metadatum' map and
the dispatcher arms ignore it. The other 'TranslatedShared'
fields are pulled from the wallet block exactly as the
swap / disburse / withdraw translators do.
-}
translateGovernanceWithdrawalInitShared
    :: TreasuryIntent a
    -> Either String (TranslatedShared, Addr, TxIn, SlotNo)
translateGovernanceWithdrawalInitShared ti = do
    let wallet = tiWallet ti
    walletAddr <- parseAddr (wjAddress wallet)
    walletTxIn <- parseTxIn (wjTxIn wallet)
    let shared =
            TranslatedShared
                { tsNetwork = tiNetwork ti
                , tsWalletTxIn = walletTxIn
                , tsWalletAddr = walletAddr
                , tsRationale = emptyRationale
                }
    pure
        ( shared
        , walletAddr
        , walletTxIn
        , SlotNo (tiValidityUpperBoundSlot ti)
        )

{- | Governance-withdrawal-init proposal translator.

Derives the typed ledger inputs the construction core
needs from a compact JSON payload. The funding key hash
becomes both the registered funding stake credential and
the proposal's reward return account. The single voter
key hash is reused for the voter stake credential, the
voter payment credential (combined with the voter stake
credential to form the voter base address), and the DRep
credential — matching the production DevNet submitter's
single-@SignKeyDSIGN@ derivation.
-}
translateGovernanceWithdrawalInitProposal
    :: TreasuryIntent 'GovernanceWithdrawalInitProposal
    -> Either
        String
        ( TranslatedShared
        , GovernanceWithdrawalInitProposalTx
        )
translateGovernanceWithdrawalInitProposal ti = do
    (shared, fundingAddr, fundingTxIn, upperSlot) <-
        translateGovernanceWithdrawalInitShared ti
    network <- parseNetwork (tiNetwork ti)
    let payload = tiPayload ti
    treasuryAccount <-
        parseRewardAccountForNetwork
            (tiNetwork ti)
            (gwipiTreasuryRewardAccountHash payload)
    fundingStakeKey <-
        parseStakingPubKeyHash
            (gwipiFundingStakeKeyHash payload)
    voterKey <- parseStakingPubKeyHash (gwipiVoterKeyHash payload)
    let fundingCredential = KeyHashObj fundingStakeKey
        voterCredential = KeyHashObj voterKey
        drepKey =
            stakingToDRepKeyHash voterKey
        drepCredential = KeyHashObj drepKey
        voterPaymentKey =
            stakingToPaymentKeyHash voterKey
        voterBaseAddr =
            Addr
                network
                (KeyHashObj voterPaymentKey)
                (StakeRefBase voterCredential)
        returnAccount =
            AccountAddress
                network
                (AccountId fundingCredential)
        amount = Coin (gwipiWithdrawalAmountLovelace payload)
    anchor <-
        parseGovernanceAnchor
            (gwipiAnchorUrl payload)
            (gwipiAnchorHash payload)
    pure
        ( shared
        , GovernanceWithdrawalInitProposalTx
            { gwiptFundingAddress = fundingAddr
            , gwiptSeedTxIn = fundingTxIn
            , gwiptFundingCredential = fundingCredential
            , gwiptVoterCredential = voterCredential
            , gwiptDrepCredential = drepCredential
            , gwiptDrepKey = drepKey
            , gwiptVoterBaseAddr = voterBaseAddr
            , gwiptReturnAccount = returnAccount
            , gwiptTreasuryAccount = treasuryAccount
            , gwiptAmount = amount
            , gwiptUpperBoundSlot = upperSlot
            , gwiptAnchor = anchor
            }
        )

-- | Governance-withdrawal-init materialization translator.
translateGovernanceWithdrawalInitMaterialization
    :: TreasuryIntent 'GovernanceWithdrawalInitMaterialization
    -> Either
        String
        ( TranslatedShared
        , GovernanceWithdrawalInitMaterializationTx
        )
translateGovernanceWithdrawalInitMaterialization ti = do
    (shared, fundingAddr, fundingTxIn, upperSlot) <-
        translateGovernanceWithdrawalInitShared ti
    let payload = tiPayload ti
    unless
        (gwimiRewardsLovelace payload > 0)
        ( Left
            "governance-withdrawal-init-materialization rewardsLovelace must be positive"
        )
    treasuryRewardAccount <-
        parseRewardAccountForNetwork
            (tiNetwork ti)
            (gwimiTreasuryRewardAccountHash payload)
    treasuryAddress <-
        parseAddr (gwimiTreasuryAddress payload)
    treasuryRefTxIn <-
        parseTxIn (gwimiTreasuryRefTxIn payload)
    registryRefTxIn <-
        parseTxIn (gwimiRegistryRefTxIn payload)
    pure
        ( shared
        , GovernanceWithdrawalInitMaterializationTx
            { gwimtFundingAddress = fundingAddr
            , gwimtSeedTxIn = fundingTxIn
            , gwimtTreasuryRewardAccount =
                treasuryRewardAccount
            , gwimtTreasuryAddress = treasuryAddress
            , gwimtTreasuryRefTxIn = treasuryRefTxIn
            , gwimtRegistryRefTxIn = registryRefTxIn
            , gwimtRewardsAmount =
                Coin (gwimiRewardsLovelace payload)
            , gwimtUpperBoundSlot = upperSlot
            }
        )

{- | Parse a 28-byte hex into a stake-role pubkey
'KeyHash'.
-}
parseStakingPubKeyHash
    :: Text -> Either String (KeyHash Staking)
parseStakingPubKeyHash t = do
    bytes <- decodeHexBytes 28 t
    Right (KeyHash (mkHash28 bytes))

{- | Reinterpret a 'KeyHash' 'Staking' as a 'KeyHash'
'DRepRole' — the underlying 28-byte hash is role-free.
The production DevNet submitter derives both the voter
staking credential and the voter DRep credential from a
single @SignKeyDSIGN@; this helper mirrors that derivation
on the JSON path.
-}
stakingToDRepKeyHash :: KeyHash Staking -> KeyHash DRepRole
stakingToDRepKeyHash (KeyHash h) = KeyHash h

{- | Reinterpret a 'KeyHash' 'Staking' as a 'KeyHash'
'Payment'. Used to derive the voter base address from the
single voter signing key.
-}
stakingToPaymentKeyHash
    :: KeyHash Staking -> KeyHash Payment
stakingToPaymentKeyHash (KeyHash h) = KeyHash h

{- | Parse a CIP-1694 governance 'Anchor' from a URL and
a 32-byte hex content hash.
-}
parseGovernanceAnchor
    :: Text -> Text -> Either String Anchor
parseGovernanceAnchor urlText hashText = do
    url <- case textToUrl 128 urlText of
        Just u -> Right u
        Nothing ->
            Left
                ( "governance anchor URL too long or invalid: "
                    <> T.unpack urlText
                )
    bytes <- decodeHexBytes 32 hashText
    Right (Anchor url (unsafeMakeSafeHash (mkHash28 bytes)))

{- | Parse a 28-byte hex into a stake-role script
'Credential'.
-}
parseStakingScriptCredential
    :: Text -> Either String (Credential Staking)
parseStakingScriptCredential t = do
    bytes <- decodeHexBytes 28 t
    Right (ScriptHashObj (ScriptHash (mkHash28 bytes)))

-- | Parse a 28-byte hex into a payment-role 'KeyHash'.
parsePaymentKeyHash :: Text -> Either String (KeyHash Payment)
parsePaymentKeyHash t = do
    bytes <- decodeHexBytes 28 t
    Right (KeyHash (mkHash28 bytes))

{- | Per-chunk lovelace values for a swap order. See #91.

* @c <= 0@         → empty (validator rejects upstream)
* @full == 0@      → one chunk of @amount@
* @rem == 0@       → @full@ chunks of @chunkSize@
* @0 < rem < full@ → @rem@ chunks of @chunkSize + 1@ followed by
                     @full - rem@ chunks of @chunkSize@.
                     This fires for @--split N@: by floor-division
                     @rem < N@, so the remainder is folded across
                     the first @rem@ chunks instead of becoming a
                     dust output.
* @rem >= full@    → @full@ chunks of @chunkSize@ followed by one
                     chunk of @rem@. This is the @--chunk-usdm X@
                     shape when the operator's chunk size leaves a
                     substantial remainder.

Invariant: @sum (chunkLovelaces a c) == a@ for @a, c > 0@.
-}
chunkLovelaces :: Integer -> Integer -> [Integer]
chunkLovelaces amount chunkSize
    | chunkSize <= 0 = []
    | full == 0 = [rem']
    | rem' == 0 = replicate (fromInteger full) chunkSize
    | rem' < full =
        replicate (fromInteger rem') (chunkSize + 1)
            <> replicate (fromInteger (full - rem')) chunkSize
    | otherwise =
        replicate (fromInteger full) chunkSize <> [rem']
  where
    (full, rem') = amount `divMod` chunkSize

{- | Per-chunk swap-order builder. Maps each value from
'chunkLovelaces' to a 'SwapOrderOut' with the corresponding
USDM datum amount (scaled by the per-chunk lovelace).
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
    [ SwapOrderOut (Coin n) (swapOrderDatum dp n (usdm n))
    | n <- chunkLovelaces totalAmount chunkSize
    ]
  where
    usdm n = (n * rNum + rDen - 1) `div` rDen
