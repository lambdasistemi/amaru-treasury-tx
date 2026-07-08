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

import Data.IORef
    ( newIORef
    , readIORef
    , writeIORef
    )
import Data.Text qualified as T

import Control.Tracer
    ( Tracer (..)
    , traceWith
    )

import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldSatisfy
    )

import Amaru.Treasury.Trace (Severity (..))
import Amaru.Treasury.Wizard.Event
    ( BuildEvent (..)
    , DisburseEvent (..)
    , DisburseWizardEvent (..)
    , ReorganizeWizardEvent (..)
    , WithdrawWizardEvent (..)
    , WizardEvent (..)
    , buildEventSeverity
    , buildEventSeverityTracer
    , disburseEventSeverity
    , disburseWizardEventSeverity
    , renderBuildEvent
    , renderEvent
    , reorganizeWizardEventSeverity
    , withdrawWizardEventSeverity
    , wizardEventSeverity
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
    describe "event severity" $ do
        it "classifies routine wizard events as Info" $ do
            wizardEventSeverity (WeNetwork "mainnet" 764824073)
                `shouldBe` Info
            disburseWizardEventSeverity
                (DweWalletUtxosQueried 2)
                `shouldBe` Info
            reorganizeWizardEventSeverity
                (RweTreasuryUtxosResolved 3)
                `shouldBe` Info
            withdrawWizardEventSeverity
                (WweRewardsQueried "stake_test" 42)
                `shouldBe` Info

        it "classifies abort and failed build events as Error" $ do
            wizardEventSeverity (WeAborted "bad metadata")
                `shouldBe` Error
            disburseWizardEventSeverity (DweAborted "bad metadata")
                `shouldBe` Error
            reorganizeWizardEventSeverity (RweAborted "bad metadata")
                `shouldBe` Error
            withdrawWizardEventSeverity (WweAborted "bad metadata")
                `shouldBe` Error
            buildEventSeverity BuildEventValidationFailed
                `shouldBe` Error
            disburseEventSeverity DeValidationFailed
                `shouldBe` Error

        it "classifies mismatch and partial build events as Warning" $ do
            buildEventSeverity
                (BuildEventNetworkMismatch "mainnet" 764824073 1)
                `shouldBe` Warning
            buildEventSeverity
                (BuildEventReevaluated 4 1)
                `shouldBe` Warning
            disburseEventSeverity (DeReevaluated 4 1)
                `shouldBe` Warning

        it "emits severity with unchanged rendered build text" $ do
            seen <- newIORef Nothing
            let tr = Tracer (writeIORef seen . Just)
            traceWith
                (buildEventSeverityTracer tr)
                (BuildEventAborted "missing input")
            captured <- readIORef seen
            captured
                `shouldBe` Just
                    ( Error
                    , renderBuildEvent
                        (BuildEventAborted "missing input")
                    )
