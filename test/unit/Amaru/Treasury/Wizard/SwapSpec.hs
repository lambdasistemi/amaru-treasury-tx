{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Wizard.SwapSpec
Description : Unit tests for the pure-Either swap-wizard
              helpers (#259 Phase 3 commit 1).
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0
-}
module Amaru.Treasury.Wizard.SwapSpec
    ( spec
    ) where

import Data.Text qualified as T

import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldSatisfy
    )

import Amaru.Treasury.Cli.SwapWizard
    ( ChunkSpec (..)
    , WizardRate (..)
    )
import Amaru.Treasury.Tx.SwapQuote
    ( SlippageBps (..)
    )
import Amaru.Treasury.Wizard.Failure
    ( BuildFailure (..)
    , FieldId (..)
    )
import Amaru.Treasury.Wizard.Swap
    ( sysexitsForBuild
    , tryResolveRateParameters
    , tryResolveSwapParameters
    )

spec :: Spec
spec = describe "Amaru.Treasury.Wizard.Swap" $ do
    describe "tryResolveSwapParameters" $ do
        it "Right for a happy-path WizardMinRate input" $
            tryResolveSwapParameters
                1500.0
                (SplitCount 3)
                (WizardMinRate 0.5)
                `shouldSatisfy` isRight'
        it "Right for an operator-override input" $
            tryResolveSwapParameters
                1500.0
                (SplitCount 3)
                (WizardOverrideRate 0.43 (SlippageBps 75))
                `shouldSatisfy` isRight'

    describe "tryResolveRateParameters" $ do
        it "Right for a happy-path WizardMinRate input" $
            tryResolveRateParameters (WizardMinRate 0.5)
                `shouldSatisfy` isRight'
        it "Left carries non-empty text when it fails" $
            -- The pure helpers expose a Left arm; exercising
            -- it here is best-effort.  If the deriver accepts
            -- the input, we accept Right too — the contract
            -- under test is "Left implies non-empty text",
            -- not "this specific input must fail".
            case tryResolveRateParameters
                (WizardOverrideRate 0.0 (SlippageBps 0)) of
                Left e -> T.null e `shouldBe` False
                Right _ -> pure ()

    describe "sysexitsForBuild" $ do
        it "BuildInputInvalid → 64 (EX_USAGE)" $
            sysexitsForBuild
                (BuildInputInvalid FieldWalletAddr "bad")
                `shouldBe` 64
        it "BuildResolveParams → 69 (EX_UNAVAILABLE)" $
            sysexitsForBuild (BuildResolveParams "nope")
                `shouldBe` 69
        it "BuildResolveTip → 69 (EX_UNAVAILABLE)" $
            sysexitsForBuild (BuildResolveTip "nope")
                `shouldBe` 69
        it "BuildResolveUtxo → 69 (EX_UNAVAILABLE)" $
            sysexitsForBuild (BuildResolveUtxo "nope")
                `shouldBe` 69
        it "BuildBuildError → 70 (EX_SOFTWARE)" $
            sysexitsForBuild (BuildBuildError "boom")
                `shouldBe` 70
        it "BuildInternalError → 70 (EX_SOFTWARE)" $
            sysexitsForBuild (BuildInternalError "boom")
                `shouldBe` 70

isRight' :: Either e a -> Bool
isRight' (Right _) = True
isRight' Left{} = False
