{-# LANGUAGE DataKinds #-}

{- |
Module      : Amaru.Treasury.Tx.WithdrawWizardSpec
Description : Unit tests for the withdraw wizard
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0
-}
module Amaru.Treasury.Tx.WithdrawWizardSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BSL
import System.Directory (doesFileExist)
import System.Environment (lookupEnv)
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    )

import Amaru.Treasury.IntentJSON
    ( Action (..)
    , SAction (..)
    , SomeTreasuryIntent (..)
    , TreasuryIntent
    , decodeTreasuryIntentFile
    , encodeSomeTreasuryIntent
    )
import Amaru.Treasury.Tx.WithdrawWizard
    ( WithdrawAnswers
    , WithdrawEnv (..)
    , WithdrawError (..)
    , withdrawToTreasuryIntent
    )
import Amaru.Treasury.Tx.WithdrawWizard.Trace ()

spec :: Spec
spec =
    describe "Amaru.Treasury.Tx.WithdrawWizard" $ do
        it "matches synthetic positive-rewards intent golden" goldenCase
        it "rejects zero rewards before emitting an intent" $ do
            env <-
                eitherDecodeStrict
                    "test/fixtures/withdraw/synthetic/env.json"
            answers <-
                eitherDecodeStrict
                    "test/fixtures/withdraw/synthetic/answers.json"
            withdrawToTreasuryIntent
                (env{weRewardsLovelace = 0})
                answers
                `shouldBe` Left WithdrawRewardsNotPositive

goldenCase :: IO ()
goldenCase = do
    let dir = "test/fixtures/withdraw/synthetic"
        envPath = dir <> "/env.json"
        ansPath = dir <> "/answers.json"
        goldenPath = dir <> "/intent.json"
    env <- eitherDecodeStrict envPath :: IO WithdrawEnv
    answers <- eitherDecodeStrict ansPath :: IO WithdrawAnswers
    intent <-
        case withdrawToTreasuryIntent env answers of
            Left err ->
                error
                    ( "withdrawToTreasuryIntent failed: "
                        <> show err
                    )
            Right got -> pure got
    let actualBytes = stableEncode intent
    exists <- doesFileExist goldenPath
    update <- lookupEnv "UPDATE_GOLDENS"
    if not exists || update == Just "1"
        then do
            BSL.writeFile goldenPath actualBytes
            error
                ( "Golden written to "
                    <> goldenPath
                    <> "; review and re-run without"
                    <> " UPDATE_GOLDENS=1 to lock in"
                )
        else do
            expectedBytes <- BSL.readFile goldenPath
            actualBytes `shouldBe` expectedBytes
            some <- expectRight =<< decodeTreasuryIntentFile goldenPath
            case some of
                SomeTreasuryIntent SWithdraw _ -> pure ()
                _ ->
                    expectationFailure
                        "expected SWithdraw intent"

eitherDecodeStrict :: (Aeson.FromJSON a) => FilePath -> IO a
eitherDecodeStrict p = do
    bs <- BSL.readFile p
    case Aeson.eitherDecode bs of
        Right v -> pure v
        Left e ->
            error ("decode " <> p <> ": " <> e)

expectRight :: (Show e) => Either e a -> IO a
expectRight =
    either
        ( errorWithoutStackTrace
            . ("unexpected Left: " <>)
            . show
        )
        pure

stableEncode :: TreasuryIntent 'Withdraw -> BSL.ByteString
stableEncode =
    encodeSomeTreasuryIntent . SomeTreasuryIntent SWithdraw
