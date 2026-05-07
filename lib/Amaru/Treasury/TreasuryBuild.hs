{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}

{- |
Module      : Amaru.Treasury.TreasuryBuild
Description : Unified IO build pipeline (action-polymorphic)
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Single dispatcher that consumes a 'SomeTreasuryIntent'
or a typed @'TreasuryIntent' a@ and runs the matching
per-action build pipeline. Keeps the pure builders
('Tx.Swap.swapProgram',
'Tx.Disburse.disburseAdaProgram', …) untouched —
'runBuild' is just the IO seam that selects which one to
call.

In this phase-4 cut only the swap branch is wired; the
others are 'throwIO' stubs. Disburse comes online when
[#47](https://github.com/lambdasistemi/amaru-treasury-tx/pull/47)
rebases on top of this PR's merge commit (tracked under
[#55](https://github.com/lambdasistemi/amaru-treasury-tx/issues/55)).
Withdraw and reorganize land with
[#45](https://github.com/lambdasistemi/amaru-treasury-tx/issues/45)
and
[#46](https://github.com/lambdasistemi/amaru-treasury-tx/issues/46).
-}
module Amaru.Treasury.TreasuryBuild
    ( -- * Outputs
      TreasuryBuildResult (..)
    , ScriptResult (..)

      -- * Driver
    , runBuild
    , runFromIntent
    ) where

import Control.Exception (throwIO)
import Data.ByteString.Lazy qualified as BSL

import Cardano.Ledger.Coin (Coin)

import Amaru.Treasury.ChainContext (ChainContext)
import Amaru.Treasury.IntentJSON
    ( Action (..)
    , SAction (..)
    , SomeTreasuryIntent (..)
    , Translated
    , TranslatedShared (..)
    , translateIntent
    )
import Amaru.Treasury.Tx.SwapBuild
    ( ScriptResult (..)
    , SwapBuildInputs (..)
    , SwapBuildResult (..)
    , runSwapBuild
    )

{- | What the build pipeline returns. Field set is
identical to today's @SwapBuildResult@ /
@DisburseBuildResult@ — just renamed under the
unified module.
-}
data TreasuryBuildResult = TreasuryBuildResult
    { tbrCborBytes :: !BSL.ByteString
    -- ^ raw Conway tx CBOR
    , tbrFeeLovelace :: !Coin
    -- ^ fee assigned by 'build'
    , tbrTotalCollateralLovelace :: !Coin
    -- ^ @total_collateral@ as recorded in the final
    --     body. 'Coin' 0 if the body has no
    --     @total_collateral@ field (a non-script tx).
    , tbrScriptResults :: ![ScriptResult]
    -- ^ outcome of re-evaluating every redeemer on the
    --     fully-balanced tx
    }

-- ----------------------------------------------------
-- Driver
-- ----------------------------------------------------

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
    -> IO TreasuryBuildResult
runBuild ctx shared sa translated = case sa of
    SSwap -> runSwap ctx shared translated
    SDisburse ->
        throwIO . userError $
            "runBuild: 'disburse' lands when feature 004 PR #47"
                <> " rebases on top of this commit (tracked"
                <> " under #55)"
    SWithdraw ->
        throwIO . userError $
            "runBuild: 'withdraw' not yet shipped (#45)"
    SReorganize ->
        throwIO . userError $
            "runBuild: 'reorganize' not yet shipped (#46)"

{- | Caller-friendly wrapper for the parser's existential
return type. Decodes-then-translates-then-builds.
-}
runFromIntent
    :: ChainContext
    -> SomeTreasuryIntent
    -> IO TreasuryBuildResult
runFromIntent ctx (SomeTreasuryIntent sa intent) = do
    case translateIntent sa intent of
        Left e ->
            throwIO . userError $
                "runFromIntent: translate: " <> e
        Right (shared, translated) ->
            runBuild ctx shared sa translated

-- ----------------------------------------------------
-- Swap runner
-- ----------------------------------------------------

{- | The swap-action build runner. Delegates to the
existing 'runSwapBuild'; this wrapper just adapts the
record shape (TranslatedShared + Translated 'Swap →
SwapBuildInputs).

The @runSwapBuild@ body itself moves into this module
in T028 once 'Amaru.Treasury.Tx.SwapBuild' is collapsed.
-}
runSwap
    :: ChainContext
    -> TranslatedShared
    -> Translated 'Swap
    -> IO TreasuryBuildResult
runSwap ctx shared swapIntent = do
    let inputs =
            SwapBuildInputs
                { sbiIntent = swapIntent
                , sbiRationale = tsRationale shared
                , sbiWalletTxIn = tsWalletTxIn shared
                , sbiWalletAddr = tsWalletAddr shared
                }
    sbr <- runSwapBuild ctx inputs
    pure
        TreasuryBuildResult
            { tbrCborBytes = sbrCborBytes sbr
            , tbrFeeLovelace = sbrFeeLovelace sbr
            , tbrTotalCollateralLovelace =
                sbrTotalCollateralLovelace sbr
            , tbrScriptResults = sbrScriptResults sbr
            }
