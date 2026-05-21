{-# LANGUAGE GADTs #-}

{- |
Module      : Amaru.Treasury.Build
Description : Unified IO build pipeline dispatcher
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Single dispatcher that consumes a 'SomeTreasuryIntent'
or a typed @'TreasuryIntent' a@ and runs the matching
per-action build pipeline. Keeps the pure builders
('Tx.Swap.swapProgram',
'Tx.Disburse.disburseAdaProgram', …) untouched —
'runBuild' is just the IO seam that selects which one to
call.

The action-specific IO runners live under this hierarchy:

* "Amaru.Treasury.Build.Swap"
* "Amaru.Treasury.Build.SwapCancel"
* "Amaru.Treasury.Build.Disburse"
* "Amaru.Treasury.Build.Withdraw"

Shared result, trace, report-writer, and diagnostic types live under
"Amaru.Treasury.Build.Result", "Amaru.Treasury.Build.Trace",
"Amaru.Treasury.Build.ReportWriter", and "Amaru.Treasury.Build.Error".
-}
module Amaru.Treasury.Build
    ( -- * Outputs and diagnostics
      module Amaru.Treasury.Build.Error
    , module Amaru.Treasury.Build.Result

      -- * Drivers
    , runBuild
    , runFromIntent
    , runFromIntentEither
    , runDisburse
    , runReorganizeBuild
    , runSwap
    , runSwapCancel
    , runWithdraw

      -- * Network guard
    , requireDevnet
    ) where

import Control.Monad (unless)
import Control.Monad.Trans.Except
    ( ExceptT
    , runExceptT
    , throwE
    , withExceptT
    )
import Data.Text (Text)
import Data.Text qualified as T

import Amaru.Treasury.Build.Disburse
    ( runDisburse
    , runDisburseAction
    )
import Amaru.Treasury.Build.Error
import Amaru.Treasury.Build.Error.Convert
    ( throwBuildException
    )
import Amaru.Treasury.Build.GovernanceWithdrawalInit
    ( runGovernanceWithdrawalInitMaterializationAction
    , runGovernanceWithdrawalInitProposalAction
    )
import Amaru.Treasury.Build.RegistryInit
    ( runRegistryInitMintAction
    , runRegistryInitReferenceScriptsAction
    , runRegistryInitSeedSplitAction
    )
import Amaru.Treasury.Build.Reorganize
    ( runReorganizeAction
    , runReorganizeBuild
    )
import Amaru.Treasury.Build.Result
import Amaru.Treasury.Build.StakeRewardInit
    ( runStakeRewardInitPlainAccountAction
    , runStakeRewardInitScriptAccountAction
    )
import Amaru.Treasury.Build.Swap
    ( runSwap
    , runSwapAction
    )
import Amaru.Treasury.Build.SwapCancel
    ( runSwapCancel
    )
import Amaru.Treasury.Build.Withdraw
    ( runWithdraw
    , runWithdrawAction
    )
import Amaru.Treasury.ChainContext (ChainContext)
import Amaru.Treasury.IntentJSON
    ( SAction (..)
    , SomeTreasuryIntent (..)
    , Translated
    , TranslatedShared (..)
    , translateIntent
    )

{- | Action-polymorphic build entry. The type-family
makes @a@ pick the right translated record at each call
site. The case on @SAction a@ is the only place a
runtime selection appears; once inside a branch, the
type family pins down @Translated a@ and the runner is
fully type-safe.
-}
runBuild
    :: ChainContext
    -> TranslatedShared
    -> SAction a
    -> Translated a
    -> IO BuildResult
runBuild ctx shared sa translated = do
    result <- runExceptT (runBuildExcept ctx shared sa translated)
    either throwBuildException pure result

runBuildExcept
    :: ChainContext
    -> TranslatedShared
    -> SAction a
    -> Translated a
    -> ExceptT BuildError IO BuildResult
runBuildExcept ctx shared sa translated = case sa of
    SSwap ->
        withExceptT
            (nestActionBuildError BuildActionSwap)
            ( runSwapAction
                ctx
                translated
                (tsRationale shared)
                (tsWalletTxIn shared)
                (tsWalletAddr shared)
            )
    SDisburse ->
        withExceptT
            (nestActionBuildError BuildActionDisburse)
            ( runDisburseAction
                ctx
                translated
                (tsRationale shared)
                (tsWalletAddr shared)
            )
    SWithdraw ->
        withExceptT
            (nestActionBuildError BuildActionWithdraw)
            ( runWithdrawAction
                ctx
                translated
                (tsRationale shared)
                (tsWalletAddr shared)
            )
    SReorganize ->
        withExceptT
            (nestActionBuildError BuildActionReorganize)
            ( runReorganizeAction
                ctx
                translated
                (tsRationale shared)
                (tsWalletAddr shared)
            )
    SRegistryInitSeedSplit -> do
        requireDevnet (tsNetwork shared)
        withExceptT
            (nestActionBuildError BuildActionIntent)
            (runRegistryInitSeedSplitAction ctx translated)
    SRegistryInitMint -> do
        requireDevnet (tsNetwork shared)
        withExceptT
            (nestActionBuildError BuildActionIntent)
            (runRegistryInitMintAction ctx translated)
    SRegistryInitReferenceScripts -> do
        requireDevnet (tsNetwork shared)
        withExceptT
            (nestActionBuildError BuildActionIntent)
            (runRegistryInitReferenceScriptsAction ctx translated)
    SStakeRewardInitScriptAccount -> do
        requireDevnet (tsNetwork shared)
        withExceptT
            (nestActionBuildError BuildActionIntent)
            (runStakeRewardInitScriptAccountAction ctx translated)
    SStakeRewardInitPlainAccount -> do
        requireDevnet (tsNetwork shared)
        withExceptT
            (nestActionBuildError BuildActionIntent)
            (runStakeRewardInitPlainAccountAction ctx translated)
    SGovernanceWithdrawalInitProposal -> do
        requireDevnet (tsNetwork shared)
        withExceptT
            (nestActionBuildError BuildActionIntent)
            ( runGovernanceWithdrawalInitProposalAction
                ctx
                translated
            )
    SGovernanceWithdrawalInitMaterialization -> do
        requireDevnet (tsNetwork shared)
        withExceptT
            (nestActionBuildError BuildActionIntent)
            ( runGovernanceWithdrawalInitMaterializationAction
                ctx
                translated
            )

{- | Dispatcher-level network guard for the init sub-actions.

The seven @registry-init-*@, @stake-reward-init-*@, and
@governance-withdrawal-init-*@ intents are DevNet-only in the
current rollout. The decoder still accepts any @network: Text@
value (parsing is not the right layer for runtime policy), but
'runBuildExcept' calls this helper first on every init arm so
the dispatcher fails closed with a typed 'BuildError' before
any N2C connection or transaction construction happens.

The rejection carries 'BuildActionIntent' (the umbrella action
shared by all init arms), 'BuildPhaseUnsupported' (this network
is not supported in this phase of the #156 rollout), and
'DiagnosticUnsupportedNetwork' with the offending text.
-}
requireDevnet :: Text -> ExceptT BuildError IO ()
requireDevnet network =
    unless (network == "devnet") $
        throwE $
            buildError
                BuildActionIntent
                BuildPhaseUnsupported
                (DiagnosticUnsupportedNetwork network)

{- | Caller-friendly wrapper for the parser's existential
return type. Decodes-then-translates-then-builds.
-}
runFromIntent
    :: ChainContext
    -> SomeTreasuryIntent
    -> IO BuildResult
runFromIntent ctx some = do
    result <- runFromIntentEither ctx some
    either throwBuildException pure result

runFromIntentEither
    :: ChainContext
    -> SomeTreasuryIntent
    -> IO (Either BuildError BuildResult)
runFromIntentEither ctx (SomeTreasuryIntent sa intent) =
    runExceptT $ do
        case translateIntent sa intent of
            Left e ->
                throwE $
                    buildError
                        BuildActionIntent
                        BuildPhaseTranslate
                        (DiagnosticTranslateFailed (T.pack e))
            Right (shared, translated) ->
                runBuildExcept ctx shared sa translated
