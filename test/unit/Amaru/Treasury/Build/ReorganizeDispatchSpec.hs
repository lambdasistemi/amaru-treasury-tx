{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}

{- |
Module      : Amaru.Treasury.Build.ReorganizeDispatchSpec
Description : Reorganize dispatcher coverage
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0
-}
module Amaru.Treasury.Build.ReorganizeDispatchSpec (spec) where

import Data.ByteString.Lazy qualified as BSL
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text qualified as T
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    , shouldSatisfy
    )

import Amaru.Treasury.Build
    ( BuildAction (..)
    , BuildDiagnostic (..)
    , BuildError (..)
    , BuildFailurePhase (..)
    , BuildResult (..)
    , runFromIntentEither
    )
import Amaru.Treasury.ChainContext
    ( ChainContext
    )
import Amaru.Treasury.ChainContext.Fixture
    ( readSwapFixture
    , toFrozenContext
    )
import Amaru.Treasury.IntentJSON
    ( ReorganizeInputs (..)
    , SAction (..)
    , SomeTreasuryIntent (..)
    , TreasuryIntent (..)
    , decodeTreasuryIntentFile
    )

fixtureDir :: FilePath
fixtureDir = "test/fixtures/reorganize-core/synthetic"

spec :: Spec
spec =
    describe "Amaru.Treasury.Build reorganize dispatcher" $ do
        it "dispatches a parsed reorganize intent to the builder" $ do
            (ctx, some) <- loadDispatchCase
            result <- runFromIntentEither ctx some
            case result of
                Right buildResult ->
                    brCborBytes buildResult
                        `shouldSatisfy` (not . BSL.null)
                Left err ->
                    expectationFailure
                        ("expected Right BuildResult, got " <> show err)

        it "rejects duplicate treasury UTxOs at translation" $ do
            (ctx, some) <- loadDispatchCase
            duplicate <- duplicateTreasuryUtxos some
            result <- runFromIntentEither ctx duplicate
            case result of
                Left err -> do
                    beAction err `shouldBe` BuildActionIntent
                    bePhase err `shouldBe` BuildPhaseTranslate
                    beDiagnostic err `shouldSatisfy` \case
                        DiagnosticTranslateFailed msg ->
                            "duplicates" `T.isInfixOf` msg
                        _ -> False
                Right _ ->
                    expectationFailure
                        "expected duplicate treasuryUtxos translate failure"

loadDispatchCase :: IO (ChainContext, SomeTreasuryIntent)
loadDispatchCase = do
    some <-
        expectRightIO
            =<< decodeTreasuryIntentFile
                (fixtureDir <> "/intent.json")
    fixture <- readSwapFixture fixtureDir
    pure (toFrozenContext fixture, some)

duplicateTreasuryUtxos
    :: SomeTreasuryIntent -> IO SomeTreasuryIntent
duplicateTreasuryUtxos = \case
    SomeTreasuryIntent SReorganize ti -> do
        let payload = tiPayload ti
            first :| _ = riTreasuryUtxos payload
            duplicatePayload =
                payload
                    { riTreasuryUtxos = first :| [first]
                    }
        pure $
            SomeTreasuryIntent
                SReorganize
                ti{tiPayload = duplicatePayload}
    _ -> do
        expectationFailure "expected reorganize intent fixture"
        error "unreachable"

expectRightIO :: (Show e) => Either e a -> IO a
expectRightIO =
    either
        (errorWithoutStackTrace . ("unexpected Left: " <>) . show)
        pure
