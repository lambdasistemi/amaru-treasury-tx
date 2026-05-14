{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Inspect.Schema
Description : JSON Schema for the treasury-inspect report
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

JSON Schema 2020-12 document for the @treasury-inspect@ report
shape. The schema is the contract between the binary's JSON
encoder ('Amaru.Treasury.Inspect.Render.encodeReport') and any
downstream automation (CI assertions, alert routers, dashboards).
The same schema is checked in at
@docs/assets/treasury-inspect-schema.json@ and gated by the
@just schema-check@ recipe.
-}
module Amaru.Treasury.Inspect.Schema
    ( treasuryInspectSchema
    , encodeTreasuryInspectSchema
    ) where

import Data.Aeson (Value, object, (.=))
import Data.Aeson.Encode.Pretty
    ( Config (..)
    , Indent (..)
    , NumberFormat (..)
    , encodePretty'
    )
import Data.Aeson.Key qualified as Key
import Data.Aeson.Types (Pair)
import Data.ByteString.Lazy (ByteString)
import Data.Text (Text)

-- | JSON Schema 2020-12 for the @treasury-inspect@ report.
treasuryInspectSchema :: Value
treasuryInspectSchema =
    object
        [ "$schema"
            .= ("https://json-schema.org/draft/2020-12/schema" :: Text)
        , "$id"
            .= ( "https://lambdasistemi.io/schemas/amaru-treasury-tx/treasury-inspect-report.schema.json"
                    :: Text
               )
        , "title" .= ("TreasuryInspectReport" :: Text)
        , "description"
            .= ( "Output of `amaru-treasury-tx treasury-inspect`. \
                 \Single-shot, read-only snapshot of treasury \
                 \balances and pending SundaeSwap orders for each \
                 \configured scope, at a given chain tip."
                    :: Text
               )
        , "type" .= ("object" :: Text)
        , "additionalProperties" .= False
        , "required" .= (["chainTip", "deployment", "scopes"] :: [Text])
        , "properties"
            .= object
                [ "chainTip" .= ref "ChainTip"
                , "deployment" .= ref "Deployment"
                , "scopes"
                    .= object
                        [ "type" .= ("array" :: Text)
                        , "description"
                            .= ( "One entry per reported scope, in \
                                 \stable order (CoreDevelopment, \
                                 \OpsAndUseCases, NetworkCompliance, \
                                 \Middleware, Contingency), filtered \
                                 \by --scope when set."
                                    :: Text
                               )
                        , "items" .= ref "ScopeSection"
                        ]
                ]
        , "$defs"
            .= object
                [ "Hex28" .= hexExact 28
                , "Hex32" .= hexExact 32
                , "Outref" .= outrefSchema
                , "ChainTip" .= chainTipSchema
                , "Deployment" .= deploymentSchema
                , "ScopeSection" .= scopeSectionSchema
                , "TreasuryUtxo" .= treasuryUtxoSchema
                , "ScopeTotals" .= scopeTotalsSchema
                , "OtherAsset" .= otherAssetSchema
                , "PendingSwapOrder" .= pendingSwapOrderSchema
                ]
        ]

-- | Stable pretty-printed encoding for the schema asset.
encodeTreasuryInspectSchema :: ByteString
encodeTreasuryInspectSchema = encodePretty' cfg treasuryInspectSchema
  where
    cfg =
        Config
            { confIndent = Spaces 4
            , confCompare = compare
            , confNumFormat = Generic
            , confTrailingNewline = True
            }

-- ----------------------------------------------------
-- Per-entity schemas
-- ----------------------------------------------------

outrefSchema :: Value
outrefSchema =
    objectSchema
        ["txId", "ix"]
        [ ("txId", ref "Hex32")
        ,
            ( "ix"
            , object
                [ "type" .= ("integer" :: Text)
                , "minimum" .= (0 :: Int)
                , "maximum" .= (65535 :: Int)
                ]
            )
        ]

chainTipSchema :: Value
chainTipSchema =
    objectSchema
        ["slot"]
        [
            ( "slot"
            , object
                [ "type" .= ("integer" :: Text)
                , "minimum" .= (0 :: Int)
                ]
            )
        ,
            ( "blockHash"
            , object
                [ "oneOf"
                    .= [ object ["type" .= ("null" :: Text)]
                       , ref "Hex32"
                       ]
                , "description"
                    .= ( "32-byte block hash; null when the \
                         \Backend cannot supply it (see \
                         \specs/109-treasury-inspect/research.md §R5)."
                            :: Text
                       )
                ]
            )
        ]

deploymentSchema :: Value
deploymentSchema =
    object
        [ "type" .= ("object" :: Text)
        , "additionalProperties" .= False
        , "required" .= (["scopeOwnersOutref"] :: [Text])
        , "properties"
            .= object
                [ "scopeOwnersOutref"
                    .= object
                        [ "$ref" .= ("#/$defs/Outref" :: Text)
                        , "description"
                            .= ( "The outref pinned in metadata.json's \
                                 \`scope_owners` field — the project's \
                                 \deployment-identity anchor. Different \
                                 \deployments have different values; \
                                 \surfacing this lets operators detect \
                                 \when they pointed inspect at the \
                                 \wrong metadata."
                                    :: Text
                               )
                        ]
                ]
        ]

