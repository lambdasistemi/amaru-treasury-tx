{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Wizard.BuildReorganizeSpec
Description : Smoke test for 'Wizard.Reorganize.buildReorganizeTx'
              and 'buildReorganizeIntent' (#280).
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

The per-'BuildDiagnostic' coverage is already shared with
'BuildSwapSpec' / 'BuildDisburseSpec' (the projection
'projectBuildError' is the single point of truth and is
exercised there exhaustively — see #269 T006).  This spec
asserts the reorganize entry points' compile-time contract:

  * 'buildReorganizeTx' is exported with the documented
    signature (slice 1).
  * 'buildReorganizeIntent' is exported with the documented
    signature (slice 2; mirrors
    'Wizard.Disburse.buildDisburseIntent').
  * Both plumb the same typed failure / success surface as
    their swap-side and disburse-side counterparts.
-}
module Amaru.Treasury.Wizard.BuildReorganizeSpec
    ( spec
    ) where

import Control.Tracer (Tracer)
import Test.Hspec (Spec, describe, it, shouldBe)

import Amaru.Treasury.Api.BuildReorganize
    ( ReorganizeBuildRequest (..)
    , mapToReorganizeWizardOpts
    )
import Amaru.Treasury.Backend (Backend)
import Amaru.Treasury.Build.Trace (BuildEvent)
import Amaru.Treasury.Cli.Common (GlobalOpts)
import Amaru.Treasury.Cli.ReorganizeWizard
    ( ReorganizeWizardOpts (..)
    )
import Amaru.Treasury.IntentJSON (SomeTreasuryIntent)
import Amaru.Treasury.Report (TxBuildSuccess)
import Amaru.Treasury.Scope (ScopeId (CoreDevelopment))
import Amaru.Treasury.Tx.ReorganizeWizard.Trace
    ( ReorganizeWizardEvent
    )
import Amaru.Treasury.Wizard.Failure
    ( BuildFailure
    , WizardFailure
    )
import Amaru.Treasury.Wizard.Reorganize
    ( buildReorganizeIntent
    , buildReorganizeTx
    )

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

    it
        "exports buildReorganizeIntent with the documented \
        \GlobalOpts -> ReorganizeWizardOpts -> Backend -> \
        \Tracer IO ReorganizeWizardEvent -> IO (Either \
        \WizardFailure SomeTreasuryIntent) shape (#280)"
        $ let
            sig
                :: GlobalOpts
                -> ReorganizeWizardOpts
                -> Backend
                -> Tracer IO ReorganizeWizardEvent
                -> IO (Either WizardFailure SomeTreasuryIntent)
            sig = buildReorganizeIntent
          in
            seq sig True `shouldBe` True

    it "maps HTTP split-native-assets into the wizard opts" $
        case mapToReorganizeWizardOpts splitNativeAssetsRequest of
            Left err ->
                fail ("expected mapper success, got: " <> show err)
            Right opts ->
                rwoSplitNativeAssets opts `shouldBe` True

splitNativeAssetsRequest :: ReorganizeBuildRequest
splitNativeAssetsRequest =
    ReorganizeBuildRequest
        { rbrScope = CoreDevelopment
        , rbrWalletAddr = "addr1qexample"
        , rbrMetadataPath = "/etc/amaru-treasury/metadata.json"
        , rbrValidityHours = Nothing
        , rbrDescription = Nothing
        , rbrJustification = Nothing
        , rbrDestinationLabel = Nothing
        , rbrEvent = Nothing
        , rbrLabel = Nothing
        , rbrSplitNativeAssets = Just True
        }
