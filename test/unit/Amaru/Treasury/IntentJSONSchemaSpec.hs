{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.IntentJSONSchemaSpec
Description : JSON Schema contract tests for TreasuryIntent
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Verifies that the generated JSON Schema asset stays in
sync with the Haskell source of truth and that checked-in
intents plus wizard-emitted JSON conform to it.
-}
module Amaru.Treasury.IntentJSONSchemaSpec (spec) where

import Data.Aeson
    ( FromJSON
    , Value (..)
    , eitherDecode
    , eitherDecodeFileStrict
    )
import Data.Aeson.Key (Key)
import Data.Aeson.KeyMap qualified as KM
import Data.JSON.JSONSchema (validateJSONSchema)
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    )

import Amaru.Treasury.IntentJSON
    ( SAction (..)
    , SomeTreasuryIntent (..)
    , encodeSomeTreasuryIntent
    )
import Amaru.Treasury.IntentJSON.Schema (intentJsonSchema)
import Amaru.Treasury.Tx.DisburseWizard
    ( DisburseAnswers
    , DisburseEnv
    , disburseToTreasuryIntent
    )
import Amaru.Treasury.Tx.SwapWizard
    ( SwapWizardQ
    , WizardEnv
    , wizardToTreasuryIntent
    )

spec :: Spec
spec = describe "Amaru.Treasury.IntentJSON.Schema" $ do
    it "matches the checked-in schema asset" $ do
        asset <-
            decodeFile "docs/assets/intent-schema.json"
        asset `shouldBe` intentJsonSchema

    it "validates the tx-build swap fixture intent" $ do
        intent <- decodeFile "test/fixtures/swap/intent.json"
        validateJSONSchema intentJsonSchema intent
            `shouldBe` True

    it "validates the swap-wizard golden intent" $ do
        intent <-
            decodeFile
                "test/fixtures/swap-wizard/expected.intent.json"
        validateJSONSchema intentJsonSchema intent
            `shouldBe` True

    it "validates the disburse-wizard ADA golden intent" $ do
        intent <-
            decodeFile
                "test/fixtures/disburse-wizard/expected.intent.ada.json"
        validateJSONSchema intentJsonSchema intent
            `shouldBe` True

    it "validates the tx-build ADA disburse fixture intent" $ do
        intent <- decodeFile "test/fixtures/disburse/ada/intent.json"
        validateJSONSchema intentJsonSchema intent
            `shouldBe` True

    it "validates JSON emitted by wizardToTreasuryIntent" $ do
        env :: WizardEnv <-
            decodeFile "test/fixtures/swap-wizard/env.json"
        answers :: SwapWizardQ <-
            decodeFile "test/fixtures/swap-wizard/answers.json"
        intent <-
            expectRight $
                wizardToTreasuryIntent env answers
        let bytes =
                encodeSomeTreasuryIntent
                    (SomeTreasuryIntent SSwap intent)
        value <- expectRight (eitherDecode bytes)
        validateJSONSchema intentJsonSchema value
            `shouldBe` True

    it "validates JSON emitted by disburseToTreasuryIntent" $ do
        env :: DisburseEnv <-
            decodeFile "test/fixtures/disburse-wizard/env.ada.json"
        answers :: DisburseAnswers <-
            decodeFile
                "test/fixtures/disburse-wizard/answers.ada.json"
        intent <-
            expectRight $
                disburseToTreasuryIntent env answers
        let bytes =
                encodeSomeTreasuryIntent
                    (SomeTreasuryIntent SDisburse intent)
        value <- expectRight (eitherDecode bytes)
        validateJSONSchema intentJsonSchema value
            `shouldBe` True

    it "rejects action/payload mismatches" $ do
        swapIntent <- decodeFile "test/fixtures/swap/intent.json"
        let mismatched =
                replaceActionBlock
                    "swap"
                    "disburse"
                    disburseBlock
                    swapIntent
        validateJSONSchema intentJsonSchema mismatched
            `shouldBe` False

decodeFile :: (FromJSON a) => FilePath -> IO a
decodeFile path = do
    r <- eitherDecodeFileStrict path
    expectRight r

expectRight :: (Show e) => Either e a -> IO a
expectRight =
    either
        ( errorWithoutStackTrace
            . ("unexpected Left: " <>)
            . show
        )
        pure

replaceActionBlock
    :: Key
    -> Key
    -> Value
    -> Value
    -> Value
replaceActionBlock oldBlock newBlock payload = \case
    Object o ->
        Object $
            KM.insert "action" (String "swap") $
                KM.insert newBlock payload $
                    KM.delete oldBlock o
    other -> other

disburseBlock :: Value
disburseBlock =
    Object $
        KM.fromList
            [ ("unit", String "ada")
            , ("amount", Number 50000000)
            ,
                ( "beneficiaryAddress"
                , String
                    "addr1q802wxt6cg6aw0nl0vdzfxavu65rxu3yzhvgayw7chfxymduzkt66uw9t5kspx5jwjecx80dz4g33htknafhdhkvzd5st4f9xu"
                )
            ,
                ( "usdmPolicy"
                , String
                    "c48cbb3d5e57ed56e276bc45f99ab39abe94e6cd7ac39fb402da47ad"
                )
            , ("usdmToken", String "0014df105553444d")
            ]
