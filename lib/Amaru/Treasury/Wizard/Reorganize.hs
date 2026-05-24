{- |
Module      : Amaru.Treasury.Wizard.Reorganize
Description : Pure-ish (no process exits) reorganize-wizard
              tx-build entry point (#280).
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Symmetric to 'Amaru.Treasury.Wizard.Swap' (#269) and
'Amaru.Treasury.Wizard.Disburse' (#277): non-CLI callers
(HTTP handlers, REPL, test harnesses) drive the reorganize
tx-build path through the typed-Either surface in this
module instead of the CLI's host-terminating wrappers.

Reuses 'BuildFailure' + 'projectBuildError' from
'Wizard.Failure' / 'Wizard.Swap' since the typed
build-side taxonomy is shared across all wizards — every
wizard's tx-build ultimately lands at
'Amaru.Treasury.Build.runFromIntentEither' and every
wizard's failure path lands at the same family of
operator-visible exit sites.
-}
module Amaru.Treasury.Wizard.Reorganize
    ( -- * Tx-build (#280)
      buildReorganizeTx
    ) where

import Control.Exception (SomeException, try)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (runExceptT, throwE)
import Control.Tracer (Tracer, traceWith)
import Data.Set qualified as Set
import Data.Text qualified as T

import Amaru.Treasury.Backend (Backend)
import Amaru.Treasury.Build
    ( BuildResult (..)
    , runFromIntentEither
    )
import Amaru.Treasury.Build.Trace
    ( BuildEvent (..)
    )
import Amaru.Treasury.ChainContext
    ( liveContext
    , networkFromMagic
    )
import Amaru.Treasury.Cli.Common
    ( GlobalOpts (..)
    )
import Amaru.Treasury.Cli.TxBuild
    ( requiredUtxos
    , txBuildReportContext
    )
import Amaru.Treasury.IntentJSON
    ( SomeTreasuryIntent
    )
import Amaru.Treasury.Report
    ( TxBuildSuccess (..)
    , buildTransactionReport
    , txCborHexFromBytes
    )
import Amaru.Treasury.Wizard.Failure
    ( BuildFailure (..)
    )
import Amaru.Treasury.Wizard.Swap (projectBuildError)

-- ---------------------------------------------------------------------------
-- Tx-build

{- | Pure-Either tx-build entry point for the reorganize
wizard.  Same shape as
'Amaru.Treasury.Wizard.Swap.buildSwapTx' (#269) and
'Amaru.Treasury.Wizard.Disburse.buildDisburseTx' (#277) —
caller-owned 'Backend', informational tracer, typed 'Left'
on every failure path.

The reorganize intent passed in must carry @SReorganize@
as its tag; @runFromIntentEither@ dispatches on the GADT
and calls the matching @runReorganizeAction@.  The same
projection 'projectBuildError' is reused since every
wizard's tx-build pipeline lands at the same shared typed
'BuildError' taxonomy.
-}
buildReorganizeTx
    :: GlobalOpts
    -> Backend
    -> SomeTreasuryIntent
    -> Tracer IO BuildEvent
    -> IO (Either BuildFailure TxBuildSuccess)
buildReorganizeTx g backend some tr = runExceptT $ do
    required <- case requiredUtxos some of
        Left e ->
            throwE (BuildResolveUtxo (T.pack e))
        Right s -> pure s
    liftIO
        ( traceWith
            tr
            (BuildEventRequiredUtxos (Set.size required))
        )

    let magic = goNetworkMagic g
        network = networkFromMagic magic
    ctxResult <-
        liftIO
            ( try @SomeException
                (liveContext network backend required)
            )
    ctx <- case ctxResult of
        Left e ->
            throwE (BuildResolveTip (T.pack (show e)))
        Right c -> pure c

    result <- liftIO (runFromIntentEither ctx some)
    br <- case result of
        Left be -> throwE (projectBuildError be)
        Right b -> pure b

    pure
        TxBuildSuccess
            { tbsTxCbor =
                txCborHexFromBytes (brCborBytes br)
            , tbsReport =
                buildTransactionReport
                    (txBuildReportContext some magic)
                    br
            }
