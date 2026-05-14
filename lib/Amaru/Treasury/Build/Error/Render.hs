{- |
Module      : Amaru.Treasury.Build.Error.Render
Description : Render structured treasury build failures
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0
-}
module Amaru.Treasury.Build.Error.Render
    ( renderBuildError
    , buildErrorCode
    ) where

import Data.Text (Text)
import Data.Text qualified as T

import Cardano.Ledger.Coin (Coin (..))

import Amaru.Treasury.Build.Error.Types
    ( BuildAction (..)
    , BuildDiagnostic (..)
    , BuildError (..)
    , BuildErrorContext (..)
    , BuildFailurePhase (..)
    )

buildErrorCode :: BuildError -> Text
buildErrorCode err =
    case beDiagnostic err of
        DiagnosticScriptEvaluationFailed{} ->
            "script-evaluation-failed"
        DiagnosticInsufficientFee{} ->
            "insufficient-fee-capacity"
        DiagnosticFeeNotConverged ->
            "fee-not-converged"
        DiagnosticCollateralShortfall{} ->
            "collateral-shortfall"
        DiagnosticChecksFailed{} ->
            "final-validation-failed"
        DiagnosticBumpFeeFailed{} ->
            "fee-bump-failed"
        DiagnosticMissingUtxos{} ->
            "missing-utxos"
        DiagnosticFeeAlignmentFailed{} ->
            "fee-alignment-failed"
        DiagnosticTranslateFailed{} ->
            "intent-translation-failed"
        DiagnosticUnsupportedAction{} ->
            "unsupported-action"

renderBuildError :: BuildError -> Text
renderBuildError err =
    "tx-build: "
        <> renderAction (beAction err)
        <> " failed "
        <> renderPhase (bePhase err)
        <> ": "
        <> renderDiagnostic (beDiagnostic err)
        <> renderContexts (beContext err)

renderAction :: BuildAction -> Text
renderAction = \case
    BuildActionSwap -> "swap"
    BuildActionSwapCancel -> "swap-cancel"
    BuildActionDisburse -> "disburse"
    BuildActionWithdraw -> "withdraw"
    BuildActionReorganize -> "reorganize"
    BuildActionIntent -> "intent"

renderPhase :: BuildFailurePhase -> Text
renderPhase = \case
    BuildPhaseTranslate -> "while translating the intent"
    BuildPhaseGatherInputs -> "while gathering inputs"
    BuildPhaseBuild -> "while building the transaction"
    BuildPhaseFeeAlignment -> "while aligning the final fee"
    BuildPhaseUnsupported -> "because the action is unsupported"

renderDiagnostic :: BuildDiagnostic -> Text
renderDiagnostic = \case
    DiagnosticScriptEvaluationFailed purpose reason ->
        "script evaluation failed for "
            <> purpose
            <> ": "
            <> reason
    DiagnosticInsufficientFee (Coin required) (Coin available) ->
        "insufficient fee capacity; required lovelace: "
            <> T.pack (show required)
            <> "; available lovelace: "
            <> T.pack (show available)
    DiagnosticFeeNotConverged ->
        "fee did not converge; retry with fresh chain state or report protocol-parameter drift"
    DiagnosticCollateralShortfall (Coin required) (Coin available) ->
        "collateral shortfall; required collateral lovelace: "
            <> T.pack (show required)
            <> "; available collateral lovelace: "
            <> T.pack (show available)
    DiagnosticChecksFailed checks ->
        "final validation checks failed: " <> checks
    DiagnosticBumpFeeFailed reason ->
        "fee bump failed: " <> reason
    DiagnosticMissingUtxos missing ->
        "missing required UTxOs from the chain context: "
            <> T.intercalate ", " missing
    DiagnosticFeeAlignmentFailed reason ->
        "fee alignment failed: " <> reason
    DiagnosticTranslateFailed reason ->
        "intent translation failed: " <> reason
    DiagnosticUnsupportedAction action ->
        action <> " is not implemented"

renderContexts :: [BuildErrorContext] -> Text
renderContexts [] = ""
renderContexts contexts =
    " (context: "
        <> T.intercalate "; " (renderContext <$> contexts)
        <> ")"

renderContext :: BuildErrorContext -> Text
renderContext = \case
    ContextIntentAction action ->
        "action=" <> action
    ContextBuildPhase phase ->
        "phase=" <> T.pack (show phase)
    ContextWalletInput input ->
        "wallet-input=" <> input
    ContextReportDestination path ->
        "report=" <> T.pack path
    ContextNetwork network ->
        "network=" <> network
