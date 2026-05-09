{-# LANGUAGE OverloadedStrings #-}

module Amaru.Treasury.ReportSchemaSpec (spec) where

import Data.Aeson (Value, eitherDecode, eitherDecodeFileStrict)
import Data.JSON.JSONSchema (validateJSONSchema)
import Test.Hspec (Spec, describe, it, shouldBe)

import Amaru.Treasury.Report (encodeReport, sampleSwapReport)
import Amaru.Treasury.Report.Schema (txReportJsonSchema)

spec :: Spec
spec = describe "Amaru.Treasury.Report.Schema" $ do
    it "matches the checked-in schema asset" $ do
        asset <- decodeFile "docs/assets/tx-report-schema.json"
        asset `shouldBe` txReportJsonSchema

    it "validates a representative encoded report" $ do
        report <- expectRight (eitherDecode (encodeReport sampleSwapReport))
        validateJSONSchema txReportJsonSchema report
            `shouldBe` True

    it "validates the swap report golden fixture" $ do
        report <- decodeFile "test/fixtures/swap/report.golden.json"
        validateJSONSchema txReportJsonSchema report
            `shouldBe` True

decodeFile :: FilePath -> IO Value
decodeFile path = expectRight =<< eitherDecodeFileStrict path

expectRight :: Either String a -> IO a
expectRight =
    either (fail . ("decode failed: " <>)) pure
