{-# LANGUAGE OverloadedStrings #-}

module Amaru.Treasury.ReportSchemaSpec (spec) where

import Data.Aeson
    ( Value (..)
    , eitherDecode
    , eitherDecodeFileStrict
    , encode
    , object
    , toJSON
    , (.=)
    )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.JSON.JSONSchema (validateJSONSchema)
import Test.Hspec (Spec, describe, it, shouldBe)

import Amaru.Treasury.IntentJSON
    ( SomeTreasuryIntent
    , decodeTreasuryIntentFile
    )
import Amaru.Treasury.Report
    ( BuildFailure (..)
    , TxBuildOutput (..)
    , TxBuildOutputResult (..)
    , TxBuildSuccess (..)
    , TxCborHex (..)
    , encodeBuildOutput
    , encodeReport
    , sampleSwapReport
    )
import Amaru.Treasury.Report.Schema (txReportJsonSchema)

spec :: Spec
spec = describe "Amaru.Treasury.Report.Schema" $ do
    it "matches the checked-in schema asset" $ do
        asset <- decodeFile "docs/assets/tx-report-schema.json"
        asset `shouldBe` txReportJsonSchema

    it "validates a representative success build-output envelope" $ do
        some <- sampleIntent
        envelope <-
            expectRight $
                eitherDecode (encodeBuildOutput (sampleBuildOutput some))
        validateJSONSchema txReportJsonSchema envelope
            `shouldBe` True

    it "validates a representative failure build-output envelope" $ do
        some <- sampleIntent
        envelope <-
            expectRight $
                eitherDecode (encodeBuildOutput (sampleFailureOutput some))
        validateJSONSchema txReportJsonSchema envelope
            `shouldBe` True

    it "rejects the old naked mechanical report shape" $ do
        report <- expectRight (eitherDecode (encodeReport sampleSwapReport))
        validateJSONSchema txReportJsonSchema report
            `shouldBe` False

    it "rejects duplicate transaction type inside nested report" $ do
        some <- sampleIntent
        let badNestedAction =
                encode $
                    object
                        [ "intent" .= some
                        , "result"
                            .= object
                                [ "tx-cbor" .= ("84a4" :: String)
                                , "report" .= reportWithAction
                                ]
                        ]
        envelope <- expectRight (eitherDecode badNestedAction)
        validateJSONSchema txReportJsonSchema envelope
            `shouldBe` False

    it "validates the swap report golden fixture" $ do
        report <- decodeFile "test/fixtures/swap/report.golden.json"
        validateJSONSchema txReportJsonSchema report
            `shouldBe` True

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
                    , tbsReport = sampleSwapReport
                    }
        }

sampleFailureOutput :: SomeTreasuryIntent -> TxBuildOutput
sampleFailureOutput some =
    TxBuildOutput
        { txoIntent = some
        , txoResult =
            TxBuildOutputFailure
                BuildFailure
                    { bfCode = "validation-failed"
                    , bfMessage = "script validation failed"
                    }
        }

reportWithAction :: Value
reportWithAction =
    case toJSON sampleSwapReport of
        Object obj ->
            Object $
                KM.insert
                    (Key.fromString "action")
                    (String "swap")
                    obj
        other -> other

decodeFile :: FilePath -> IO Value
decodeFile path = expectRight =<< eitherDecodeFileStrict path

expectRight :: Either String a -> IO a
expectRight =
    either (fail . ("decode failed: " <>)) pure
