{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Wizard.BuildSwapSpec
Description : Per-variant coverage for 'projectBuildError'
              (#269 T006).
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

The full 'buildSwapTx' end-to-end happy-path is pinned by
the byte-identity golden corpus
('SwapGoldenSpec' / 'BuildSwapGoldenSpec').  This spec
covers the typed-projection layer only: every
'BuildDiagnostic' constructor produced by the underlying
'Amaru.Treasury.Build' pipeline collapses cleanly into one
of the six 'BuildFailure' arms, with the operator-facing
diagnostic text preserved.
-}
module Amaru.Treasury.Wizard.BuildSwapSpec
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

import Cardano.Ledger.Coin (Coin (..))

import Amaru.Treasury.Build.Error.Types
    ( BuildAction (..)
    , BuildDiagnostic (..)
    , BuildError (..)
    , BuildFailurePhase (..)
    )
import Amaru.Treasury.Wizard.Failure
    ( BuildFailure (..)
    )
import Amaru.Treasury.Wizard.Swap
    ( projectBuildError
    )

-- | Build a minimal 'BuildError' for a chosen diagnostic, in
--   the @BuildPhaseBuild@ phase of @BuildActionSwap@.  Used
--   to drive 'projectBuildError' in isolation.
errAt :: BuildFailurePhase -> BuildDiagnostic -> BuildError
errAt phase diag =
    BuildError
        { beAction = BuildActionSwap
        , bePhase = phase
        , beContext = []
        , beDiagnostic = diag
        }

spec :: Spec
spec = describe "Amaru.Treasury.Wizard.Swap.projectBuildError" $ do
    -- ResolveUtxo family.
    it "DiagnosticMissingUtxos → BuildResolveUtxo" $
        case projectBuildError
            ( errAt
                BuildPhaseGatherInputs
                (DiagnosticMissingUtxos ["abc#0"])
            ) of
            BuildResolveUtxo t -> t `shouldSatisfy` (not . T.null)
            other -> expectationFailed "BuildResolveUtxo" other

    -- ResolveParams family.
    it "DiagnosticUnsupportedNetwork → BuildResolveParams" $
        case projectBuildError
            ( errAt
                BuildPhaseUnsupported
                (DiagnosticUnsupportedNetwork "mainnet")
            ) of
            BuildResolveParams t -> t `shouldSatisfy` (not . T.null)
            other -> expectationFailed "BuildResolveParams" other

    -- BuildError family — six diagnostics collapse here.
    describe "DSL / balance / fee diagnostics → BuildBuildError" $ do
        let cases =
                [
                    ( "ScriptEvaluationFailed"
                    , DiagnosticScriptEvaluationFailed
                        "PolicyMint"
                        "validator returned false"
                    )
                ,
                    ( "InsufficientFee"
                    , DiagnosticInsufficientFee
                        (Coin 100)
                        (Coin 50)
                    )
                ,
                    ( "FeeNotConverged"
                    , DiagnosticFeeNotConverged
                    )
                ,
                    ( "CollateralShortfall"
                    , DiagnosticCollateralShortfall
                        (Coin 5_000_000)
                        (Coin 1_000_000)
                    )
                ,
                    ( "BumpFeeFailed"
                    , DiagnosticBumpFeeFailed "iteration limit"
                    )
                ,
                    ( "ChecksFailed"
                    , DiagnosticChecksFailed "ledger said no"
                    )
                ,
                    ( "FeeAlignmentFailed"
                    , DiagnosticFeeAlignmentFailed
                        "could not align"
                    )
                ]
        mapM_
            ( \(name, diag) -> it name $
                case projectBuildError
                    (errAt BuildPhaseBuild diag) of
                    BuildBuildError t ->
                        t `shouldSatisfy` (not . T.null)
                    other ->
                        expectationFailed
                            "BuildBuildError"
                            other
            )
            cases

    -- Internal family.
    describe "internal-invariant diagnostics → BuildInternalError" $ do
        it "TranslateFailed" $
            case projectBuildError
                ( errAt
                    BuildPhaseTranslate
                    (DiagnosticTranslateFailed "parse fail")
                ) of
                BuildInternalError t ->
                    t `shouldSatisfy` (not . T.null)
                other ->
                    expectationFailed "BuildInternalError" other
        it "UnsupportedAction" $
            case projectBuildError
                ( errAt
                    BuildPhaseUnsupported
                    (DiagnosticUnsupportedAction "bogus")
                ) of
                BuildInternalError t ->
                    t `shouldSatisfy` (not . T.null)
                other ->
                    expectationFailed "BuildInternalError" other

    -- Round-trip preservation: the diagnostic name appears
    -- in the rendered text so a UI can surface the
    -- underlying class even after the collapse.
    it
        "preserves the diagnostic class in the rendered text"
        $ let bf =
                projectBuildError
                    ( errAt
                        BuildPhaseBuild
                        ( DiagnosticInsufficientFee
                            (Coin 99)
                            (Coin 1)
                        )
                    )
              t = case bf of
                BuildBuildError m -> m
                _ -> ""
           in "insufficient" `T.isInfixOf` T.toLower t
                `shouldBe` True

expectationFailed :: String -> BuildFailure -> a
expectationFailed expected got =
    error
        ( "expected "
            <> expected
            <> " but got "
            <> show got
        )
