{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Amaru.Treasury.ReportSpec (spec) where

import Data.Aeson
    ( Value (..)
    , eitherDecode
    , encode
    , object
    , toJSON
    , (.=)
    )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy.Char8 qualified as BSL8
import Data.Either (isLeft)
import Data.List (isInfixOf)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldSatisfy
    )

import Amaru.Treasury.Build (runFromIntent)
import Amaru.Treasury.ChainContext.Fixture
    ( readSwapFixture
    , toFrozenContext
    )
import Amaru.Treasury.IntentJSON
    ( SomeTreasuryIntent
    , decodeTreasuryIntentFile
    )
import Amaru.Treasury.Report
    ( BuildFailure (..)
    , MetadataSummary (..)
    , ProducedOutput (..)
    , ProducedOutputRole (..)
    , ReportContext (..)
    , SignerRequirement (..)
    , SignerSource (..)
    , TransactionIdentity (..)
    , TransactionReport (..)
    , TreasuryAccounting (..)
    , TxBuildOutput (..)
    , TxBuildOutputResult (..)
    , TxBuildSuccess (..)
    , TxCborHex (..)
    , UtxoSummary (..)
    , ValidationFacts (..)
    , ValidityInterval (..)
    , ValueSummary (..)
    , WalletAccounting (..)
    , buildTransactionReport
    , encodeBuildOutput
    , encodeReport
    )
