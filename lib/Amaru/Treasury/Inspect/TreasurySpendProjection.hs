{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

{- |
Module      : Amaru.Treasury.Inspect.TreasurySpendProjection
Description : Typed projection of the treasury spend redeemer
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Decodes the @treasury.treasury.spend@ redeemer against the treasury
CIP-57 blueprint vendored from the Aiken contracts repo (see
@assets/blueprints/PROVENANCE.md@) using
'Cardano.Tx.Blueprint.decodeBlueprintDataWith'. The blueprint is
compiled into the backend and never accepted at request time.

The redeemer is the @TreasurySpendRedeemer@ sum
(@Reorganize | SweepTreasury | Fund | Disburse@). The decoder selects
the matching alternative by constructor index but does not surface its
title, so the variant name is read from the redeemer's own constructor
index; the @amount@ asset map (for @Fund@/@Disburse@) is taken from the
blueprint-decoded value.
-}
module Amaru.Treasury.Inspect.TreasurySpendProjection
    ( ProjectedTreasurySpend (..)
    , ProjectedAsset (..)
    , projectTreasurySpendRedeemer
    ) where

import Data.Aeson
    ( FromJSON (..)
    , ToJSON (..)
    , object
    , withObject
    , (.:)
    , (.=)
    )
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.FileEmbed (embedFile)
import Data.List (find)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T

import Cardano.Ledger.Api.Scripts.Data (Data (..))
import Cardano.Ledger.Conway (ConwayEra)
import PlutusCore.Data qualified as PLC

import Cardano.Tx.Blueprint
    ( Blueprint (..)
    , BlueprintArgument (..)
    , BlueprintSchema
    , BlueprintValidator (..)
    , decodeBlueprintDataWith
    , parseBlueprintJSON
    )
import Cardano.Tx.Diff (OpenValue (..))

-- | One asset entry of a @Fund@/@Disburse@ redeemer @amount@ map.
data ProjectedAsset = ProjectedAsset
    { paPolicy :: !Text
    -- ^ Minting-policy id, hex; empty for ADA.
    , paAsset :: !Text
    -- ^ Asset name, hex; empty for ADA.
    , paQuantity :: !Integer
    }
    deriving stock (Eq, Show)

-- | Typed projection of a @treasury.treasury.spend@ redeemer.
data ProjectedTreasurySpend = ProjectedTreasurySpend
    { ptsVariant :: !Text
    -- ^ @Reorganize@ | @SweepTreasury@ | @Fund@ | @Disburse@.
    , ptsAmount :: ![ProjectedAsset]
    -- ^ Asset map for @Fund@/@Disburse@; empty for the field-less
    -- @Reorganize@/@SweepTreasury@ variants.
    }
    deriving stock (Eq, Show)

instance ToJSON ProjectedAsset where
    toJSON a =
        object
            [ "policy" .= paPolicy a
            , "asset" .= paAsset a
            , "quantity" .= paQuantity a
            ]

instance FromJSON ProjectedAsset where
    parseJSON =
        withObject "ProjectedAsset" $ \o ->
            ProjectedAsset
                <$> o .: "policy"
                <*> o .: "asset"
                <*> o .: "quantity"

instance ToJSON ProjectedTreasurySpend where
    toJSON p =
        object
            [ "variant" .= ptsVariant p
            , "amount" .= ptsAmount p
            ]

instance FromJSON ProjectedTreasurySpend where
    parseJSON =
        withObject "ProjectedTreasurySpend" $ \o ->
            ProjectedTreasurySpend
                <$> o .: "variant"
                <*> o .: "amount"

treasurySpendBlueprintBytes :: ByteString
treasurySpendBlueprintBytes =
    $(embedFile "assets/blueprints/treasury-spend.cip57.json")

{- | The @treasury.treasury.spend@ redeemer schema plus the blueprint's
definition map (for per-occurrence @$ref@ resolution).
-}
treasurySpendRedeemerSchema
    :: Either Text (Map Text BlueprintSchema, BlueprintSchema)
treasurySpendRedeemerSchema = do
    blueprint <-
        first T.pack $
            parseBlueprintJSON (LBS.fromStrict treasurySpendBlueprintBytes)
    validator <-
        maybe (Left "treasury.treasury.spend validator absent") Right $
            find
                ((== Just "treasury.treasury.spend") . validatorTitle)
                (blueprintValidators blueprint)
    argument <-
        maybe (Left "treasury.treasury.spend has no redeemer") Right $
            validatorRedeemer validator
    pure (blueprintDefinitions blueprint, argumentSchema argument)

{- | Project a @treasury.treasury.spend@ redeemer into its named variant
and (for @Fund@/@Disburse@) the disbursed asset map. Returns 'Left' for
any value that is not a recognised @TreasurySpendRedeemer@.
-}
projectTreasurySpendRedeemer
    :: Data ConwayEra -> Either Text ProjectedTreasurySpend
projectTreasurySpendRedeemer redeemer@(Data plutus) = do
    (definitions, schema) <- treasurySpendRedeemerSchema
    decoded <-
        first (T.pack . show) $
            decodeBlueprintDataWith definitions schema redeemer
    variant <- treasurySpendVariant plutus
    amount <- treasurySpendAmount decoded
    pure ProjectedTreasurySpend{ptsVariant = variant, ptsAmount = amount}

treasurySpendVariant :: PLC.Data -> Either Text Text
treasurySpendVariant = \case
    PLC.Constr 0 _ -> Right "Reorganize"
    PLC.Constr 1 _ -> Right "SweepTreasury"
    PLC.Constr 2 _ -> Right "Fund"
    PLC.Constr 3 _ -> Right "Disburse"
    other ->
        Left
            ( "unexpected treasury spend redeemer constructor: "
                <> T.pack (show other)
            )

treasurySpendAmount :: OpenValue -> Either Text [ProjectedAsset]
treasurySpendAmount = \case
    OpenObject fields ->
        case Map.lookup "amount" fields of
            Nothing -> Right []
            Just (OpenArray policies) ->
                concat <$> traverse policyAssets policies
            Just other ->
                Left ("treasury redeemer amount not a map: " <> showT other)
    other ->
        Left ("treasury redeemer not a constructor object: " <> showT other)

policyAssets :: OpenValue -> Either Text [ProjectedAsset]
policyAssets = \case
    OpenObject entry -> do
        policy <- openKey "key" entry >>= openBytes
        assets <- openKey "value" entry >>= openArray
        traverse (assetQuantity policy) assets
    other -> Left ("treasury amount policy entry malformed: " <> showT other)

assetQuantity :: Text -> OpenValue -> Either Text ProjectedAsset
assetQuantity policy = \case
    OpenObject entry -> do
        asset <- openKey "key" entry >>= openBytes
        quantity <- openKey "value" entry >>= openInteger
        pure
            ProjectedAsset
                { paPolicy = policy
                , paAsset = asset
                , paQuantity = quantity
                }
    other -> Left ("treasury amount asset entry malformed: " <> showT other)

openKey :: Text -> Map Text OpenValue -> Either Text OpenValue
openKey key entry =
    maybe
        (Left ("missing blueprint field: " <> key))
        Right
        (Map.lookup key entry)

openBytes :: OpenValue -> Either Text Text
openBytes = \case
    OpenBytes hex -> Right hex
    other -> Left ("expected bytes, got: " <> showT other)

openInteger :: OpenValue -> Either Text Integer
openInteger = \case
    OpenInteger n -> Right n
    other -> Left ("expected integer, got: " <> showT other)

openArray :: OpenValue -> Either Text [OpenValue]
openArray = \case
    OpenArray xs -> Right xs
    other -> Left ("expected array, got: " <> showT other)

showT :: OpenValue -> Text
showT = T.pack . show
