{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Wizard.BuildDisburseSpec
Description : Smoke test for 'Wizard.Disburse.buildDisburseTx'
              (#277).
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

The per-'BuildDiagnostic' coverage is already shared with
'BuildSwapSpec' (the projection 'projectBuildError' is the
single point of truth and is exercised there exhaustively
— see #269 T006).  This spec asserts the disburse entry
point's compile-time contract:

  * 'buildDisburseTx' is exported with the documented
    signature.
  * It plumbs the same 'BuildFailure' / 'TxBuildSuccess'
    Either as 'buildSwapTx'.
-}
module Amaru.Treasury.Wizard.BuildDisburseSpec
    ( spec
    ) where

import Control.Tracer (Tracer)
import Test.Hspec (Spec, describe, it, shouldBe)

import Amaru.Treasury.Backend (Backend)
import Amaru.Treasury.Build.Trace (BuildEvent)
import Amaru.Treasury.Cli.Common (GlobalOpts)
import Amaru.Treasury.IntentJSON (SomeTreasuryIntent)
import Amaru.Treasury.Report (TxBuildSuccess)
import Amaru.Treasury.Wizard.Disburse (buildDisburseTx)
import Amaru.Treasury.Wizard.Failure (BuildFailure)

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