import Amaru.Treasury.Report.Accounting
    ( addValueSummary
    , sumValueSummaries
    , treasuryNetDebit
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

    it "encodes and decodes a tx-build success envelope" $ do
        some <- sampleIntent
        let output = sampleBuildOutput some
            decoded = eitherDecode (encodeBuildOutput output)
            decodedValue = eitherDecode (encodeBuildOutput output)
            expectedResult =
                object
                    [ "tx-cbor" .= ("84a4" :: Text)
                    , "report" .= expectedReport
                    ]
        decoded `shouldBe` Right output
        decodedValue `shouldSatisfy` hasField "intent" (toJSON some)
        decodedValue `shouldSatisfy` hasField "result" expectedResult
        BSL8.last (encodeBuildOutput output) `shouldBe` '\n'

    it "encodes failure envelopes without tx-cbor or report" $ do
        some <- sampleIntent
        let output =
                TxBuildOutput
                    { txoIntent = some
                    , txoResult =
                        TxBuildOutputFailure
                            BuildFailure
                                { bfCode = "validation-failed"
                                , bfMessage = "script validation failed"
                                }
                    }
            expectedResult =
                object
                    [ "failure"
                        .= object
                            [ "code" .= ("validation-failed" :: Text)
                            , "message"
                                .= ( "script validation failed"
                                        :: Text
                                   )
                            ]
                    ]
        eitherDecode (encodeBuildOutput output) `shouldBe` Right output
        eitherDecode (encodeBuildOutput output)
            `shouldSatisfy` hasField "result" expectedResult

    it "rejects malformed tx-cbor in success envelopes" $ do
        some <- sampleIntent
        let bad =
                object
                    [ "intent" .= some
                    , "result"
                        .= object
                            [ "tx-cbor" .= ("84A4" :: Text)
                            , "report" .= sampleReport
                            ]
                    ]
        (eitherDecode (encode bad) :: Either String TxBuildOutput)
            `shouldSatisfy` isLeft

    it "rejects nested report transaction-type duplication" $ do
        some <- sampleIntent
        let bad =
                object
                    [ "intent" .= some
                    , "result"
                        .= object
                            [ "tx-cbor" .= ("84a4" :: Text)
                            , "report" .= reportWithAction
                            ]
                    ]
        (eitherDecode (encode bad) :: Either String TxBuildOutput)
            `shouldSatisfy` isLeft

    it "keeps report bytes deterministic and host-independent" $ do
        let encoded = BSL8.unpack (encodeReport deterministicReport)
        encoded
            `shouldSatisfy` fieldsAppearInOrder
                [ "\"identity\""
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

    it
        "accounts for swap wallet fuel, change, and collateral without double-counting"
        $ do
            report <- buildSwapFixtureReport
            let wallet = trWalletAccounting report
            waInputs wallet `shouldSatisfy` (not . null)
            waCollateralInput wallet `shouldSatisfy` isJust
            waChangeOutput wallet `shouldSatisfy` isJust
            waCollateralReturn wallet `shouldSatisfy` isJust
            waFeeLovelace wallet
                `shouldBe` vfFeeLovelace (trValidation report)
            tiTotalCollateralLovelace (trIdentity report)
                `shouldSatisfy` (> 0)
            waNetSpendLovelace wallet
                `shouldBe` vfFeeLovelace (trValidation report)

    it
        "accounts for swap treasury inputs, orders, overhead, leftover, and net debit"
        $ do
            report <- buildSwapFixtureReport
            let treasury = trTreasuryAccounting report
            taInputs treasury `shouldSatisfy` (not . null)
            taInputTotal treasury
                `shouldBe` ValueSummary
                    { vsLovelace = 1_450_000_000_000
                    , vsAssets = Map.empty
                    }
            taSundaeOrderTotal treasury
                `shouldBe` ValueSummary
                    { vsLovelace = 408_271_505_306
                    , vsAssets = Map.empty
                    }
            taPerChunkOverheadLovelace treasury `shouldBe` 3_280_000
            taTreasuryLeftover treasury
                `shouldBe` ValueSummary
                    { vsLovelace = 1_041_728_494_694
                    , vsAssets = Map.empty
                    }
            taNetDebit treasury
                `shouldBe` ValueSummary
                    { vsLovelace = 408_271_505_306
                    , vsAssets = Map.empty
                    }

    it
        "preserves and nets treasury native assets across inputs, orders, leftover, and net debit"
        $ do
            let treasuryInputs =
                    [ ValueSummary
                        { vsLovelace = 110
                        , vsAssets =
                            Map.fromList
                                [
                                    ( "policyA"
                                    , Map.fromList
                                        [ ("assetA", 5)
                                        , ("assetB", 2)
                                        ]
                                    )
                                ]
                        }
                    , ValueSummary
                        { vsLovelace = 40
                        , vsAssets =
                            Map.fromList
                                [ ("policyA", Map.singleton "assetA" 7)
                                , ("policyB", Map.singleton "assetC" 11)
                                ]
                        }
                    ]
                inputTotal = sumValueSummaries treasuryInputs
                orderTotal =
                    ValueSummary
                        { vsLovelace = 60
                        , vsAssets =
                            Map.fromList
                                [ ("policyA", Map.singleton "assetA" 8)
                                , ("policyB", Map.singleton "assetC" 3)
                                ]
                        }
                leftover =
                    ValueSummary
                        { vsLovelace = 90
                        , vsAssets =
                            Map.fromList
                                [
                                    ( "policyA"
                                    , Map.fromList
                                        [ ("assetA", 4)
                                        , ("assetB", 2)
                                        ]
                                    )
                                , ("policyB", Map.singleton "assetC" 8)
                                ]
                        }

            inputTotal
                `shouldBe` orderTotal `addValueSummary` leftover
            treasuryNetDebit inputTotal leftover `shouldBe` orderTotal

    it
        "classifies swap fixture outputs by mechanical role"
        $ do
            report <- buildSwapFixtureReport
            let outputs = trOutputs report
                roles = poRole <$> outputs
            length outputs `shouldBe` 35
            poIndex <$> outputs `shouldBe` [0 .. 34]
            take 33 roles `shouldBe` replicate 33 OutputSwapOrder
            drop 33 roles
                `shouldBe` [OutputTreasuryLeftover, OutputWalletChange]

    it
        "extracts tx-body required signers from the swap fixture"
        $ do
            report <- buildSwapFixtureReport
            trSigners report
                `shouldBe` [ SignerRequirement
                                { srKeyHash =
                                    "8bd03209d227956aaf9670751e0aa2057b51c1537a43f155b24fb1c1"
                                , srSource = SourceTxBodyRequiredSigner
                                , srScope = Nothing
                                }
                           , SignerRequirement
                                { srKeyHash =
                                    "f3ab64b0f97dcf0f91232754603283df5d75a1201337432c04d23e2e"
                                , srSource = SourceTxBodyRequiredSigner
                                , srScope = Nothing
                                }
                           ]

    it
        "labels selected scope owner, extra signer, and intent signer sources"
        $ do
            report <- buildSwapFixtureReportWith signerSourceContext
            trSigners report
                `shouldBe` [ SignerRequirement
                                { srKeyHash = networkComplianceOwner
                                , srSource = SourceSelectedScopeOwner
                                , srScope =
                                    Just "network_compliance"
                                }
                           , SignerRequirement
                                { srKeyHash = opsOwner
                                , srSource = SourceExtraSigner
                                , srScope = Nothing
                                }
                           , SignerRequirement
                                { srKeyHash = sampleKeyHash
                                , srSource = SourceIntentRequiredSigner
                                , srScope = Nothing
                                }
                           ]

    it "reports swap validation facts from the successful build" $ do
        report <- buildSwapFixtureReport
        trValidation report
            `shouldBe` ValidationFacts
                { vfIntentNetwork = "mainnet"
                , vfSocketNetworkMagic = 764_824_073
                , vfNetworkMatches = True
                , vfFeeLovelace = 1_023_379
                , vfBodySizeBytes = 14_987
                , vfRedeemerCount = 2
                , vfRedeemerFailures = 0
                , vfValidationStatus = "ok"
                , vfValidityInterval =
                    ValidityInterval
                        { viInvalidBefore = Nothing
                        , viInvalidHereafter = Just 186_796_799
                        }
                }

    it "treats devnet magic 42 as a matching report network" $ do
        report <-
            buildSwapFixtureReportWith
                emptyReportContext
                    { rcNetwork = "devnet"
                    , rcSocketNetworkMagic = 42
                    }
        vfNetworkMatches (trValidation report) `shouldBe` True

    it "reports selected reference inputs and metadata summary" $ do
        report <- buildSwapFixtureReport
        trReferenceInputs report `shouldBe` expectedSwapReferenceInputs
        msAuxiliaryDataHash (trMetadata report)
            `shouldBe` Just expectedSwapMetadataHash
        msCip1694LabelPresent (trMetadata report) `shouldBe` True

    it "encodes every produced-output role tag" $
        toJSON (roleOutput <$> allProducedOutputRoles)
            `shouldBe` toJSON
                [ roleJson 0 "swapOrder"
                , roleJson 1 "treasuryLeftover"
                , roleJson 2 "walletChange"
                , roleJson 3 "collateralReturn"
                , roleJson 4 "metadata"
                , roleJson 5 "unknown"
                ]

decodedReport :: Either String Value
decodedReport = eitherDecode (encodeReport sampleReport)

sampleIntent :: IO SomeTreasuryIntent
sampleIntent = do
    si <- decodeTreasuryIntentFile "test/fixtures/swap/intent.json"
    case si of
        Left e -> error ("intent JSON: " <> e)
        Right v -> pure v

sampleBuildOutput :: SomeTreasuryIntent -> TxBuildOutput
sampleBuildOutput some =
    TxBuildOutput
        { txoIntent = some
        , txoResult =
            TxBuildOutputSuccess
                TxBuildSuccess
                    { tbsTxCbor = TxCborHex "84a4"
                    , tbsReport = sampleReport
                    }
        }

reportWithAction :: Value
reportWithAction =
    case toJSON sampleReport of
        Object obj ->
            Object $
                KM.insert
                    (Key.fromString "action")
                    (String "swap")
                    obj
        other -> other

buildSwapFixtureReport :: IO TransactionReport
buildSwapFixtureReport = buildSwapFixtureReportWith emptyReportContext

buildSwapFixtureReportWith :: ReportContext -> IO TransactionReport
buildSwapFixtureReportWith reportContext = do
    si <- decodeTreasuryIntentFile "test/fixtures/swap/intent.json"
    some <- case si of
        Left e -> error ("intent JSON: " <> e)
        Right v -> pure v
    fixture <- readSwapFixture "test/fixtures/swap"
    let ctx = toFrozenContext fixture
    tbr <- runFromIntent ctx some
    pure $
        buildTransactionReport
            reportContext
            tbr

emptyReportContext :: ReportContext
emptyReportContext =
    ReportContext
        { rcNetwork = "mainnet"
        , rcSocketNetworkMagic = 764_824_073
        , rcSelectedScopeOwner = Nothing
        , rcExtraSigners = []
        , rcIntentRequiredSigners = []
        }

signerSourceContext :: ReportContext
signerSourceContext =
    emptyReportContext
        { rcSelectedScopeOwner =
            Just
                ( networkComplianceOwner
                , "network_compliance"
                )
        , rcExtraSigners = [opsOwner]
        , rcIntentRequiredSigners = [sampleKeyHash]
        }

hasField :: String -> Value -> Either String Value -> Bool
hasField field expected (Right (Object obj)) =
    KM.lookup (Key.fromString field) obj == Just expected
hasField _ _ _ = False

sampleReport :: TransactionReport
sampleReport =
    TransactionReport
        { trSchema = 1
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
        , tiBodySizeBytes = 14987
        , tiFeeLovelace = 1041155
        , tiTotalCollateralLovelace = 1561733
        , tiValidityInterval = sampleValidityInterval
        }

sampleWalletAccounting :: WalletAccounting
sampleWalletAccounting =
    WalletAccounting
        { waInputs = [sampleUtxo]
        , waCollateralInput = Just sampleUtxo
        , waChangeOutput = Nothing
        , waCollateralReturn = Nothing
        , waFeeLovelace = 1041155
        , waNetSpendLovelace = 1041155
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
        , vfFeeLovelace = 1041155
        , vfBodySizeBytes = 14987
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
        , "bodySizeBytes" .= (14987 :: Int)
        , "feeLovelace" .= (1041155 :: Int)
        , "totalCollateralLovelace" .= (1561733 :: Int)
        , "validityInterval" .= expectedValidityInterval
        ]

expectedWalletAccounting :: Value
expectedWalletAccounting =
    object
        [ "inputs" .= [expectedUtxo]
        , "collateralInput" .= Just expectedUtxo
        , "changeOutput" .= (Nothing :: Maybe Value)
        , "collateralReturn" .= (Nothing :: Maybe Value)
        , "feeLovelace" .= (1041155 :: Int)
        , "netSpendLovelace" .= (1041155 :: Int)
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
        , "feeLovelace" .= (1041155 :: Int)
        , "bodySizeBytes" .= (14987 :: Int)
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

opsOwner :: Text
opsOwner =
    "f3ab64b0f97dcf0f91232754603283df5d75a1201337432c04d23e2e"

networkComplianceOwner :: Text
networkComplianceOwner =
    "8bd03209d227956aaf9670751e0aa2057b51c1537a43f155b24fb1c1"

expectedSwapReferenceInputs :: [Text]
expectedSwapReferenceInputs =
    [ "11ace24a7b0caad4a68a38ef2fff18185dc9ea604e84425dab487cae94e4cf54#0"
    , "25ba96f5deb14bb5c56e7542d6a9ba8450f52cc698ebd74574e1a0525d861095#2"
    , "810bfcbde85ae72f27d7e8cd154c03c802de15d3fa0dd83a32a4b0fdba330b3c#0"
    , "e7b395a93d49a17994d66df0e4778a01dee05e7711e6612f28d97b63e4e6311c#2"
    ]

expectedSwapMetadataHash :: Text
expectedSwapMetadataHash =
    "1163dfe0f06e30a30353b706b988721fb0a6f5168db22402ef6a76b8e677868d"

allProducedOutputRoles :: [ProducedOutputRole]
allProducedOutputRoles =
    [ OutputSwapOrder
    , OutputTreasuryLeftover
    , OutputWalletChange
    , OutputCollateralReturn
    , OutputMetadata
    , OutputUnknown
    ]

roleOutput :: ProducedOutputRole -> ProducedOutput
roleOutput role =
    ProducedOutput
        { poIndex = roleIndex role
        , poRole = role
        , poAddress = "addr_test1role"
        , poValue = emptyValue
        , poDatum = Nothing
        }

roleIndex :: ProducedOutputRole -> Int
roleIndex = \case
    OutputSwapOrder -> 0
    OutputTreasuryLeftover -> 1
    OutputWalletChange -> 2
    OutputCollateralReturn -> 3
    OutputMetadata -> 4
    OutputUnknown -> 5

roleJson :: Int -> Text -> Value
roleJson index role =
    object
        [ "index" .= index
        , "role" .= role
        , "address" .= ("addr_test1role" :: Text)
        , "value" .= expectedValue
        , "datum" .= (Nothing :: Maybe Value)
        ]
