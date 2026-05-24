{- |
Module      : Amaru.Treasury.Wizard.Disburse
Description : Pure-ish (no process exits) disburse tx-build
              entry point (#277).
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Symmetric to 'Amaru.Treasury.Wizard.Swap.buildSwapTx'
(#269): non-CLI callers (HTTP handlers, REPL, test
harnesses) drive the disburse tx-build path through this
typed-Either surface instead of the CLI's host-terminating
wrapper.

Reuses 'BuildFailure' + 'projectBuildError' from
'Wizard.Swap' since the build-side typed taxonomy is
shared across all wizards — every wizard's tx-build
ultimately lands at 'Amaru.Treasury.Build.runFromIntentEither'.

'buildDisburseIntent' (the analogue of 'buildSwapIntent')
lands in a follow-up slice within this PR.
-}
module Amaru.Treasury.Wizard.Disburse
    ( buildDisburseTx
    ) where

import Control.Exception (SomeException, try)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (runExceptT, throwE)
import Control.Tracer (Tracer (..), traceWith)
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
import Amaru.Treasury.Cli.Common (GlobalOpts (..))
import Amaru.Treasury.Cli.TxBuild
    ( requiredUtxos
    , txBuildReportContext
    )
import Amaru.Treasury.IntentJSON (SomeTreasuryIntent (..))
import Amaru.Treasury.Report
    ( TxBuildSuccess (..)
    , buildTransactionReport
    , txCborHexFromBytes
    )
import Amaru.Treasury.Wizard.Failure (BuildFailure (..))
import Amaru.Treasury.Wizard.Swap (projectBuildError)

{- | Pure-Either tx-build entry point for the disburse
wizard.  Same shape as 'Amaru.Treasury.Wizard.Swap.buildSwapTx'
(#269) — caller-owned 'Backend', informational tracer,
typed 'Left' on every failure path.

The disburse intent passed in must carry @SDisburse@ as
its tag; @runFromIntentEither@ dispatches on the GADT and
calls the matching @runDisburseAction@.  Same projection
'projectBuildError' is reused since every wizard's
tx-build pipeline lands at the same shared typed
'BuildError' taxonomy.
-}
buildDisburseTx
    :: GlobalOpts
    -> Backend
    -> SomeTreasuryIntent
    -> Tracer IO BuildEvent
    -> IO (Either BuildFailure TxBuildSuccess)
buildDisburseTx g backend some tr = runExceptT $ do
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
