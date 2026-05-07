{- |
Module      : Amaru.Treasury.Tx.DisburseWizardSpec
Description : Unit tests for the disburse wizard
License     : Apache-2.0
-}
module Amaru.Treasury.Tx.DisburseWizardSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BSL
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    )

import Amaru.Treasury.IntentJSON
    ( SAction (..)
    , TreasuryIntent (..)
    )
import Amaru.Treasury.Tx.DisburseWizard
    ( disburseToTreasuryIntent
    )

spec :: Spec
spec =
    describe "Amaru.Treasury.Tx.DisburseWizard" $
        it "emits a schema-v1 TreasuryIntent 'Disburse" $ do
            env <-
                eitherDecodeStrict
                    "test/fixtures/disburse-wizard/env.ada.json"
            answers <-
                eitherDecodeStrict
                    "test/fixtures/disburse-wizard/answers.ada.json"
            intent <-
                expectRight $
                    disburseToTreasuryIntent env answers
            tiSAction intent `shouldBe` SDisburse
            tiSchema intent `shouldBe` 1
            tiNetwork intent `shouldBe` "mainnet"

eitherDecodeStrict :: (Aeson.FromJSON a) => FilePath -> IO a
eitherDecodeStrict p = do
    bs <- BSL.readFile p
    expectRight (Aeson.eitherDecode bs)

expectRight :: (Show e) => Either e a -> IO a
expectRight =
    either
        ( errorWithoutStackTrace
            . ("unexpected Left: " <>)
            . show
        )
        pure
