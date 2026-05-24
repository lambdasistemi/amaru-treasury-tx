{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Wizard.BuildDisburseSpec
Description : Smoke test for 'Wizard.Disburse.buildDisburseTx'
              and 'buildDisburseIntent' (#277).
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

The per-'BuildDiagnostic' coverage is already shared with
'BuildSwapSpec' (the projection 'projectBuildError' is the
single point of truth and is exercised there exhaustively
— see #269 T006).  This spec asserts the disburse entry
points' compile-time contract:

  * 'buildDisburseTx' is exported with the documented
    signature.
  * 'buildDisburseIntent' is exported with the documented
    signature (mirrors 'Wizard.Swap.buildSwapIntent').
  * Both plumb the same typed failure / success surface as
    their swap-side counterparts.
-}
module Amaru.Treasury.Wizard.BuildDisburseSpec
    ( spec
    ) where

import Control.Tracer (Tracer)
import Test.Hspec (Spec, describe, it, shouldBe)

import Amaru.Treasury.Backend (Backend)
import Amaru.Treasury.Build.Trace (BuildEvent)
import Amaru.Treasury.Cli.Common (GlobalOpts)
import Amaru.Treasury.Cli.DisburseWizard (DisburseWizardOpts)
import Amaru.Treasury.IntentJSON (SomeTreasuryIntent)
import Amaru.Treasury.Report (TxBuildSuccess)
import Amaru.Treasury.Tx.DisburseWizard.Trace
    ( DisburseWizardEvent
    )
import Amaru.Treasury.Wizard.Disburse
    ( buildDisburseIntent
    , buildDisburseTx
    )
import Amaru.Treasury.Wizard.Failure
    ( BuildFailure
    , WizardFailure
    )

spec :: Spec
spec = describe "Amaru.Treasury.Wizard.Disburse" $ do
    it
        "exports buildDisburseTx with the documented \
        \GlobalOpts -> Backend -> SomeTreasuryIntent -> \
        \Tracer IO BuildEvent -> IO (Either BuildFailure \
        \TxBuildSuccess) shape (#277)"
        $ let
            -- Reference the symbol so the test fails to
            -- compile if the export ever drifts.
            sig
                :: GlobalOpts
                -> Backend
                -> SomeTreasuryIntent
                -> Tracer IO BuildEvent
                -> IO (Either BuildFailure TxBuildSuccess)
            sig = buildDisburseTx
          in
            -- Stable smoke value: the helper is referenced
            -- through 'sig' above; this assertion is a
            -- type-witness only.
            seq sig True `shouldBe` True

    it
        "exports buildDisburseIntent with the documented \
        \GlobalOpts -> DisburseWizardOpts -> Backend -> \
        \Tracer IO DisburseWizardEvent -> IO (Either \
        \WizardFailure SomeTreasuryIntent) shape (#277)"
        $ let
            sig
                :: GlobalOpts
                -> DisburseWizardOpts
                -> Backend
                -> Tracer IO DisburseWizardEvent
                -> IO (Either WizardFailure SomeTreasuryIntent)
            sig = buildDisburseIntent
          in
            seq sig True `shouldBe` True
