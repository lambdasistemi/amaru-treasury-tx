{- |
Module      : Amaru.Treasury.Inspect.SchemaSpec
Description : JSON Schema contract tests for the treasury-inspect report
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Verifies that the generated JSON Schema asset under
@docs/assets/treasury-inspect-schema.json@ stays in sync with
'Amaru.Treasury.Inspect.Schema.treasuryInspectSchema', and that
the checked-in golden inspect-report under
@test/fixtures/treasury-inspect/report.golden.json@ validates
against that schema.
-}
module Amaru.Treasury.Inspect.SchemaSpec
    ( spec
    ) where

import Data.Aeson (Value, eitherDecodeFileStrict)
import Data.JSON.JSONSchema (validateJSONSchema)
import Test.Hspec (Spec, describe, it, shouldBe)

import Amaru.Treasury.Inspect.Schema (treasuryInspectSchema)

spec :: Spec
spec = describe "Amaru.Treasury.Inspect.Schema" $ do
    it "matches the checked-in schema asset" $ do
        asset <-
            decodeFile "docs/assets/treasury-inspect-schema.json"
        asset `shouldBe` treasuryInspectSchema

    it "validates the golden inspect report" $ do
        report <-
            decodeFile
                "test/fixtures/treasury-inspect/report.golden.json"
        validateJSONSchema treasuryInspectSchema report
            `shouldBe` True

decodeFile :: FilePath -> IO Value
decodeFile path = do
    r <- eitherDecodeFileStrict path
    case r of
        Left e ->
            errorWithoutStackTrace
                ("decoding " <> path <> ": " <> e)
        Right v -> pure v
