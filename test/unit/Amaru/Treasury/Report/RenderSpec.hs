{-# LANGUAGE OverloadedStrings #-}

module Amaru.Treasury.Report.RenderSpec (spec) where

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldSatisfy
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
    )
import Amaru.Treasury.Report.Render
    ( RenderError (..)
    , RenderOutput (..)
    , renderBuildOutput
    )
import Amaru.Treasury.Report.Render.Time
    ( SlotTimeConfig
    , networkSlotTimeConfig
    , slotToUtcText
    )

spec :: Spec
spec = describe "Amaru.Treasury.Report.Render" $ do
    it "renders leading success facts from the envelope and intent" $ do
        rendered <- renderFixture fixtureReport
        rendered `shouldContainText` "# swap on network_compliance"
        rendered
            `shouldContainText` "- Transaction id: 0000000000000000000000000000000000000000000000000000000000000000"
        rendered
            `shouldContainText` "- Explorer: https://cardanoscan.io/transaction/0000000000000000000000000000000000000000000000000000000000000000"
        rendered
            `shouldContainText` "- CBOR fingerprint: 84a4 (4 hex chars)"
        rendered
            `shouldContainText` "- Validity: invalid before none; invalid hereafter slot 186796799 (2026-05-09T21:44:50Z)"
        rendered
            `shouldContainText` "- CIP-1694 rationale: Swap ADA<->USDM - Swapping ADA for $100k at a rate of $0.245 per ADA; Required to pay Antithesis as vendor; destination Network Compliance's treasury"

    it "derives UTC validity instants from network slot data" $ do
        mainnet <- expectSlotConfig "mainnet"
        preprod <- expectSlotConfig "preprod"
        slotToUtcText mainnet 186_796_799
            `shouldBe` Just "2026-05-09T21:44:50Z"
        slotToUtcText preprod 112_700_800
            `shouldBe` Just "2026-01-14T09:46:40Z"

    it "falls back to slot-only validity when slot data is absent" $ do
        rendered <- renderFixture fixtureReport{trNetwork = "customnet"}
        rendered
            `shouldContainText` "- Validity: invalid before none; invalid hereafter slot 186796799"

    it "pairs lovelace values with ADA and computes conservation" $ do
        rendered <- renderFixture fixtureReport
        rendered
            `shouldContainText` "- Conservation: inputs 15000000 lovelace (15.000000 ADA) = outputs 14000000 lovelace (14.000000 ADA) + fee 1000000 lovelace (1.000000 ADA), residual 0 lovelace (0.000000 ADA)"

    it "collapses identical produced outputs by role address and amount" $ do
        rendered <- renderFixture fixtureReport
        rendered
            `shouldContainText` "- 2 x unknown -> addr_test1same: 2000000 lovelace (2.000000 ADA)"
        rendered
            `shouldContainText` "- 1 x treasuryLeftover -> addr_test1leftover: 10000000 lovelace (10.000000 ADA)"

    it "rejects build-failure envelopes as non-success reports" $ do
        some <- sampleIntent
        renderBuildOutput
            TxBuildOutput
                { txoIntent = some
                , txoResult =
                    TxBuildOutputFailure
                        (BuildFailure "validation-failed" "script validation failed")
                }
            `shouldBe` Left
                ( RenderBuildFailure
                    (BuildFailure "validation-failed" "script validation failed")
                )

renderFixture :: TransactionReport -> IO Text
renderFixture report = do
    some <- sampleIntent
    case renderBuildOutput (successOutput some report) of
        Left err -> fail ("render failed: " <> show err)
        Right (RenderOutput text) -> pure text

successOutput
    :: SomeTreasuryIntent -> TransactionReport -> TxBuildOutput
successOutput some report =
    TxBuildOutput
        { txoIntent = some
        , txoResult =
            TxBuildOutputSuccess
                TxBuildSuccess
                    { tbsTxCbor = TxCborHex "84a4"
                    , tbsReport = report
                    }
        }

