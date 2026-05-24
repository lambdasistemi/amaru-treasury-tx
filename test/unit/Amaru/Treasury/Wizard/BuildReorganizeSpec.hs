{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Wizard.BuildReorganizeSpec
Description : Smoke test for 'Wizard.Reorganize.buildReorganizeTx'
              (#280).
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

The per-'BuildDiagnostic' coverage is already shared with
'BuildSwapSpec' / 'BuildDisburseSpec' (the projection
'projectBuildError' is the single point of truth and is
exercised there exhaustively — see #269 T006).  This spec
asserts the reorganize tx-build entry point's compile-time
contract:

  * 'buildReorganizeTx' is exported with the documented
    signature.
  * It plumbs the same typed failure / success surface as
    its swap-side and disburse-side counterparts.
-}
module Amaru.Treasury.Wizard.BuildReorganizeSpec
    ( spec
    ) where

import Control.Tracer (Tracer)
import Test.Hspec (Spec, describe, it, shouldBe)

import Amaru.Treasury.Backend (Backend)
import Amaru.Treasury.Build.Trace (BuildEvent)
import Amaru.Treasury.Cli.Common (GlobalOpts)
import Amaru.Treasury.IntentJSON (SomeTreasuryIntent)
import Amaru.Treasury.Report (TxBuildSuccess)
import Amaru.Treasury.Wizard.Failure (BuildFailure)
import Amaru.Treasury.Wizard.Reorganize (buildReorganizeTx)

spec :: Spec
spec = describe "Amaru.Treasury.Wizard.Reorganize" $ do
    it
        "exports buildReorganizeTx with the documented \
        \GlobalOpts -> Backend -> SomeTreasuryIntent -> \
        \Tracer IO BuildEvent -> IO (Either BuildFailure \
        \TxBuildSuccess) shape (#280)"
        $ let
            -- Reference the symbol so the test fails to
            -- compile if the export ever drifts.
            sig
                :: GlobalOpts
                -> Backend
                -> SomeTreasuryIntent
                -> Tracer IO BuildEvent
                -> IO (Either BuildFailure TxBuildSuccess)
            sig = buildReorganizeTx
          in
            -- Stable smoke value: the helper is referenced
            -- through 'sig' above; this assertion is a
            -- type-witness only.
            seq sig True `shouldBe` True
