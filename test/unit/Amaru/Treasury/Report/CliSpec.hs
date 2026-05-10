{-# LANGUAGE OverloadedStrings #-}

module Amaru.Treasury.Report.CliSpec (spec) where

import Data.Aeson
    ( Value
    , encode
    , object
    , (.=)
    )
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.Either (isLeft)
import Data.Text qualified as T
import Options.Applicative
    ( defaultPrefs
    , execParserPure
    , info
    )
import Options.Applicative.Types
    ( ParserResult (..)
    )
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
    ( TxBuildOutput (..)
    , TxBuildOutputResult (..)
    )
import Amaru.Treasury.Report.Cli
    ( ReportRenderOpts (..)
    , decodeReportRenderInput
    , reportRenderOptsP
    )

spec :: Spec
spec = describe "Amaru.Treasury.Report.Cli" $ do
    describe "report-render CLI parser" $ do
        it "defaults to stdin and stdout" $
            parseReportRender []
                `shouldBe` Right
                    ReportRenderOpts
                        { rrInPath = Nothing
                        , rrOutPath = Nothing
                        , rrMetadataPath = Nothing
                        }

        it "accepts input, output, metadata, and stdio aliases" $ do
            parseReportRender
                [ "--in"
                , "report.json"
                , "--out"
                , "report.md"
                , "--metadata"
                , "metadata.json"
                ]
                `shouldBe` Right
                    ReportRenderOpts
                        { rrInPath = Just "report.json"
                        , rrOutPath = Just "report.md"
                        , rrMetadataPath = Just "metadata.json"
                        }
            parseReportRender ["--in", "-", "--out", "-"]
                `shouldBe` Right
                    ReportRenderOpts
                        { rrInPath = Nothing
                        , rrOutPath = Nothing
                        , rrMetadataPath = Nothing
                        }

        it "rejects separate intent flags" $ do
            parseReportRender ["--intent", "intent.json"]
                `shouldBe` Left "parse failure"
            parseReportRender ["--no-intent"]
                `shouldBe` Left "parse failure"

    describe "build-output envelope decoding" $ do
        it "rejects fixtures with missing or malformed required fields" $ do
            missing <-
                BS.readFile
                    "test/fixtures/swap/report.missing-required-fields.json"
            malformed <-
                BS.readFile
                    "test/fixtures/swap/report.malformed-required-fields.json"
            decodeReportRenderInput missing `shouldSatisfy` isLeft
            decodeReportRenderInput malformed `shouldSatisfy` isLeft

        it "rejects missing result, success tx-cbor, and success report" $ do
            some <- sampleIntent
            decodeReportRenderInput (strict (object ["intent" .= some]))
                `shouldSatisfy` isLeft
            decodeReportRenderInput
                ( strict $
                    object
                        [ "intent" .= some
                        , "result" .= object ["report" .= object []]
                        ]
                )
                `shouldSatisfy` isLeft
            decodeReportRenderInput
                ( strict $
                    object
                        [ "intent" .= some
                        , "result" .= object ["tx-cbor" .= ("84a4" :: T.Text)]
                        ]
                )
                `shouldSatisfy` isLeft

        it "decodes a checked-in success envelope" $ do
            bytes <- BS.readFile "test/fixtures/swap/report.golden.json"
            case decodeReportRenderInput bytes of
                Left err -> fail (T.unpack err)
                Right output ->
                    case txoResult output of
                        TxBuildOutputSuccess{} -> pure ()
                        TxBuildOutputFailure{} ->
                            fail "expected success envelope"

parseReportRender :: [String] -> Either String ReportRenderOpts
parseReportRender args =
    case execParserPure defaultPrefs (info reportRenderOptsP mempty) args of
        Success opts -> Right opts
        Failure{} -> Left "parse failure"
        CompletionInvoked{} -> Left "completion invoked"

sampleIntent :: IO SomeTreasuryIntent
sampleIntent = do
    decoded <- decodeTreasuryIntentFile "test/fixtures/swap/intent.json"
    either (fail . ("intent JSON: " <>)) pure decoded

strict :: Value -> BS.ByteString
strict = BSL.toStrict . encode
