{-# LANGUAGE OverloadedStrings #-}

module Amaru.Treasury.Report.Schema
    ( encodeTxReportJsonSchema
    , txReportJsonSchema
    ) where

import Data.Aeson (Value, object, (.=))
import Data.Aeson.Encode.Pretty
    ( Config (..)
    , Indent (..)
    , NumberFormat (..)
    , encodePretty'
    )
import Data.Aeson.Types (Pair)
import Data.ByteString.Lazy (ByteString)
import Data.Text (Text)

txReportJsonSchema :: Value
txReportJsonSchema =
    object
        [ "$schema"
            .= ("https://json-schema.org/draft/2020-12/schema" :: Text)
        , "$id"
            .= ( "https://github.com/lambdasistemi/amaru-treasury-tx/schemas/tx-report-v1.json"
                    :: Text
               )
        , "title" .= ("Amaru Treasury Transaction Build Output JSON" :: Text)
        , "type" .= ("object" :: Text)
        , "required"
            .= [ "intent" :: Text
               , "result"
               ]
        , "properties"
            .= object
                [ "intent" .= object ["type" .= ("object" :: Text)]
                , "result" .= ref "txBuildOutputResult"
                ]
        , "additionalProperties" .= False
        , "$defs"
            .= object
                [ "txBuildOutputResult" .= txBuildOutputResultSchema
                , "txBuildSuccess" .= txBuildSuccessSchema
                , "buildFailure" .= buildFailureSchema
                , "transactionReport" .= transactionReportSchema
                , "transactionIdentity" .= transactionIdentitySchema
                , "walletAccounting" .= walletAccountingSchema
                , "treasuryAccounting" .= treasuryAccountingSchema
                , "producedOutput" .= producedOutputSchema
                , "signerRequirement" .= signerRequirementSchema
                , "validationFacts" .= validationFactsSchema
                , "validityInterval" .= validityIntervalSchema
                , "utxoSummary" .= utxoSummarySchema
                , "valueSummary" .= valueSummarySchema
                , "metadataSummary" .= metadataSummarySchema
                ]
        ]

encodeTxReportJsonSchema :: ByteString
encodeTxReportJsonSchema = encodePretty' schemaJsonConfig txReportJsonSchema

txBuildOutputResultSchema :: Value
txBuildOutputResultSchema =
    object
        [ "anyOf"
            .= [ ref "txBuildSuccess"
               , objectSchema ["failure"] [("failure", ref "buildFailure")]
               ]
        ]

txBuildSuccessSchema :: Value
txBuildSuccessSchema =
    objectSchema
        ["tx-cbor", "report"]
        [ ("tx-cbor", txCborHexSchema)
        , ("report", ref "transactionReport")
        ]

buildFailureSchema :: Value
buildFailureSchema =
    objectSchema
        ["code", "message"]
        [ ("code", stringSchema)
        , ("message", stringSchema)
        ]

transactionReportSchema :: Value
transactionReportSchema =
    objectSchema
        [ "schema"
        , "network"
        , "identity"
        , "walletAccounting"
        , "treasuryAccounting"
        , "outputs"
        , "signers"
        , "validation"
        , "referenceInputs"
        , "metadata"
        ]
        [ ("schema", constInteger 1)
        , ("network", stringSchema)
        , ("identity", ref "transactionIdentity")
        , ("walletAccounting", ref "walletAccounting")
        , ("treasuryAccounting", ref "treasuryAccounting")
        , ("outputs", arrayOf (ref "producedOutput"))
        , ("signers", arrayOf (ref "signerRequirement"))
        , ("validation", ref "validationFacts")
        , ("referenceInputs", arrayOf stringSchema)
        , ("metadata", ref "metadataSummary")
        ]

transactionIdentitySchema :: Value
transactionIdentitySchema =
    objectSchema
        [ "txId"
        , "bodySizeBytes"
        , "feeLovelace"
        , "totalCollateralLovelace"
        , "validityInterval"
        ]
        [ ("txId", stringSchema)
        , ("bodySizeBytes", nonNegativeIntegerSchema)
        , ("feeLovelace", nonNegativeIntegerSchema)
        , ("totalCollateralLovelace", nonNegativeIntegerSchema)
        , ("validityInterval", ref "validityInterval")
        ]

walletAccountingSchema :: Value
walletAccountingSchema =
    objectSchema
        [ "inputs"
        , "collateralInput"
        , "changeOutput"
        , "collateralReturn"
        , "feeLovelace"
        , "withdrawalLovelace"
        , "netSpendLovelace"
        ]
        [ ("inputs", arrayOf (ref "utxoSummary"))
        , ("collateralInput", nullable (ref "utxoSummary"))
        , ("changeOutput", nullable (ref "utxoSummary"))
        , ("collateralReturn", nullable (ref "utxoSummary"))
        , ("feeLovelace", nonNegativeIntegerSchema)
        , ("withdrawalLovelace", nonNegativeIntegerSchema)
        , ("netSpendLovelace", nonNegativeIntegerSchema)
        ]

treasuryAccountingSchema :: Value
treasuryAccountingSchema =
    objectSchema
        [ "inputs"
        , "inputTotal"
        , "sundaeOrderTotal"
        , "perChunkOverheadLovelace"
        , "treasuryLeftover"
        , "netDebit"
        ]
        [ ("inputs", arrayOf (ref "utxoSummary"))
        , ("inputTotal", ref "valueSummary")
        , ("sundaeOrderTotal", ref "valueSummary")
        , ("perChunkOverheadLovelace", nonNegativeIntegerSchema)
        , ("treasuryLeftover", ref "valueSummary")
        , ("netDebit", ref "valueSummary")
        ]

producedOutputSchema :: Value
producedOutputSchema =
    objectSchema
        ["index", "role", "address", "value", "datum"]
        [ ("index", nonNegativeIntegerSchema)
        ,
            ( "role"
            , enumTextSchema
                [ "swapOrder"
                , "treasuryLeftover"
                , "walletChange"
                , "collateralReturn"
                , "metadata"
                , "unknown"
                ]
            )
        , ("address", stringSchema)
        , ("value", ref "valueSummary")
        , ("datum", nullable stringSchema)
        ]

signerRequirementSchema :: Value
signerRequirementSchema =
    objectSchema
        ["keyHash", "source", "scope"]
        [ ("keyHash", stringSchema)
        ,
            ( "source"
            , enumTextSchema
                [ "selectedScopeOwner"
                , "extraSigner"
                , "intentRequiredSigner"
                , "txBodyRequiredSigner"
                ]
            )
        , ("scope", nullable stringSchema)
        ]

validationFactsSchema :: Value
validationFactsSchema =
    objectSchema
        [ "intentNetwork"
        , "socketNetworkMagic"
        , "networkMatches"
        , "feeLovelace"
        , "bodySizeBytes"
        , "redeemerCount"
        , "redeemerFailures"
        , "validationStatus"
        , "validityInterval"
        ]
        [ ("intentNetwork", stringSchema)
        , ("socketNetworkMagic", nonNegativeIntegerSchema)
        , ("networkMatches", booleanSchema)
        , ("feeLovelace", nonNegativeIntegerSchema)
        , ("bodySizeBytes", nonNegativeIntegerSchema)
        , ("redeemerCount", nonNegativeIntegerSchema)
        , ("redeemerFailures", nonNegativeIntegerSchema)
        , ("validationStatus", stringSchema)
        , ("validityInterval", ref "validityInterval")
        ]

validityIntervalSchema :: Value
validityIntervalSchema =
    objectSchema
        ["invalidBefore", "invalidHereafter"]
        [ ("invalidBefore", nullable nonNegativeIntegerSchema)
        , ("invalidHereafter", nullable nonNegativeIntegerSchema)
        ]

utxoSummarySchema :: Value
utxoSummarySchema =
    objectSchema
        ["txIn", "value"]
        [ ("txIn", stringSchema)
        , ("value", ref "valueSummary")
        ]

valueSummarySchema :: Value
valueSummarySchema =
    objectSchema
        ["lovelace", "assets"]
        [ ("lovelace", nonNegativeIntegerSchema)
        ,
            ( "assets"
            , object
                [ "type" .= ("object" :: Text)
                , "additionalProperties"
                    .= object
                        [ "type" .= ("object" :: Text)
                        , "additionalProperties"
                            .= nonNegativeIntegerSchema
                        ]
                ]
            )
        ]

metadataSummarySchema :: Value
metadataSummarySchema =
    objectSchema
        ["auxiliaryDataHash", "cip1694LabelPresent"]
        [ ("auxiliaryDataHash", nullable stringSchema)
        , ("cip1694LabelPresent", booleanSchema)
        ]

objectSchema :: [Text] -> [Pair] -> Value
objectSchema requiredFields properties =
    object
        [ "type" .= ("object" :: Text)
        , "required" .= requiredFields
        , "properties" .= object properties
        , "additionalProperties" .= False
        ]

nullable :: Value -> Value
nullable schema =
    object
        [ "anyOf"
            .= [ schema
               , object ["type" .= ("null" :: Text)]
               ]
        ]

arrayOf :: Value -> Value
arrayOf items =
    object
        [ "type" .= ("array" :: Text)
        , "items" .= items
        ]

ref :: Text -> Value
ref name =
    object ["$ref" .= ("#/$defs/" <> name)]

constInteger :: Int -> Value
constInteger n =
    object
        [ "type" .= ("integer" :: Text)
        , "const" .= n
        ]

enumTextSchema :: [Text] -> Value
enumTextSchema values =
    object
        [ "type" .= ("string" :: Text)
        , "enum" .= values
        ]

stringSchema :: Value
stringSchema = object ["type" .= ("string" :: Text)]

txCborHexSchema :: Value
txCborHexSchema =
    object
        [ "type" .= ("string" :: Text)
        , "minLength" .= (2 :: Int)
        , "pattern" .= ("^([0-9a-f]{2})+$" :: Text)
        ]

booleanSchema :: Value
booleanSchema = object ["type" .= ("boolean" :: Text)]

nonNegativeIntegerSchema :: Value
nonNegativeIntegerSchema =
    object
        [ "type" .= ("integer" :: Text)
        , "minimum" .= (0 :: Int)
        ]

schemaJsonConfig :: Config
schemaJsonConfig =
    Config
        { confIndent = Spaces 4
        , confCompare = compare
        , confNumFormat = Generic
        , confTrailingNewline = True
        }
