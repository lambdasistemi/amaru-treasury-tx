{- |
Module      : Amaru.Treasury.Build.Error.Convert
Description : Convert lower-level build failures into treasury diagnostics
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0
-}
module Amaru.Treasury.Build.Error.Convert
    ( diagnosticFromTxBuildError
    , missingUtxosError
    , runActionBuild
    , throwBuildException
    , buildErrorFromTxBuildError
    ) where

import Control.Exception (throwIO)
import Control.Monad.Trans.Except
    ( ExceptT
    , runExceptT
    , withExceptT
    )
import Data.Text qualified as T

import Cardano.Ledger.TxIn (TxIn)
import Cardano.Node.Client.Balance (BalanceError (..))
import Cardano.Node.Client.TxBuild qualified as TxBuild

import Amaru.Treasury.Build.Error.Exception
    ( BuildException (..)
    )
import Amaru.Treasury.Build.Error.Types
    ( ActionBuildError
    , BuildAction
    , BuildDiagnostic (..)
    , BuildError
    , BuildFailurePhase (..)
    , actionBuildError
    , buildError
    , nestActionBuildError
    )

buildErrorFromTxBuildError
    :: BuildAction
    -> BuildFailurePhase
    -> TxBuild.BuildError ()
    -> BuildError
buildErrorFromTxBuildError action phase =
    buildError action phase . diagnosticFromTxBuildError

diagnosticFromTxBuildError :: TxBuild.BuildError () -> BuildDiagnostic
diagnosticFromTxBuildError = \case
    TxBuild.EvalFailure purpose reason ->
        DiagnosticScriptEvaluationFailed
            (T.pack (show purpose))
            (T.pack reason)
    TxBuild.BalanceFailed balanceError ->
        diagnosticFromBalanceError balanceError
    TxBuild.ChecksFailed checks ->
        DiagnosticChecksFailed (T.pack (show checks))
    TxBuild.BumpFeeFailed reason ->
        DiagnosticBumpFeeFailed (T.pack reason)

diagnosticFromBalanceError :: BalanceError -> BuildDiagnostic
diagnosticFromBalanceError = \case
    InsufficientFee required available ->
        DiagnosticInsufficientFee required available
    FeeNotConverged ->
        DiagnosticFeeNotConverged
    CollateralShortfall required available ->
        DiagnosticCollateralShortfall required available

throwBuildException :: BuildError -> IO a
throwBuildException =
    throwIO . BuildException

runActionBuild
    :: BuildAction
    -> ExceptT ActionBuildError IO a
    -> IO a
runActionBuild action buildAction = do
    result <-
        runExceptT $
            withExceptT (nestActionBuildError action) buildAction
    either throwBuildException pure result

missingUtxosError :: [TxIn] -> ActionBuildError
missingUtxosError missing =
    actionBuildError
        BuildPhaseGatherInputs
        (DiagnosticMissingUtxos (T.pack . show <$> missing))