scopeSectionSchema :: Value
scopeSectionSchema =
    objectSchema
        [ "scope"
        , "treasuryAddress"
        , "treasuryScriptHash"
        , "treasuryUtxos"
        , "totals"
        , "pendingOrders"
        ]
        [
            ( "scope"
            , enumTextSchema
                [ "core_development"
                , "ops_and_use_cases"
                , "network_compliance"
                , "middleware"
                , "contingency"
                ]
            )
        ,
            ( "treasuryAddress"
            , object
                [ "type" .= ("string" :: Text)
                , "description"
                    .= ( "Bech32-encoded scope contract address."
                            :: Text
                       )
                ]
            )
        , ("treasuryScriptHash", ref "Hex28")
        ,
            ( "treasuryUtxos"
            , object
                [ "type" .= ("array" :: Text)
                , "items" .= ref "TreasuryUtxo"
                ]
            )
        , ("totals", ref "ScopeTotals")
        ,
            ( "pendingOrders"
            , object
                [ "type" .= ("array" :: Text)
                , "items" .= ref "PendingSwapOrder"
                ]
            )
        ]

treasuryUtxoSchema :: Value
treasuryUtxoSchema =
    object
        [ "type" .= ("object" :: Text)
        , "additionalProperties" .= False
        , "required"
            .= ( ["outref", "lovelace", "usdm", "otherAssets"]
                    :: [Text]
               )
        , "properties"
            .= object
                [ "outref" .= ref "Outref"
                , "lovelace" .= nonNegInt
                , "usdm" .= nonNegInt
                , ( "otherAssets"
                        :: Key.Key
                  )
                    .= object
                        [ "type" .= ("array" :: Text)
                        , "items" .= ref "OtherAsset"
                        ]
                , ( "datumHash"
                        :: Key.Key
                  )
                    .= object
                        [ "oneOf"
                            .= [ object ["type" .= ("null" :: Text)]
                               , ref "Hex32"
                               ]
                        ]
                ]
        ]

scopeTotalsSchema :: Value
scopeTotalsSchema =
    objectSchema
        ["lovelace", "usdm", "otherAssetsCount"]
        [ ("lovelace", nonNegInt)
        , ("usdm", nonNegInt)
        , ("otherAssetsCount", nonNegInt)
        ]

otherAssetSchema :: Value
otherAssetSchema =
    objectSchema
        ["policy", "assetName", "quantity"]
        [ ("policy", ref "Hex28")
        ,
            ( "assetName"
            , object
                [ "type" .= ("string" :: Text)
                , "pattern" .= ("^[0-9a-f]*$" :: Text)
                , "description"
                    .= ( "Hex-encoded asset name bytes; empty string \
                         \for the unnamed token."
                            :: Text
                       )
                ]
            )
        ,
            ( "quantity"
            , object
                [ "type" .= ("integer" :: Text)
                , "minimum" .= (1 :: Int)
                ]
            )
        ]

pendingSwapOrderSchema :: Value
pendingSwapOrderSchema =
    objectSchema
        [ "outref"
        , "lovelaceIn"
        , "minUsdmOut"
        , "sundaeFeeLovelace"
        ]
        [ ("outref", ref "Outref")
        , ("lovelaceIn", nonNegInt)
        , ("minUsdmOut", nonNegInt)
        , ("sundaeFeeLovelace", nonNegInt)
        ]

-- ----------------------------------------------------
-- Shared building blocks
-- ----------------------------------------------------

nonNegInt :: Value
nonNegInt =
    object
        [ "type" .= ("integer" :: Text)
        , "minimum" .= (0 :: Int)
        ]

hexExact :: Int -> Value
hexExact bytes =
    object
        [ "type" .= ("string" :: Text)
        , "pattern"
            .= ("^[0-9a-f]{" <> showText (bytes * 2) <> "}$")
        , "description"
            .= ( showText bytes
                    <> "-byte value as "
                    <> showText (bytes * 2)
                    <> " lowercase hex characters."
               )
        ]

enumTextSchema :: [Text] -> Value
enumTextSchema values =
    object
        [ "type" .= ("string" :: Text)
        , "enum" .= values
        ]

objectSchema :: [Text] -> [(Text, Value)] -> Value
objectSchema required properties =
    object
        [ "type" .= ("object" :: Text)
        , "additionalProperties" .= False
        , "required" .= required
        , "properties" .= object (schemaPair <$> properties)
        ]

ref :: Text -> Value
ref name = object ["$ref" .= ("#/$defs/" <> name)]

schemaPair :: (Text, Value) -> Pair
schemaPair (k, v) = Key.fromText k .= v

showText :: Int -> Text
showText = Key.toText . Key.fromString . show
