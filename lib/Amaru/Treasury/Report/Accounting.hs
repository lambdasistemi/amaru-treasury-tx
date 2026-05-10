{-# LANGUAGE OverloadedStrings #-}

module Amaru.Treasury.Report.Accounting
    ( UtxoSummary (..)
    , ValueSummary (..)
    , addValueSummary
    , emptyValue
    , subtractValueSummary
    , sumValueSummaries
    , treasuryNetDebit
    , valueSummary
    ) where

import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Data.Aeson
    ( FromJSON (..)
    , ToJSON (..)
    , object
    , withObject
    , (.:)
    , (.=)
    )
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Short qualified as SBS
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text.Encoding qualified as Text

import Amaru.Treasury.Registry.Derive (scriptHashToHex)

data ValueSummary = ValueSummary
    { vsLovelace :: Integer
    , vsAssets :: Map Text (Map Text Integer)
    }
    deriving stock (Eq, Show)

data UtxoSummary = UtxoSummary
    { usTxIn :: Text
    , usValue :: ValueSummary
    }
    deriving stock (Eq, Show)

instance ToJSON ValueSummary where
    toJSON value =
        object
            [ "lovelace" .= vsLovelace value
            , "assets" .= vsAssets value
            ]

instance FromJSON ValueSummary where
    parseJSON = withObject "ValueSummary" $ \o ->
        ValueSummary
            <$> o .: "lovelace"
            <*> o .: "assets"

instance ToJSON UtxoSummary where
    toJSON utxo =
        object
            [ "txIn" .= usTxIn utxo
            , "value" .= usValue utxo
            ]

instance FromJSON UtxoSummary where
    parseJSON = withObject "UtxoSummary" $ \o ->
        UtxoSummary
            <$> o .: "txIn"
            <*> o .: "value"

emptyValue :: ValueSummary
emptyValue =
    ValueSummary
        { vsLovelace = 0
        , vsAssets = Map.empty
        }

valueSummary :: MaryValue -> ValueSummary
valueSummary (MaryValue (Coin lovelace) (MultiAsset policies)) =
    ValueSummary
        { vsLovelace = lovelace
        , vsAssets =
            normalizeAssets
                [ ( policyIdText policy
                  , Map.singleton (assetNameText asset) quantity
                  )
                | (policy, assets) <- Map.toList policies
                , (asset, quantity) <- Map.toList assets
                , quantity /= 0
                ]
        }

sumValueSummaries :: [ValueSummary] -> ValueSummary
sumValueSummaries =
    foldr addValueSummary emptyValue

addValueSummary :: ValueSummary -> ValueSummary -> ValueSummary
addValueSummary left right =
    ValueSummary
        { vsLovelace = vsLovelace left + vsLovelace right
        , vsAssets =
            normalizeAssets $
                Map.toList (vsAssets left)
                    <> Map.toList (vsAssets right)
        }

subtractValueSummary :: ValueSummary -> ValueSummary -> ValueSummary
subtractValueSummary left right =
    addValueSummary
        left
        ValueSummary
            { vsLovelace = negate (vsLovelace right)
            , vsAssets = fmap (fmap negate) (vsAssets right)
            }

treasuryNetDebit :: ValueSummary -> ValueSummary -> ValueSummary
treasuryNetDebit inputTotal leftover =
    inputTotal `subtractValueSummary` leftover

normalizeAssets
    :: [(Text, Map Text Integer)] -> Map Text (Map Text Integer)
normalizeAssets =
    Map.filter (not . Map.null)
        . fmap (Map.filter (/= 0))
        . Map.fromListWith (Map.unionWith (+))

policyIdText :: PolicyID -> Text
policyIdText (PolicyID scriptHash) = scriptHashToHex scriptHash

assetNameText :: AssetName -> Text
assetNameText (AssetName raw) =
    Text.decodeUtf8 (B16.encode (SBS.fromShort raw))
