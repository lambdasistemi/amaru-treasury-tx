{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Wizard.EventSpec
Description : Smoke tests for the 'Amaru.Treasury.Wizard.Event'
              module (#259 + #269).
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0
-}
module Amaru.Treasury.Wizard.EventSpec
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

import Amaru.Treasury.Wizard.Event
    ( BuildEvent (..)
    , WizardEvent (..)
    , renderBuildEvent
    , renderEvent
    )

spec :: Spec
spec = describe "Amaru.Treasury.Wizard.Event" $ do
    it
        "re-exports WizardEvent + renderEvent so callers \
        \have a stable import path under the Wizard/ tree"
        $ renderEvent (WeNetwork "mainnet" 764824073)
            `shouldSatisfy` (not . T.null)
    describe "renderBuildEvent" $ do
        it "renders ResolvingPParams" $
            renderBuildEvent BeResolvingPParams
                `shouldBe` "resolving protocol parameters"
        it "renders SelectingWalletInputs with the address" $
            renderBuildEvent (BeSelectingWalletInputs "addr1q...")
                `shouldBe` "selecting wallet inputs at addr1q..."
        it "renders BuildingSundaeOrder with the direction" $
            renderBuildEvent (BeBuildingSundaeOrder "ADA->USDM")
                `shouldBe` "building sundae order (ADA->USDM)"
        it "renders BalancingTx with the input/output counts" $
            renderBuildEvent (BeBalancingTx 3 4)
                `shouldBe` "balancing tx (3 in, 4 out)"
        it "renders SerialisingTx" $
            renderBuildEvent BeSerialisingTx
                `shouldBe` "serialising tx body"
        it "renders WritingReport with the txid" $
            renderBuildEvent (BeWritingReport "deadbeef")
                `shouldBe` "writing report for tx deadbeef"
