{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.IntentJSON.Schema
Description : JSON Schema for the unified TreasuryIntent contract
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Defines the generated JSON Schema 2020-12 document for the
unified @intent.json@ contract consumed by @tx-build@ and
emitted by treasury wizards.
-}
module Amaru.Treasury.IntentJSON.Schema
    ( intentJsonSchema
    , encodeIntentJsonSchema
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
import Data.Text qualified as T

import Amaru.Treasury.IntentJSON (allowedSchemas)

-- | JSON Schema 2020-12 for @TreasuryIntent@ schema v1.
intentJsonSchema :: Value
intentJsonSchema =
    object
        [ "$schema"
            .= ("https://json-schema.org/draft/2020-12/schema" :: Text)
        , "$id"
            .= ( "https://github.com/lambdasistemi/amaru-treasury-tx/schemas/treasury-intent-v1.json"
                    :: Text
               )
        , "title" .= ("Amaru TreasuryIntent JSON" :: Text)
        , "description"
            .= ( "Unified intent JSON contract emitted by treasury wizards and consumed by tx-build."
                    :: Text
               )
        , "oneOf"
            .= [ actionSchema "swap" "swap" (ref "swap")
               , actionSchema "disburse" "disburse" (ref "disburse")
               , actionSchema "withdraw" "withdraw" (ref "withdraw")
               , actionSchema
                    "reorganize"
                    "reorganize"
                    (ref "reorganize")
               , actionSchema
                    "registry-init-seed-split"
                    "registry-init-seed-split"
                    (ref "registry-init-seed-split")
               , actionSchema
                    "registry-init-mint"
                    "registry-init-mint"
                    (ref "registry-init-mint")
               , actionSchema
                    "registry-init-reference-scripts"
                    "registry-init-reference-scripts"
                    (ref "registry-init-reference-scripts")
               , actionSchema
                    "stake-reward-init-script-account"
                    "stake-reward-init-script-account"
                    (ref "stake-reward-init-script-account")
               , actionSchema
                    "stake-reward-init-plain-account"
                    "stake-reward-init-plain-account"
                    (ref "stake-reward-init-plain-account")
               , actionSchema
                    "governance-withdrawal-init-proposal"
                    "governance-withdrawal-init-proposal"
                    (ref "governance-withdrawal-init-proposal")
               , actionSchema
                    "governance-withdrawal-init-materialization"
                    "governance-withdrawal-init-materialization"
                    (ref "governance-withdrawal-init-materialization")
               ]
        , "$defs"
            .= object
                [ "wallet" .= walletSchema
                , "scope" .= scopeSchema
                , "assetMap" .= assetMapSchema
                , "rationale" .= rationaleSchema
                , "swap" .= swapSchema
                , "disburse" .= disburseSchema
                , "withdraw" .= withdrawSchema
                , "reorganize" .= reorganizeSchema
                , "registry-init-seed-split"
                    .= registryInitSeedSplitSchema
                , "registry-init-mint"
                    .= registryInitMintSchema
                , "registry-init-reference-scripts"
                    .= registryInitReferenceScriptsSchema
                , "stake-reward-init-script-account"
                    .= stakeRewardInitScriptAccountSchema
                , "stake-reward-init-plain-account"
                    .= stakeRewardInitPlainAccountSchema
                , "governance-withdrawal-init-proposal"
                    .= governanceWithdrawalInitProposalSchema
                , "governance-withdrawal-init-materialization"
                    .= governanceWithdrawalInitMaterializationSchema
                , "txIn" .= txInSchema
                , "bech32Address" .= bech32AddressSchema
                , "rewardAccount" .= rewardAccountSchema
                , "hex28" .= hexBytesSchema 28
                , "hex32" .= hexBytesSchema 32
                , "assetNameHex" .= assetNameHexSchema
                ]
        ]

-- | Stable pretty-printed encoding for the schema asset.
encodeIntentJsonSchema :: ByteString
encodeIntentJsonSchema = encodePretty' cfg intentJsonSchema
  where
    cfg =
        Config
            { confIndent = Spaces 4
            , confCompare = compare
            , confNumFormat = Generic
            , confTrailingNewline = True
            }

actionSchema :: Text -> Text -> Value -> Value
actionSchema actionName payloadKey payloadSchema =
    objectSchema
        (commonRequired <> [payloadKey])
        ( [ ("schema", schemaVersionSchema)
          , ("action", constStringSchema actionName)
          ,
              ( "network"
              , enumTextSchema
                    ["devnet", "mainnet", "preprod", "preview"]
              )
          , ("wallet", ref "wallet")
          , ("scope", ref "scope")
          , ("signers", arrayOf (ref "hex28"))
          , ("validityUpperBoundSlot", nonNegativeIntegerSchema)
          , ("rationale", ref "rationale")
          ]
            <> [(payloadKey, payloadSchema)]
        )

commonRequired :: [Text]
commonRequired =
    [ "schema"
    , "action"
    , "network"
    , "wallet"
    , "scope"
    , "signers"
    , "validityUpperBoundSlot"
    , "rationale"
    ]

walletSchema :: Value
walletSchema =
    objectSchema
        ["txIn", "address"]
        [ ("txIn", ref "txIn")
        , ("address", ref "bech32Address")
        , ("extraTxIns", arrayOf (ref "txIn"))
        ]

scopeSchema :: Value
scopeSchema =
    objectSchema
        [ "id"
        , "treasuryAddress"
        , "treasuryUtxos"
        , "treasuryLeftoverLovelace"
        , "treasuryLeftoverUsdm"
        , "treasuryLeftoverOtherAssets"
        , "treasuryScriptHash"
        , "permissionsRewardAccount"
        , "scopesDeployedAt"
        , "permissionsDeployedAt"
        , "treasuryDeployedAt"
        , "registryDeployedAt"
        , "registryPolicyId"
        ]
        [
            ( "id"
            , enumTextSchema
                [ "core_development"
                , "ops_and_use_cases"
                , "network_compliance"
                , "middleware"
                , "contingency"
                ]
            )
        , ("treasuryAddress", ref "bech32Address")
        , ("treasuryUtxos", arrayOf (ref "txIn"))
        , ("treasuryLeftoverLovelace", nonNegativeIntegerSchema)
        , ("treasuryLeftoverUsdm", nonNegativeIntegerSchema)
        , ("treasuryLeftoverOtherAssets", ref "assetMap")
        , ("treasuryScriptHash", ref "hex28")
        , ("permissionsRewardAccount", ref "hex28")
        , ("scopesDeployedAt", ref "txIn")
        , ("permissionsDeployedAt", ref "txIn")
        , ("treasuryDeployedAt", ref "txIn")
        , ("registryDeployedAt", ref "txIn")
        , ("registryPolicyId", ref "hex28")
        ]

assetMapSchema :: Value
assetMapSchema =
    object
        [ "type" .= ("object" :: Text)
        , "propertyNames" .= ref "hex28"
        , "additionalProperties"
            .= object
                [ "type" .= ("object" :: Text)
                , "propertyNames" .= ref "assetNameHex"
                , "additionalProperties" .= nonNegativeIntegerSchema
                ]
        ]

rationaleSchema :: Value
rationaleSchema =
    objectSchema
        [ "event"
        , "label"
        , "description"
        , "justification"
        , "destinationLabel"
        ]
        [ ("event", stringSchema)
        , ("label", stringSchema)
        , ("description", stringSchema)
        , ("justification", stringSchema)
        , ("destinationLabel", stringSchema)
        , ("references", referencesSchema)
        ]

referencesSchema :: Value
referencesSchema =
    object
        [ "type" .= ("array" :: Text)
        , "default" .= ([] :: [Value])
        , "items" .= referenceItemSchema
        ]

referenceItemSchema :: Value
referenceItemSchema =
    object
        [ "type" .= ("object" :: Text)
        , "required" .= (["uri", "label"] :: [Text])
        , "properties"
            .= object
                [ "uri"
                    .= boundedStringSchema
                        1
                        256
                        Nothing
                        "Full URI of the reference document (e.g. ipfs://<CID>, https://..., ar://...). Chunked per the metadatum 64-byte cap at serialisation time."
                , "@type"
                    .= boundedStringSchema
                        1
                        64
                        (Just "Other")
                        "SundaeSwap reference type. Default 'Other'."
                , "label"
                    .= boundedStringSchema
                        1
                        256
                        Nothing
                        "Human-readable label. Literal ' - ' marks the split for the on-chain Metadatum 3-chunk shape."
                ]
        , "additionalProperties" .= False
        ]

boundedStringSchema :: Int -> Int -> Maybe Text -> Text -> Value
boundedStringSchema lo hi mDefault description =
    object $
        [ "type" .= ("string" :: Text)
        , "minLength" .= lo
        , "maxLength" .= hi
        , "description" .= description
        ]
            <> case mDefault of
                Just d -> ["default" .= d]
                Nothing -> []

swapSchema :: Value
swapSchema =
    objectSchema
        [ "swapOrderAddress"
        , "chunkSizeLovelace"
        , "amountLovelace"
        , "extraPerChunkLovelace"
        , "rateNumerator"
        , "rateDenominator"
        , "poolId"
        , "coreOwner"
        , "opsOwner"
        , "networkComplianceOwner"
        , "middlewareOwner"
        , "sundaeProtocolFeeLovelace"
        , "usdmPolicy"
        , "usdmToken"
        ]
        [ ("swapOrderAddress", ref "bech32Address")
        , ("chunkSizeLovelace", positiveIntegerSchema)
        , ("amountLovelace", positiveIntegerSchema)
        , ("extraPerChunkLovelace", nonNegativeIntegerSchema)
        , ("rateNumerator", positiveIntegerSchema)
        , ("rateDenominator", positiveIntegerSchema)
        , ("poolId", ref "hex28")
        , ("coreOwner", ref "hex28")
        , ("opsOwner", ref "hex28")
        , ("networkComplianceOwner", ref "hex28")
        , ("middlewareOwner", ref "hex28")
        , ("sundaeProtocolFeeLovelace", nonNegativeIntegerSchema)
        , ("usdmPolicy", ref "hex28")
        , ("usdmToken", ref "assetNameHex")
        ]

disburseSchema :: Value
disburseSchema =
    objectSchema
        [ "unit"
        , "amount"
        , "beneficiaryAddress"
        , "usdmPolicy"
        , "usdmToken"
        ]
        [ ("unit", enumTextSchema ["ada", "usdm"])
        , ("amount", positiveIntegerSchema)
        , ("beneficiaryAddress", ref "bech32Address")
        , ("usdmPolicy", ref "hex28")
        , ("usdmToken", ref "assetNameHex")
        ]

withdrawSchema :: Value
withdrawSchema =
    objectSchema
        [ "treasuryRewardAccount"
        , "rewardsLovelace"
        ]
        [ ("treasuryRewardAccount", ref "hex28")
        , ("rewardsLovelace", positiveIntegerSchema)
        ]

reorganizeSchema :: Value
reorganizeSchema =
    objectSchema
        [ "walletUtxo"
        , "treasuryUtxos"
        , "treasuryAddress"
        , "treasuryDeployedAt"
        , "registryDeployedAt"
        , "permissionsRewardAccount"
        , "permissionsDeployedAt"
        , "scopeOwnerSigner"
        , "upperBound"
        ]
        [ ("walletUtxo", ref "txIn")
        , ("treasuryUtxos", nonEmptyArrayOf (ref "txIn"))
        , ("treasuryAddress", ref "bech32Address")
        , ("treasuryDeployedAt", ref "txIn")
        , ("registryDeployedAt", ref "txIn")
        , ("permissionsRewardAccount", ref "rewardAccount")
        , ("permissionsDeployedAt", ref "txIn")
        , ("scopeOwnerSigner", ref "hex28")
        , ("upperBound", nonNegativeIntegerSchema)
        ]

emptyPayloadSchema :: Value
emptyPayloadSchema = objectSchema [] []

registryInitSeedSplitSchema :: Value
registryInitSeedSplitSchema = emptyPayloadSchema

registryInitMintSchema :: Value
registryInitMintSchema =
    objectSchema
        [ "scopesSeedTxIn"
        , "registrySeedTxIn"
        , "ownerKeyHash"
        ]
        [ ("scopesSeedTxIn", ref "txIn")
        , ("registrySeedTxIn", ref "txIn")
        , ("ownerKeyHash", ref "hex28")
        ]

registryInitReferenceScriptsSchema :: Value
registryInitReferenceScriptsSchema =
    objectSchema
        [ "scopesSeedTxIn"
        , "registrySeedTxIn"
        ]
        [ ("scopesSeedTxIn", ref "txIn")
        , ("registrySeedTxIn", ref "txIn")
        ]

stakeRewardInitScriptAccountSchema :: Value
stakeRewardInitScriptAccountSchema =
    objectSchema
        [ "treasuryRefTxIn"
        , "treasuryScriptHash"
        ]
        [ ("treasuryRefTxIn", ref "txIn")
        , ("treasuryScriptHash", ref "hex28")
        ]

stakeRewardInitPlainAccountSchema :: Value
stakeRewardInitPlainAccountSchema =
    objectSchema
        [ "permissionsScriptHash"
        ]
        [ ("permissionsScriptHash", ref "hex28")
        ]

governanceWithdrawalInitProposalSchema :: Value
governanceWithdrawalInitProposalSchema =
    objectSchema
        [ "treasuryRewardAccountHash"
        , "withdrawalAmountLovelace"
        , "fundingStakeKeyHash"
        , "voterKeyHash"
        , "anchorUrl"
        , "anchorHash"
        ]
        [ ("treasuryRewardAccountHash", ref "hex28")
        ,
            ( "withdrawalAmountLovelace"
            , positiveIntegerSchema
            )
        , ("fundingStakeKeyHash", ref "hex28")
        , ("voterKeyHash", ref "hex28")
        , ("anchorUrl", anchorUrlSchema)
        , ("anchorHash", ref "hex32")
        ]

governanceWithdrawalInitMaterializationSchema :: Value
governanceWithdrawalInitMaterializationSchema =
    objectSchema
        [ "treasuryRewardAccountHash"
        , "treasuryAddress"
        , "treasuryRefTxIn"
        , "registryRefTxIn"
        , "rewardsLovelace"
        ]
        [ ("treasuryRewardAccountHash", ref "hex28")
        , ("treasuryAddress", ref "bech32Address")
        , ("treasuryRefTxIn", ref "txIn")
        , ("registryRefTxIn", ref "txIn")
        , ("rewardsLovelace", positiveIntegerSchema)
        ]

anchorUrlSchema :: Value
anchorUrlSchema =
    object
        [ "type" .= ("string" :: Text)
        , "minLength" .= (1 :: Int)
        , "maxLength" .= (128 :: Int)
        ]

schemaVersionSchema :: Value
schemaVersionSchema =
    object
        [ "type" .= ("integer" :: Text)
        , "enum" .= allowedSchemas
        ]

txInSchema :: Value
txInSchema =
    object
        [ "type" .= ("string" :: Text)
        , "pattern" .= ("^[0-9a-fA-F]{64}#[0-9]+$" :: Text)
        ]

bech32AddressSchema :: Value
bech32AddressSchema =
    object
        [ "type" .= ("string" :: Text)
        , "pattern" .= ("^addr(_test)?1[0-9a-z]+$" :: Text)
        ]

rewardAccountSchema :: Value
rewardAccountSchema =
    object
        [ "type" .= ("string" :: Text)
        , "pattern" .= ("^stake(_test)?1[0-9a-z]+$" :: Text)
        ]

assetNameHexSchema :: Value
assetNameHexSchema =
    object
        [ "type" .= ("string" :: Text)
        , "pattern" .= ("^([0-9a-fA-F]{2})*$" :: Text)
        ]

hexBytesSchema :: Int -> Value
hexBytesSchema bytes =
    object
        [ "type" .= ("string" :: Text)
        , "pattern"
            .= ( "^([0-9a-fA-F]{"
                    <> showText (bytes * 2)
                    <> "})$"
               )
        ]

stringSchema :: Value
stringSchema = object ["type" .= ("string" :: Text)]

positiveIntegerSchema :: Value
positiveIntegerSchema =
    object
        [ "type" .= ("integer" :: Text)
        , "minimum" .= (1 :: Int)
        ]

nonNegativeIntegerSchema :: Value
nonNegativeIntegerSchema =
    object
        [ "type" .= ("integer" :: Text)
        , "minimum" .= (0 :: Int)
        ]

arrayOf :: Value -> Value
arrayOf itemSchema =
    object
        [ "type" .= ("array" :: Text)
        , "items" .= itemSchema
        ]

nonEmptyArrayOf :: Value -> Value
nonEmptyArrayOf itemSchema =
    object
        [ "type" .= ("array" :: Text)
        , "minItems" .= (1 :: Int)
        , "items" .= itemSchema
        ]

enumTextSchema :: [Text] -> Value
enumTextSchema values =
    object
        [ "type" .= ("string" :: Text)
        , "enum" .= values
        ]

constStringSchema :: Text -> Value
constStringSchema value =
    object
        [ "type" .= ("string" :: Text)
        , "const" .= value
        ]

objectSchema :: [Text] -> [(Text, Value)] -> Value
objectSchema required properties =
    object
        [ "type" .= ("object" :: Text)
        , "required" .= required
        , "properties" .= object (schemaPair <$> properties)
        , "additionalProperties" .= False
        ]

ref :: Text -> Value
ref name =
    object
        [ "$ref" .= ("#/$defs/" <> name)
        ]

schemaPair :: (Text, Value) -> Pair
schemaPair (key, value) = Key.fromText key .= value

showText :: (Show a) => a -> Text
showText = T.pack . show
