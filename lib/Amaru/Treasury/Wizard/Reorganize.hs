{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Wizard.Reorganize
Description : Pure-ish (no process exits) reorganize-wizard
              entry points (#280).
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Symmetric to 'Amaru.Treasury.Wizard.Swap' (#269) and
'Amaru.Treasury.Wizard.Disburse' (#277): non-CLI callers
(HTTP handlers, REPL, test harnesses) drive the reorganize
intent-construction and tx-build paths through the
typed-Either surfaces in this module instead of the CLI's
host-terminating wrappers.

Reuses 'WizardFailure' / 'BuildFailure' + 'projectBuildError'
from 'Wizard.Failure' / 'Wizard.Swap' since the typed
taxonomies are shared across all wizards — every wizard's
tx-build ultimately lands at
'Amaru.Treasury.Build.runFromIntentEither' and every
wizard's intent-construction lands at the same family of
operator-visible exit sites.
-}
module Amaru.Treasury.Wizard.Reorganize
    ( -- * Intent assembly (#280)
      buildReorganizeIntent

      -- * Tx-build (#280)
    , buildReorganizeTx
    ) where

import Control.Exception (SomeException, try)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (runExceptT, throwE)
import Control.Tracer (Tracer, traceWith)
import Data.List.NonEmpty qualified as NE
import Data.Set qualified as Set
import Data.Text qualified as T

import Ouroboros.Network.Magic (NetworkMagic (..))

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
    , resolveNetworkName
    )
import Amaru.Treasury.Cli.ReorganizeWizard
    ( CommonFlags (..)
    , ReorganizeWizardOpts (..)
    , mkLiveEnv
    , optsToAnswers
    , validateReorganizeWizardInputControl
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
import Amaru.Treasury.Scope (scopeText)
import Amaru.Treasury.Tx.ReorganizeWizard
    ( ReorganizeEnv (..)
    , ReorganizeError (..)
    , ReorganizeResolverInput (..)
    , renderReorganizeWalletShortfallWithExcludes
    , reorganizeToIntent
    , resolveReorganizeIC
    )
import Amaru.Treasury.Tx.ReorganizeWizard.Trace
    ( ReorganizeWizardEvent (..)
    )
import Amaru.Treasury.Tx.SwapWizard (WalletSelection (..))
import Amaru.Treasury.Wizard.Failure
    ( BuildFailure (..)
    , FieldId (..)
    , WizardFailure (..)
    )
import Amaru.Treasury.Wizard.InputControl
    ( outRefText
    , renderInputControlError
    )
import Amaru.Treasury.Wizard.Swap (projectBuildError)

-- ---------------------------------------------------------------------------
-- Intent assembly

{- | Pure-ish entry point for the reorganize-wizard intent
construction (no process exits).

Mirrors 'Amaru.Treasury.Wizard.Disburse.buildDisburseIntent'
from the moment the backend is open onward: validate input
controls, resolve the network, run the reorganize resolver
(metadata read + wallet UTxO query + treasury UTxO query +
upper-bound resolution), translate the resolved environment
to the typed intent, and return.  Every former
@runReorganizeWizardLive@ bail-out site is now a 'throwE'
of a typed 'WizardFailure' constructor via
'projectReorganizeError'.

The caller owns the 'Backend' lifetime — for the CLI, this
is the 'withLocalNodeBackend' bracket inside the wrapper;
for an HTTP server, this is a per-process backend handle
opened at server boot and reused across requests.

The CLI 'runReorganizeWizard' is left in place unchanged in
this slice so the branch stays bisect-safe; a later slice
will rewire it to delegate here.
-}
buildReorganizeIntent
    :: GlobalOpts
    -> ReorganizeWizardOpts
    -> Backend
    -> Tracer IO ReorganizeWizardEvent
    -> IO (Either WizardFailure SomeTreasuryIntent)
buildReorganizeIntent g opts@ReorganizeWizardOpts{rwoCommon = cf} backend tr =
    runExceptT $ do
        -- 1. Input-control validation (operator-supplied
        --    @--exclude-utxo@ / @--extra-tx-in@ sets).
        case validateReorganizeWizardInputControl cf of
            Right () -> pure ()
            Left ce ->
                throwE
                    ( InputControl
                        FieldExcludeUtxo
                        (renderInputControlError ce)
                    )

        -- 2. Network resolution from CLI flags.
        networkName <- case resolveNetworkName g of
            Right t -> pure t
            Left e -> throwE (ResolveNetworkUnsupported (T.pack e))

        let NetworkMagic magic = goNetworkMagic g
        liftIO
            ( traceWith
                tr
                (RweNetwork networkName (fromIntegral magic))
            )
        liftIO (traceWith tr (RweMetadata (cfMetadataPath cf)))

        -- 3. Resolver input + live env from the caller-owned
        --    'Backend'.  Same shape as
        --    'Cli.ReorganizeWizard.runReorganizeWizardLive'.
        let renv = mkLiveEnv backend
            input =
                ReorganizeResolverInput
                    { rriNetwork = networkName
                    , rriWalletAddrBech32 = cfWalletAddr cf
                    , rriMetadataPath = cfMetadataPath cf
                    , rriScope = cfScope cf
                    , rriValidityHours = cfValidityHours cf
                    }
        resolved <-
            liftIO
                ( resolveReorganizeIC
                    renv
                    (cfExcludeSet cf)
                    (cfForcedSet cf)
                    input
                )
        (env, _outcome) <- case resolved of
            Right ok -> pure ok
            Left e -> throwE (projectReorganizeError e)

        liftIO (traceWith tr (RweScopeResolved (cfScope cf)))
        liftIO
            ( traceWith
                tr
                ( RweWalletUtxoSelected
                    (wsTxIn (reWalletSelection env))
                )
            )
        liftIO
            ( traceWith
                tr
                ( RweTreasuryUtxosResolved
                    (NE.length (reTreasuryUtxos env))
                )
            )
        liftIO
            ( traceWith
                tr
                (RweUpperBoundResolved (reUpperBoundSlot env))
            )

        -- 4. Translate the resolved env + typed answers
        --    into the SReorganize intent.
        intent <-
            case reorganizeToIntent env (optsToAnswers opts) of
                Right i -> pure i
                Left e -> throwE (projectReorganizeError e)

        liftIO (traceWith tr (RweIntentReady (Just (cfOut cf))))
        pure intent

{- | Project a 'ReorganizeError' raised by the
reorganize-wizard resolver or translator into the
shared 'WizardFailure' taxonomy.

CLI pre-flight variants (output-path, network/socket
absence) should not arise inside 'buildReorganizeIntent' —
those checks live in the CLI shell ahead of the backend
open.  They are projected defensively into the catch-all
'ResolveResolver' so a wrapped caller never observes a
silently-dropped error.
-}
projectReorganizeError :: ReorganizeError -> WizardFailure
projectReorganizeError = \case
    ReorganizeValidityHoursZero ->
        InputOutOfRange FieldValidityHours "0"
    ReorganizeValidityOvershoot e ->
        ResolveValidityHorizon (T.pack (show e))
    ReorganizeLedgerFieldParseError field msg ->
        InternalTranslate
            ( "ledger field "
                <> field
                <> ": "
                <> T.pack msg
            )
    ReorganizeMetadataReadError s ->
        ResolveRegistryVerify ("verify: " <> T.pack s)
    ReorganizeScopeNotInMetadata sc ->
        ResolveRegistryVerify
            ("scope not in metadata: " <> scopeText sc)
    ReorganizeScopeOwnerMissing sc ->
        ResolveRegistryVerify
            ("scope owner missing: " <> scopeText sc)
    ReorganizeResolverExtraTxInNotOnWallet refs ->
        ResolveResolver
            ( "reorganize-wizard: extra input not found on wallet: "
                <> T.intercalate ", " (map outRefText refs)
            )
    ReorganizeResolverWalletShortfallWithExcludes
        avail
        required
        refs ->
            ResolveResolver
                ( renderReorganizeWalletShortfallWithExcludes
                    ( "wallet shortfall available="
                        <> T.pack (show avail)
                        <> " required="
                        <> T.pack (show required)
                    )
                    refs
                )
    other ->
        ResolveResolver ("resolve: " <> T.pack (show other))

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
