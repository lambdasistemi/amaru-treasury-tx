{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

{- |
Module      : Amaru.Treasury.Wizard.Disburse
Description : Pure-ish (no process exits) disburse-wizard
              entry points (#277).
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Symmetric to 'Amaru.Treasury.Wizard.Swap' (#259 / #269):
non-CLI callers (HTTP handlers, REPL, test harnesses) drive
the disburse intent-construction and tx-build paths through
the typed-Either surfaces in this module instead of the
CLI's host-terminating wrappers.

Reuses 'WizardFailure' / 'BuildFailure' + 'projectBuildError'
from 'Wizard.Swap' / 'Wizard.Failure' since the typed
taxonomies are shared across all wizards — every wizard's
tx-build ultimately lands at
'Amaru.Treasury.Build.runFromIntentEither' and every
wizard's intent-construction lands at the same family of
operator-visible exit sites.
-}
module Amaru.Treasury.Wizard.Disburse
    ( -- * Intent assembly (#277)
      buildDisburseIntent

      -- * Tx-build (#277)
    , buildDisburseTx
    ) where

import Control.Exception (SomeException, try)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (runExceptT, throwE)
import Control.Tracer (Tracer, traceWith)
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
import Amaru.Treasury.Cli.DisburseWizard
    ( DisburseWizardOpts (..)
    , providerToDisburseResolverEnv
    , traceDisburseEnv
    , traceDisburseRegistryView
    , traceDisburseResolverEnv
    , validateDisburseWizardInputControl
    , verifyDisburseRegistry
    )
import Amaru.Treasury.Cli.TxBuild
    ( requiredUtxos
    , txBuildReportContext
    )
import Amaru.Treasury.IntentJSON
    ( SAction (..)
    , SomeTreasuryIntent (..)
    , tiValidityUpperBoundSlot
    )
import Amaru.Treasury.Report
    ( TxBuildSuccess (..)
    , buildTransactionReport
    , txCborHexFromBytes
    )
import Amaru.Treasury.Tx.DisburseWizard qualified as Disburse
import Amaru.Treasury.Tx.DisburseWizard.Trace
    ( DisburseWizardEvent (..)
    )
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

{- | Pure-ish entry point for the disburse-wizard intent
construction (no process exits).

Mirrors 'Amaru.Treasury.Wizard.Swap.buildSwapIntent' from
the moment the backend is open onward: validate input
controls, resolve the network, verify the registry, resolve
the disburse env (with operator-supplied exclusion / forced
sets), translate to the typed intent, and return.  Every
former @abortDisburse@ site in
'Amaru.Treasury.Cli.DisburseWizard.runDisburseCommand' is
now a 'throwE' of a typed 'WizardFailure' constructor.

The caller owns the 'Backend' lifetime — for the CLI, this
is the 'withLocalNodeBackend' bracket inside the wrapper;
for an HTTP server, this is a per-process backend handle
opened at server boot and reused across requests.

Scope: this slice ports the @disburse-wizard@ subcommand
only.  The narrower @contingency-disburse-wizard@ path
(distinct in source scope, beneficiary derivation, and
default rationale shape) will land in a separate entry
point alongside this one.  The CLI 'runDisburseWizard' /
'runContingencyDisburse' are left in place unchanged;
later slices rewire them to delegate here.
-}
buildDisburseIntent
    :: GlobalOpts
    -> DisburseWizardOpts
    -> Backend
    -> Tracer IO DisburseWizardEvent
    -> IO (Either WizardFailure SomeTreasuryIntent)
buildDisburseIntent g opts@DisburseWizardOpts{..} backend tr =
    runExceptT $ do
        -- 1. Input-control validation (operator-supplied
        --    @--exclude-utxo@ / @--extra-tx-in@ sets).
        case validateDisburseWizardInputControl opts of
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
                (DweNetwork networkName (fromIntegral magic))
            )
        liftIO (traceWith tr (DweMetadata dwOptsMetadataPath))

        -- 3. Registry verification + projection.
        verified <-
            liftIO
                ( verifyDisburseRegistry
                    backend
                    dwOptsMetadataPath
                    (Set.singleton dwOptsScope)
                    networkName
                )
        rv <- case verified of
            Left e ->
                throwE
                    ( ResolveRegistryVerify
                        ("verify: " <> T.pack (show e))
                    )
            Right registry ->
                case Disburse.registryViewFromVerified
                    dwOptsScope
                    registry of
                    Left e ->
                        throwE
                            ( ResolveRegistryVerify
                                ("project: " <> T.pack (show e))
                            )
                    Right view -> pure view

        liftIO (traceDisburseRegistryView tr dwOptsScope rv)
        let renv =
                traceDisburseResolverEnv tr $
                    providerToDisburseResolverEnv backend

        -- 4. Build the answers + resolver input.  For the
        --    @disburse-wizard@ subcommand these are derived
        --    directly from the operator flags; the
        --    @contingency-disburse-wizard@ variant uses a
        --    different derivation and will live in a sibling
        --    entry point.
        let answers =
                Disburse.DisburseAnswers
                    { Disburse.daScope = dwOptsScope
                    , Disburse.daUnit = dwOptsUnit
                    , Disburse.daAmount = dwOptsAmount
                    , Disburse.daBeneficiaryAddrBech32 =
                        dwOptsBeneficiaryAddr
                    , Disburse.daValidityHours = dwOptsValidityHours
                    , Disburse.daRationale =
                        Disburse.RationaleAnswers
                            { Disburse.raDescription =
                                dwOptsDescription
                            , Disburse.raJustification =
                                dwOptsJustification
                            , Disburse.raDestinationLabel =
                                dwOptsDestinationLabel
                            , Disburse.raEvent = dwOptsEvent
                            , Disburse.raLabel = dwOptsLabel
                            }
                    , Disburse.daRationaleReferences =
                        dwOptsReferences
                    , Disburse.daExtraSigners = dwOptsSigners
                    }
            ri =
                Disburse.ResolverInput
                    { Disburse.riNetwork = networkName
                    , Disburse.riWalletAddrBech32 =
                        dwOptsWalletAddr
                    , Disburse.riBeneficiaryAddrBech32 =
                        dwOptsBeneficiaryAddr
                    , Disburse.riScope = dwOptsScope
                    , Disburse.riUnit = dwOptsUnit
                    , Disburse.riAmount = dwOptsAmount
                    , Disburse.riRegistry = rv
                    , Disburse.riValidityHours =
                        dwOptsValidityHours
                    , Disburse.riTreasuryTxIns =
                        dwOptsTreasuryTxIns
                    }

        -- 5. Resolve the chain-derived disburse env.
        er <-
            liftIO
                ( Disburse.resolveDisburseEnvIC
                    renv
                    dwOptsExcludeSet
                    dwOptsForcedSet
                    ri
                )
        env <- case er of
            Left
                (Disburse.ResolverExtraTxInNotOnWallet refs) ->
                    throwE
                        ( ResolveResolver
                            ( "disburse-wizard: extra input not found on wallet: "
                                <> T.intercalate
                                    ", "
                                    (map outRefText refs)
                            )
                        )
            Left
                ( Disburse.ResolverWalletShortfallWithExcludes
                        avail
                        required
                        refs
                    ) ->
                    throwE
                        ( ResolveResolver
                            ( Disburse.renderDisburseWalletShortfallWithExcludes
                                ( "wallet shortfall available="
                                    <> T.pack (show avail)
                                    <> " required="
                                    <> T.pack (show required)
                                )
                                refs
                            )
                        )
            Left
                ( Disburse.ResolverTreasuryShortfallWithExcludes
                        avail
                        required
                        refs
                    ) ->
                    throwE
                        ( ResolveResolver
                            ( Disburse.renderDisburseWalletShortfallWithExcludes
                                ( "treasury shortfall available="
                                    <> T.pack (show avail)
                                    <> " required="
                                    <> T.pack (show required)
                                )
                                refs
                            )
                        )
            Left e ->
                throwE
                    ( ResolveResolver
                        ("resolve: " <> T.pack (show e))
                    )
            Right (e, _outcome) -> pure e

        liftIO (traceDisburseEnv tr env)

        -- 6. Translate operator answers into the typed intent.
        intent <-
            case Disburse.disburseToTreasuryIntent env answers of
                Left de ->
                    throwE
                        ( InternalTranslate
                            ( "translate: "
                                <> T.pack
                                    ( show
                                        (de :: Disburse.DisburseError)
                                    )
                            )
                        )
                Right i -> pure i

        -- 7. Trailing trace events (CLI byte-identity).
        liftIO
            ( traceWith tr $
                DweUpperBoundResolved
                    (tiValidityUpperBoundSlot intent)
            )
        liftIO (traceWith tr (DweIntentReady dwOptsOut))

        pure (SomeTreasuryIntent SDisburse intent)

-- ---------------------------------------------------------------------------
-- Tx-build

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
