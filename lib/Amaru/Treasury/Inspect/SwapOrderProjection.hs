{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

{- |
Module      : Amaru.Treasury.Inspect.SwapOrderProjection
Description : Typed projection of a SundaeSwap order inline datum
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Decodes a SundaeSwap @OrderDatum@ inline datum against the typed
SundaeSwap CIP-57 blueprint vendored at
@assets/blueprints/sundae-order.cip57.json@ (see
@assets/blueprints/PROVENANCE.md@) using
'Cardano.Tx.Blueprint.decodeBlueprintDataWith', whose per-occurrence
@$ref@ resolution tolerates the recursive @owner: MultisigScript@
field. The blueprint is compiled into the backend and never accepted
at request time.

The projection surfaces the operator-relevant fields the inspector
needs — the destination payment-credential @recipient@, the minimum
asset @details.min_received@, and the @max_protocol_fee@ scooper fee —
mirroring 'Amaru.Treasury.Tx.Swap.swapOrderDatum'.
-}
module Amaru.Treasury.Inspect.SwapOrderProjection
    ( ProjectedSwapOrder (..)
    , projectSwapOrderDatum
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

import Cardano.Tx.Blueprint
    ( Blueprint (..)
    , BlueprintArgument (..)
    , BlueprintSchema
    , BlueprintValidator (..)
    , decodeBlueprintDataWith
    , parseBlueprintJSON
    )
import Cardano.Tx.Diff (OpenValue (..))

import Amaru.Treasury.Inspect.TreasurySpendProjection
    ( ProjectedAsset (..)
    )

-- | Operator-relevant projection of a SundaeSwap @OrderDatum@.
data ProjectedSwapOrder = ProjectedSwapOrder
    { psoRecipient :: !Text
    -- ^ Destination payment-credential hash, hex (the funding scope's
    -- treasury script hash for an Amaru treasury swap).
    , psoMinReceived :: !ProjectedAsset
    -- ^ Minimum asset the order accepts (@details.min_received@).
    , psoScooperFee :: !Integer
    -- ^ Maximum protocol (scooper) fee in lovelace
    -- (@max_protocol_fee@).
    }
    deriving stock (Eq, Show)

instance ToJSON ProjectedSwapOrder where
    toJSON p =
        object
            [ "recipient" .= psoRecipient p
            , "minReceived" .= psoMinReceived p
            , "scooperFee" .= psoScooperFee p
            ]

instance FromJSON ProjectedSwapOrder where
    parseJSON =
        withObject "ProjectedSwapOrder" $ \o ->
            ProjectedSwapOrder
                <$> o .: "recipient"
                <*> o .: "minReceived"
                <*> o .: "scooperFee"

swapOrderBlueprintBytes :: ByteString
swapOrderBlueprintBytes =
    $(embedFile "assets/blueprints/sundae-order.cip57.json")

{- | The @OrderDatum@ schema (carried by the @documentation.spend@
validator) plus the blueprint definition map for @$ref@ resolution.
-}
swapOrderDatumSchema
    :: Either Text (Map Text BlueprintSchema, BlueprintSchema)
swapOrderDatumSchema = do
    blueprint <-
        first T.pack $
            parseBlueprintJSON (LBS.fromStrict swapOrderBlueprintBytes)
    validator <-
        maybe (Left "documentation.spend validator absent") Right $
            find
                ((== Just "documentation.spend") . validatorTitle)
                (blueprintValidators blueprint)
    argument <-
        maybe (Left "documentation.spend has no datum") Right $
            validatorDatum validator
    pure (blueprintDefinitions blueprint, argumentSchema argument)

{- | Project a SundaeSwap @OrderDatum@ inline datum. Returns 'Left' for
any value that does not decode against the @OrderDatum@ schema.
-}
projectSwapOrderDatum
    :: Data ConwayEra -> Either Text ProjectedSwapOrder
projectSwapOrderDatum datum = do
    (definitions, schema) <- swapOrderDatumSchema
    decoded <-
        first (T.pack . show) $
            decodeBlueprintDataWith definitions schema datum
    destination <- field "destination" decoded
    address <- field "address" destination
    paymentCredential <- field "payment_credential" address
    recipient <- field "field0" paymentCredential >>= openBytes
    details <- field "details" decoded
    minReceived <-
        field "min_received" details >>= openArray >>= assetTriple
    scooperFee <- field "max_protocol_fee" decoded >>= openInteger
    pure
        ProjectedSwapOrder
            { psoRecipient = recipient
            , psoMinReceived = minReceived
            , psoScooperFee = scooperFee
            }

field :: Text -> OpenValue -> Either Text OpenValue
field key = \case
    OpenObject fields ->
        maybe
            (Left ("missing blueprint field: " <> key))
            Right
            (Map.lookup key fields)
    other ->
        Left ("expected object for field " <> key <> ", got: " <> showT other)

assetTriple :: [OpenValue] -> Either Text ProjectedAsset
assetTriple = \case
    [policy, asset, quantity] ->
        ProjectedAsset
            <$> openBytes policy
            <*> openBytes asset
            <*> openInteger quantity
    other ->
        Left
            ( "expected a [policy, asset, quantity] triple: "
                <> T.pack (show other)
            )

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