sampleIntent :: IO SomeTreasuryIntent
sampleIntent = do
    decoded <- decodeTreasuryIntentFile "test/fixtures/swap/intent.json"
    either (fail . ("intent JSON: " <>)) pure decoded

expectSlotConfig
    :: Text
    -> IO SlotTimeConfig
expectSlotConfig network =
    case networkSlotTimeConfig network of
        Nothing -> fail ("missing slot time config for " <> T.unpack network)
        Just config -> pure config

fixtureReport :: TransactionReport
fixtureReport =
    TransactionReport
        { trSchema = 1
        , trNetwork = "mainnet"
        , trIdentity =
            TransactionIdentity
                { tiTxId =
                    "0000000000000000000000000000000000000000000000000000000000000000"
                , tiBodySizeBytes = 42
                , tiFeeLovelace = 1_000_000
                , tiTotalCollateralLovelace = 0
                , tiValidityInterval =
                    ValidityInterval
                        { viInvalidBefore = Nothing
                        , viInvalidHereafter = Just 186_796_799
                        }
                }
        , trWalletAccounting =
            WalletAccounting
                { waInputs = [utxo "wallet#0" 5_000_000]
                , waCollateralInput = Nothing
                , waChangeOutput = Nothing
                , waCollateralReturn = Nothing
                , waFeeLovelace = 1_000_000
                , waNetSpendLovelace = 1_000_000
                }
        , trTreasuryAccounting =
            TreasuryAccounting
                { taInputs = [utxo "treasury#0" 10_000_000]
                , taInputTotal = lovelace 10_000_000
                , taSundaeOrderTotal = lovelace 4_000_000
                , taPerChunkOverheadLovelace = 0
                , taTreasuryLeftover = lovelace 10_000_000
                , taNetDebit = lovelace 4_000_000
                }
        , trOutputs =
            [ output 0 OutputUnknown "addr_test1same" 2_000_000
            , output 1 OutputUnknown "addr_test1same" 2_000_000
            , output
                2
                OutputTreasuryLeftover
                "addr_test1leftover"
                10_000_000
            ]
        , trSigners =
            [ SignerRequirement
                { srKeyHash =
                    "11111111111111111111111111111111111111111111111111111111"
                , srSource = SourceTxBodyRequiredSigner
                , srScope = Nothing
                }
            ]
        , trValidation =
            ValidationFacts
                { vfIntentNetwork = "mainnet"
                , vfSocketNetworkMagic = 764_824_073
                , vfNetworkMatches = True
                , vfFeeLovelace = 1_000_000
                , vfBodySizeBytes = 42
                , vfRedeemerCount = 0
                , vfRedeemerFailures = 0
                , vfValidationStatus = "ok"
                , vfValidityInterval =
                    ValidityInterval
                        { viInvalidBefore = Nothing
                        , viInvalidHereafter = Just 186_796_799
                        }
                }
        , trReferenceInputs = []
        , trMetadata =
            MetadataSummary
                { msAuxiliaryDataHash = Nothing
                , msCip1694LabelPresent = True
                }
        }

utxo :: Text -> Integer -> UtxoSummary
utxo txIn amount =
    UtxoSummary
        { usTxIn = txIn
        , usValue = lovelace amount
        }

output
    :: Int -> ProducedOutputRole -> Text -> Integer -> ProducedOutput
output index role address amount =
    ProducedOutput
        { poIndex = index
        , poRole = role
        , poAddress = address
        , poValue = lovelace amount
        , poDatum = Nothing
        }

lovelace :: Integer -> ValueSummary
lovelace amount =
    ValueSummary
        { vsLovelace = amount
        , vsAssets = Map.empty
        }

shouldContainText :: Text -> Text -> IO ()
shouldContainText haystack needle =
    haystack `shouldSatisfy` T.isInfixOf needle
