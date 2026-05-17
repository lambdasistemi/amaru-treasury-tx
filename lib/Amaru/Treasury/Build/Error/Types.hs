{- |
Module      : Amaru.Treasury.Build.Error.Types
Description : Structured treasury build failure data types
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0
-}
module Amaru.Treasury.Build.Error.Types
    ( ActionBuildError (..)
    , BuildDiagnostic (..)
    , BuildErrorContext (..)
    , BuildFailurePhase (..)
    , BuildAction (..)
    , BuildError (..)
    , actionBuildError
    , nestActionBuildError
    , buildError
    ) where

import Data.Text (Text)

import Cardano.Ledger.Coin (Coin)

-- | Treasury action whose build path produced a diagnostic.
data BuildAction
    = BuildActionSwap
    | BuildActionSwapCancel
    | BuildActionDisburse
    | BuildActionWithdraw
    | BuildActionReorganize
    | BuildActionIntent
    deriving stock (Eq, Show)

-- | Coarse phase where an expected build failure occurred.
data BuildFailurePhase
    = BuildPhaseTranslate
    | BuildPhaseGatherInputs
    | BuildPhaseBuild
    | BuildPhaseFeeAlignment
    | BuildPhaseUnsupported
    deriving stock (Eq, Show)

-- | Extra structured context added while an error moves outward.
data BuildErrorContext
    = ContextIntentAction !Text
    | ContextBuildPhase !BuildFailurePhase
    | ContextWalletInput !Text
    | ContextReportDestination !FilePath
    | ContextNetwork !Text
    deriving stock (Eq, Show)

-- | Stable project-owned build diagnostic.
data BuildDiagnostic
    = DiagnosticScriptEvaluationFailed !Text !Text
    | DiagnosticInsufficientFee !Coin !Coin
    | DiagnosticFeeNotConverged
    | DiagnosticCollateralShortfall !Coin !Coin
    | DiagnosticChecksFailed !Text
    | DiagnosticBumpFeeFailed !Text
    | DiagnosticMissingUtxos ![Text]
    | DiagnosticFeeAlignmentFailed !Text
    | DiagnosticTranslateFailed !Text
    | DiagnosticUnsupportedAction !Text
    | -- | Dispatcher-level network guard rejection. The
      --     payload is the offending @network@ string from
      --     the parsed intent (e.g. @\"mainnet\"@). Raised
      --     by 'Amaru.Treasury.Build.requireDevnet' for the
      --     seven init sub-actions, which are DevNet-only
      --     in the current rollout.
      DiagnosticUnsupportedNetwork !Text
    deriving stock (Eq, Show)

-- | Expected treasury build failure with stable rendering.
data BuildError = BuildError
    { beAction :: !BuildAction
    , bePhase :: !BuildFailurePhase
    , beContext :: ![BuildErrorContext]
    , beDiagnostic :: !BuildDiagnostic
    }
    deriving stock (Eq, Show)

data ActionBuildError = ActionBuildError
    { abePhase :: !BuildFailurePhase
    , abeContext :: ![BuildErrorContext]
    , abeDiagnostic :: !BuildDiagnostic
    }
    deriving stock (Eq, Show)

buildError
    :: BuildAction
    -> BuildFailurePhase
    -> BuildDiagnostic
    -> BuildError
buildError action phase diagnostic =
    BuildError
        { beAction = action
        , bePhase = phase
        , beContext = []
        , beDiagnostic = diagnostic
        }

actionBuildError
    :: BuildFailurePhase
    -> BuildDiagnostic
    -> ActionBuildError
actionBuildError phase diagnostic =
    ActionBuildError
        { abePhase = phase
        , abeContext = []
        , abeDiagnostic = diagnostic
        }

nestActionBuildError
    :: BuildAction
    -> ActionBuildError
    -> BuildError
nestActionBuildError action err =
    BuildError
        { beAction = action
        , bePhase = abePhase err
        , beContext = abeContext err
        , beDiagnostic = abeDiagnostic err
        }
