{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Wizard.EventSpec
Description : Smoke tests for the 'Amaru.Treasury.Wizard.Event'
              re-export shim (#259 + #269).
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
    it
        "re-exports BuildEvent + renderBuildEvent from \
        \Amaru.Treasury.Build.Trace so the buildSwapTx \
        \pipeline shares the same per-step event taxonomy \
        \as the existing tx-build CLI subcommand"
        $ renderBuildEvent (BuildEventConnect "/tmp/node.socket")
            `shouldSatisfy` (not . T.null)
