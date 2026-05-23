{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Wizard.EventSpec
Description : Smoke test for the 'Amaru.Treasury.Wizard.Event'
              re-export shim (#259).
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
    ( WizardEvent (..)
    , renderEvent
    )

spec :: Spec
spec =
    describe "Amaru.Treasury.Wizard.Event"
        $ it
            "re-exports WizardEvent + renderEvent so callers \
            \have a stable import path under the Wizard/ tree"
        $ renderEvent (WeNetwork "mainnet" 764824073)
            `shouldSatisfy` (not . T.null)
