{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Wizard.BuildContingencyDisburseSpec
Description : Compile-time contract + destination-translation
              test for 'Wizard.Disburse.buildContingencyDisburseIntent'
              (#327).
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Sibling of 'BuildDisburseSpec' for the contingency path.
The per-'BuildDiagnostic' coverage is shared through
'projectBuildError' (exercised in 'BuildSwapSpec'); this spec
asserts the contingency entry point's compile-time contract
and the pure destination translation:

  * 'buildContingencyDisburseIntent' is exported with the
    same shape as 'buildDisburseIntent' but over
    'ContingencyDisburseOpts'.
  * 'resolveContingencyDestinations' turns N operator
    @(scope, lovelace)@ destinations into an N-element
    'DisburseDestination' list, preserving operator order and
    amounts.
-}
module Amaru.Treasury.Wizard.BuildContingencyDisburseSpec
    ( spec
    ) where

import Control.Tracer (Tracer)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NE
import Test.Hspec (Spec, describe, it, shouldBe)

import Amaru.Treasury.Backend (Backend)
import Amaru.Treasury.Cli.Common (GlobalOpts)
import Amaru.Treasury.Cli.DisburseWizard
    ( ContingencyDisburseOpts
    )
import Amaru.Treasury.IntentJSON
    ( DisburseDestination (..)
    , SomeTreasuryIntent
    )
import Amaru.Treasury.Scope (ScopeId (..), scopeText)
import Amaru.Treasury.Tx.DisburseWizard.Trace
    ( DisburseWizardEvent
    )
import Amaru.Treasury.Wizard.Disburse
    ( buildContingencyDisburseIntent
    , resolveContingencyDestinations
    )
import Amaru.Treasury.Wizard.Failure
    ( WizardFailure
    )

spec :: Spec
spec =
    describe "Amaru.Treasury.Wizard.Disburse (contingency)" $ do
        it
            "exports buildContingencyDisburseIntent with the \
            \documented GlobalOpts -> ContingencyDisburseOpts \
            \-> Backend -> Tracer IO DisburseWizardEvent -> IO \
            \(Either WizardFailure SomeTreasuryIntent) shape \
            \(#327)"
            $ let
                -- Reference the symbol so the test fails to
                -- compile if the export ever drifts.
                sig
                    :: GlobalOpts
                    -> ContingencyDisburseOpts
                    -> Backend
                    -> Tracer IO DisburseWizardEvent
                    -> IO
                        ( Either
                            WizardFailure
                            SomeTreasuryIntent
                        )
                sig = buildContingencyDisburseIntent
              in
                seq sig True `shouldBe` True

        it
            "translates N destinations into an N-element \
            \DisburseDestination list, preserving order and \
            \amounts (#327)"
            $ do
                let dests :: NonEmpty (ScopeId, Integer)
                    dests =
                        NE.fromList
                            [ (CoreDevelopment, 1000000)
                            , (OpsAndUseCases, 2500000)
                            , (Middleware, 7000000)
                            ]
                    -- Stub resolver: a scope's address is its
                    -- own scope text; the translation under
                    -- test is the (scope, lovelace) -> typed
                    -- destination mapping, not address lookup.
                    resolved =
                        resolveContingencyDestinations
                            (Right . scopeText)
                            dests
                fmap (length . NE.toList) resolved
                    `shouldBe` Right 3
                fmap NE.toList resolved
                    `shouldBe` Right
                        [ DisburseDestination
                            "core_development"
                            1000000
                        , DisburseDestination
                            "ops_and_use_cases"
                            2500000
                        , DisburseDestination
                            "middleware"
                            7000000
                        ]
