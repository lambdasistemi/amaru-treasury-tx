{-# LANGUAGE OverloadedStrings #-}

module Amaru.Treasury.ReportSpec (spec) where

import Data.Aeson (Value (..), eitherDecode, object, toJSON, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy.Char8 qualified as BSL8
import Data.List (isInfixOf)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldSatisfy
    )

import Amaru.Treasury.Report
    ( MetadataSummary (..)
    , ProducedOutput (..)
    , ProducedOutputRole (..)
    , SignerRequirement (..)
    , SignerSource (..)
    , TransactionIdentity (..)
    , TransactionReport (..)
    , TreasuryAccounting (..)
    , UtxoSummary (..)
    , ValidationFacts (..)
    , ValidityInterval (..)
    , ValueSummary (..)
    , WalletAccounting (..)
    , buildTransactionReport
    , encodeReport
    )

spec :: Spec
spec = describe "Amaru.Treasury.Report" $ do
    it "encodes the foundational TransactionReport JSON shape" $
        decodedReport `shouldBe` Right expectedReport

    it "encodes TransactionIdentity facts under identity" $
        decodedReport
            `shouldSatisfy` hasField
                "identity"
                expectedIdentity

    it "encodes WalletAccounting with fee and net spend placeholders" $
        decodedReport
            `shouldSatisfy` hasField
                "walletAccounting"
                expectedWalletAccounting

    it
        "encodes TreasuryAccounting totals without deriving later semantics"
        $ decodedReport
            `shouldSatisfy` hasField
                "treasuryAccounting"
                expectedTreasuryAccounting

    it "encodes ProducedOutput role, address, value, and datum" $
        decodedReport
            `shouldSatisfy` hasField
                "outputs"
                (toJSON [expectedOutput])

    it "encodes SignerRequirement key hash, source, and optional scope" $
        decodedReport
            `shouldSatisfy` hasField
                "signers"
                (toJSON [expectedSigner])

    it "encodes ValidationFacts independently from later builder plumbing" $
        decodedReport
            `shouldSatisfy` hasField "validation" expectedValidation

    it "encodes with a trailing newline" $
        BSL8.last (encodeReport sampleReport) `shouldBe` '\n'

    it "keeps report bytes deterministic and host-independent" $ do
        let encoded = BSL8.unpack (encodeReport deterministicReport)
        encoded
            `shouldSatisfy` fieldsAppearInOrder
                [ "\"action\""
                , "\"identity\""
                , "\"metadata\""
                , "\"network\""
                , "\"outputs\""
                , "\"referenceInputs\""
                , "\"schema\""
                , "\"signers\""
                , "\"treasuryAccounting\""
                , "\"validation\""
                , "\"walletAccounting\""
                ]
        encoded
            `shouldSatisfy` fieldsAppearInOrder
                [ "\"aPolicy\""
                , "\"bPolicy\""
                ]
        encoded
            `shouldSatisfy` fieldsAppearInOrder
                [ "\"aAsset\""
                , "\"zAsset\""
                ]
        encoded `shouldSatisfy` isInfixOf "\"index\": 0"
        encoded `shouldSatisfy` isInfixOf "\"index\": 1"
        encoded `shouldSatisfy` (not . isInfixOf "timestamp")
        encoded `shouldSatisfy` (not . isInfixOf "path")
        BSL8.last (encodeReport deterministicReport) `shouldBe` '\n'

    it "exposes a pure report constructor for build results" $
        buildTransactionReport `seq`
            True
                `shouldBe` True

decodedReport :: Either String Value
decodedReport = eitherDecode (encodeReport sampleReport)

hasField :: String -> Value -> Either String Value -> Bool
hasField field expected (Right (Object obj)) =
    KM.lookup (Key.fromString field) obj == Just expected
hasField _ _ _ = False

sampleReport :: TransactionReport
sampleReport =
    TransactionReport
        { trSchema = 1
        , trAction = "swap"
        , trNetwork = "mainnet"
        , trIdentity = sampleIdentity
        , trWalletAccounting = sampleWalletAccounting
        , trTreasuryAccounting = sampleTreasuryAccounting
        , trOutputs =
            [ ProducedOutput
                { poIndex = 0
                , poRole = OutputUnknown
                , poAddress = "addr_test1..."
                , poValue = emptyValue
                , poDatum = Nothing
                }
            ]
        , trSigners =
            [ SignerRequirement
                { srKeyHash = sampleKeyHash
                , srSource = SourceExtraSigner
                , srScope = Nothing
                }
            ]
        , trValidation = sampleValidationFacts
        , trReferenceInputs = []
        , trMetadata =
            MetadataSummary
                { msAuxiliaryDataHash = Nothing
                , msCip1694LabelPresent = True
                }
        }

deterministicReport :: TransactionReport
deterministicReport =
    sampleReport
        { trOutputs =
            [ ProducedOutput
                { poIndex = 0
                , poRole = OutputUnknown
                , poAddress = "addr_test1first"
                , poValue =
                    ValueSummary
                        { vsLovelace = 2
                        , vsAssets =
                            Map.fromList
                                [
                                    ( "bPolicy"
                                    , Map.fromList
                                        [ ("zAsset", 9)
                                        , ("aAsset", 1)
                                        ]
                                    )
                                ,
                                    ( "aPolicy"
                                    , Map.singleton "onlyAsset" 3
                                    )
                                ]
                        }
                , poDatum = Nothing
                }
            , ProducedOutput
                { poIndex = 1
                , poRole = OutputUnknown
                , poAddress = "addr_test1second"
                , poValue = emptyValue
                , poDatum = Nothing
                }
            ]
        }

fieldsAppearInOrder :: [String] -> String -> Bool
fieldsAppearInOrder =
    go
  where
    go [] _ = True
    go (field : rest) input =
        case breakOn field input of
            Nothing -> False
            Just suffix -> go rest suffix

breakOn :: String -> String -> Maybe String
breakOn needle input
    | needle `isPrefixOf` input = Just (drop (length needle) input)
    | otherwise = case input of
        [] -> Nothing
        (_ : rest) -> breakOn needle rest

isPrefixOf :: String -> String -> Bool
isPrefixOf prefix input =
    take (length prefix) input == prefix

sampleIdentity :: TransactionIdentity
sampleIdentity =
    TransactionIdentity
        { tiTxId = sampleTxId
        , tiBodySizeBytes = 14954
        , tiFeeLovelace = 1039703
        , tiTotalCollateralLovelace = 1559555
        , tiValidityInterval = sampleValidityInterval
        }

sampleWalletAccounting :: WalletAccounting
sampleWalletAccounting =
    WalletAccounting
        { waInputs = [sampleUtxo]
        , waCollateralInput = Just sampleUtxo
        , waChangeOutput = Nothing
        , waCollateralReturn = Nothing
        , waFeeLovelace = 1039703
        , waNetSpendLovelace = 1039703
        }

sampleTreasuryAccounting :: TreasuryAccounting
sampleTreasuryAccounting =
    TreasuryAccounting
        { taInputs = []
        , taInputTotal = emptyValue
        , taSundaeOrderTotal = emptyValue
        , taPerChunkOverheadLovelace = 0
        , taTreasuryLeftover = emptyValue
        , taNetDebit = emptyValue
        }

sampleValidationFacts :: ValidationFacts
sampleValidationFacts =
    ValidationFacts
        { vfIntentNetwork = "mainnet"
        , vfSocketNetworkMagic = 764824073
        , vfNetworkMatches = True
        , vfFeeLovelace = 1039703
        , vfBodySizeBytes = 14954
        , vfRedeemerCount = 2
        , vfRedeemerFailures = 0
        , vfValidationStatus = "ok"
        , vfValidityInterval = sampleValidityInterval
        }

sampleUtxo :: UtxoSummary
sampleUtxo =
    UtxoSummary
        { usTxIn =
            "0000000000000000000000000000000000000000000000000000000000000000#0"
        , usValue = emptyValue
        }

emptyValue :: ValueSummary
emptyValue =
    ValueSummary
        { vsLovelace = 0
        , vsAssets = Map.empty
        }

sampleValidityInterval :: ValidityInterval
sampleValidityInterval =
    ValidityInterval
        { viInvalidBefore = Nothing
        , viInvalidHereafter = Just 186796799
        }

expectedReport :: Value
expectedReport =
    object
        [ "schema" .= (1 :: Int)
        , "action" .= ("swap" :: String)
        , "network" .= ("mainnet" :: String)
        , "identity" .= expectedIdentity
        , "walletAccounting" .= expectedWalletAccounting
        , "treasuryAccounting" .= expectedTreasuryAccounting
        , "outputs" .= [expectedOutput]
        , "signers" .= [expectedSigner]
        , "validation" .= expectedValidation
        , "referenceInputs" .= ([] :: [Value])
        , "metadata" .= expectedMetadata
        ]

expectedIdentity :: Value
expectedIdentity =
    object
        [ "txId" .= sampleTxId
        , "bodySizeBytes" .= (14954 :: Int)
        , "feeLovelace" .= (1039703 :: Int)
        , "totalCollateralLovelace" .= (1559555 :: Int)
        , "validityInterval" .= expectedValidityInterval
        ]

expectedWalletAccounting :: Value
expectedWalletAccounting =
    object
        [ "inputs" .= [expectedUtxo]
        , "collateralInput" .= Just expectedUtxo
        , "changeOutput" .= (Nothing :: Maybe Value)
        , "collateralReturn" .= (Nothing :: Maybe Value)
        , "feeLovelace" .= (1039703 :: Int)
        , "netSpendLovelace" .= (1039703 :: Int)
        ]

expectedTreasuryAccounting :: Value
expectedTreasuryAccounting =
    object
        [ "inputs" .= ([] :: [Value])
        , "inputTotal" .= expectedValue
        , "sundaeOrderTotal" .= expectedValue
        , "perChunkOverheadLovelace" .= (0 :: Int)
        , "treasuryLeftover" .= expectedValue
        , "netDebit" .= expectedValue
        ]

expectedOutput :: Value
expectedOutput =
    object
        [ "index" .= (0 :: Int)
        , "role" .= ("unknown" :: String)
        , "address" .= ("addr_test1..." :: String)
        , "value" .= expectedValue
        , "datum" .= (Nothing :: Maybe Value)
        ]

expectedSigner :: Value
expectedSigner =
    object
        [ "keyHash" .= sampleKeyHash
        , "source" .= ("extraSigner" :: String)
        , "scope" .= (Nothing :: Maybe Value)
        ]

expectedValidation :: Value
expectedValidation =
    object
        [ "intentNetwork" .= ("mainnet" :: String)
        , "socketNetworkMagic" .= (764824073 :: Int)
        , "networkMatches" .= True
        , "feeLovelace" .= (1039703 :: Int)
        , "bodySizeBytes" .= (14954 :: Int)
        , "redeemerCount" .= (2 :: Int)
        , "redeemerFailures" .= (0 :: Int)
        , "validationStatus" .= ("ok" :: String)
        , "validityInterval" .= expectedValidityInterval
        ]

expectedMetadata :: Value
expectedMetadata =
    object
        [ "auxiliaryDataHash" .= (Nothing :: Maybe Value)
        , "cip1694LabelPresent" .= True
        ]

expectedUtxo :: Value
expectedUtxo =
    object
        [ "txIn"
            .= ( "0000000000000000000000000000000000000000000000000000000000000000#0"
                    :: String
               )
        , "value" .= expectedValue
        ]

expectedValue :: Value
expectedValue =
    object
        [ "lovelace" .= (0 :: Int)
        , "assets" .= object []
        ]

expectedValidityInterval :: Value
expectedValidityInterval =
    object
        [ "invalidBefore" .= (Nothing :: Maybe Value)
        , "invalidHereafter" .= Just (186796799 :: Int)
        ]

sampleTxId :: Text
sampleTxId =
    "0000000000000000000000000000000000000000000000000000000000000000"

sampleKeyHash :: Text
sampleKeyHash =
    "11111111111111111111111111111111111111111111111111111111"
