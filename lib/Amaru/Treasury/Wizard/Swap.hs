{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

{- |
Module      : Amaru.Treasury.Wizard.Swap
Description : Pure-ish (no process exits) swap-wizard
              entry points (#259).
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

This module is the typed surface a non-CLI caller — an HTTP
handler, a GUI, a test harness — uses to drive the
swap-wizard pipeline without crashing the host process on a
validation error.

'buildSwapIntent' carries the same IO sequence the existing
'Amaru.Treasury.Cli.SwapWizard.runWizard' performs, with
every @abortTr@ exit-on-error site replaced by a typed
'Left' return.  The CLI 'runWizard' is left in place
unchanged in this commit so the branch stays bisect-safe;
Phase 4 of #259 will rewire it to delegate here.
-}
module Amaru.Treasury.Wizard.Swap
    ( -- * Pure-Either resolver helpers
      tryResolveSwapParameters
    , tryResolveRateParameters

      -- * Intent assembly
    , buildSwapIntent
    ) where

import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except
    ( runExceptT
    , throwE
    )
import Control.Tracer (Tracer, traceWith)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T

import Ouroboros.Network.Magic (NetworkMagic (..))

import Amaru.Treasury.Backend (Backend)
import Amaru.Treasury.Cli.Common
    ( GlobalOpts (..)
    , resolveNetworkName
    )
import Amaru.Treasury.Cli.SwapCommon
    ( providerToResolverEnv
    , traceEnv
    , traceRegistryView
    , traceResolverEnv
    )
import Amaru.Treasury.Cli.SwapWizard
    ( ChunkSpec (..)
    , WizardOpts (..)
    , WizardOrder (..)
    , WizardRate (..)
    , WizardRateParameters (..)
    , WizardSwapParameters (..)
    , rateToFraction
    , swapQuoteRequestChunk
    , usdmToLovelace
    , validateWizardInputControl
    )
import Amaru.Treasury.IntentJSON
    ( SAction (..)
    , SomeTreasuryIntent (..)
    , SwapInputs (..)
    , tiPayload
    , tiValidityUpperBoundSlot
    )
import Amaru.Treasury.Registry.Verify (verifyRegistry)
import Amaru.Treasury.Tx.SwapQuote qualified as SQ
import Amaru.Treasury.Tx.SwapWizard
    ( AllAdaPlan (..)
    , RationaleAnswers (..)
    , ResolverAllAdaInput (..)
    , ResolverError (..)
    , ResolverInput (..)
    , SwapWizardQ (..)
    , WizardError
    , registryViewFromVerified
    , renderWalletShortfall
    , renderWalletShortfallWithExcludes
    , resolveWizardEnvAllAdaIC
    , resolveWizardEnvIC
    , wizardToTreasuryIntent
    )
import Amaru.Treasury.Tx.SwapWizard.Trace
    ( WizardEvent (..)
    )
import Amaru.Treasury.Wizard.Failure
    ( FieldId (..)
    , WizardFailure (..)
    )
import Amaru.Treasury.Wizard.InputControl
    ( renderInputControlError
    )

-- ---------------------------------------------------------------------------
-- Pure-Either resolver helpers

{- | Pure variant of
'Amaru.Treasury.Cli.SwapWizard.resolveWizardSwapParameters'.
Returns 'Left' with a single-line stderr-shaped diagnostic
on the only failure path (operator-override
'SQ.deriveSwapParameters' refused).
-}
tryResolveSwapParameters
    :: Double
    -> ChunkSpec
    -> WizardRate
    -> Either Text WizardSwapParameters
tryResolveSwapParameters usdm chunkSpec = \case
    WizardMinRate minRate ->
        let amountLov = usdmToLovelace usdm minRate
            chunkSize = case chunkSpec of
                SplitCount n -> amountLov `div` toInteger n
                ChunkUsdm x -> usdmToLovelace x minRate
            (rateNum, rateDen) = rateToFraction minRate
        in  Right
                WizardSwapParameters
                    { wspAmountLovelace = amountLov
                    , wspChunkSizeLovelace = chunkSize
                    , wspRateNumerator = rateNum
                    , wspRateDenominator = rateDen
                    }
    WizardOverrideRate adaUsdm slippage ->
        let observation =
                SQ.QuoteObservation
                    { SQ.qoPair = SQ.AdaUsdm
                    , SQ.qoQuote = toRational adaUsdm
                    , SQ.qoProvenance = SQ.OperatorOverride
                    }
        in  case SQ.deriveSwapParameters
                observation
                slippage
                SQ.SwapQuoteRequest
                    { SQ.sqrRequestedUsdm = toRational usdm
                    , SQ.sqrChunk = swapQuoteRequestChunk chunkSpec
                    } of
                Right derived ->
                    Right
                        WizardSwapParameters
                            { wspAmountLovelace = SQ.dspAmountLovelace derived
                            , wspChunkSizeLovelace = SQ.dspChunkSizeLovelace derived
                            , wspRateNumerator = SQ.dspRateNumerator derived
                            , wspRateDenominator = SQ.dspRateDenominator derived
                            }
                Left err ->
                    Left
                        ( "derive swap parameters: "
                            <> T.pack (show err)
                        )

{- | Pure variant of
'Amaru.Treasury.Cli.SwapWizard.resolveWizardRateParameters'.
Returns 'Left' on the only failure path (operator-override
'SQ.deriveSwapParameters' refused).
-}
tryResolveRateParameters
    :: WizardRate
    -> Either Text WizardRateParameters
tryResolveRateParameters = \case
    WizardMinRate minRate ->
        let (rateNum, rateDen) = rateToFraction minRate
        in  Right
                WizardRateParameters
                    { wrpRateNumerator = rateNum
                    , wrpRateDenominator = rateDen
                    }
    WizardOverrideRate adaUsdm slippage ->
        let observation =
                SQ.QuoteObservation
                    { SQ.qoPair = SQ.AdaUsdm
                    , SQ.qoQuote = toRational adaUsdm
                    , SQ.qoProvenance = SQ.OperatorOverride
                    }
        in  case SQ.deriveSwapParameters
                observation
                slippage
                SQ.SwapQuoteRequest
                    { SQ.sqrRequestedUsdm = 1
                    , SQ.sqrChunk = SQ.SplitInto 1
                    } of
                Right derived ->
                    Right
                        WizardRateParameters
                            { wrpRateNumerator = SQ.dspRateNumerator derived
                            , wrpRateDenominator = SQ.dspRateDenominator derived
                            }
                Left err ->
                    Left
                        ( "derive swap rate: "
                            <> T.pack (show err)
                        )

-- ---------------------------------------------------------------------------
-- Intent assembly

{- | Pure-ish entry point for the swap-wizard intent
construction (no process exits).

The body mirrors the IO sequence of
'Amaru.Treasury.Cli.SwapWizard.runWizard' from the moment
the backend is open onward: validate input controls,
resolve the network, verify the registry, resolve the
exclusion/forced env, translate to the typed intent, and
return.  Every former @abortTr@ site is now a 'throwE' of a
typed 'WizardFailure' constructor.

The caller owns the 'Backend' lifetime — for the CLI, this
is the 'withLocalNodeBackend' bracket inside the wrapper;
for an HTTP server, this is a per-process backend handle
opened at server boot and reused across requests.

This function is independent of the CLI 'runWizard'; the
two coexist on the branch until Phase 4 of #259 rewires
the CLI to delegate here.
-}
buildSwapIntent
    :: GlobalOpts
    -> WizardOpts
    -> Backend
    -> Tracer IO WizardEvent
    -> IO (Either WizardFailure SomeTreasuryIntent)
buildSwapIntent g opts@WizardOpts{..} backend tr = runExceptT $ do
    -- 1. Input-control validation (operator-supplied
    --    @--exclude-utxo@ / @--extra-tx-in@ sets).
    case validateWizardInputControl opts of
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
    liftIO (traceWith tr (WeNetwork networkName (fromIntegral magic)))
    liftIO (traceWith tr (WeMetadata wOptsMetadataPath))

    -- 3. Registry verification + projection.
    verified <-
        liftIO
            ( verifyRegistry
                backend
                wOptsMetadataPath
                (Set.singleton wOptsScope)
            )
    rv <- case verified of
        Left e ->
            throwE
                ( ResolveRegistryVerify
                    ("verify: " <> T.pack (show e))
                )
        Right registry ->
            case registryViewFromVerified wOptsScope registry of
                Left e ->
                    throwE
                        ( ResolveRegistryVerify
                            ("project: " <> T.pack (show e))
                        )
                Right view -> pure view

    liftIO (traceRegistryView tr wOptsScope rv)
    let renv = traceResolverEnv tr (providerToResolverEnv backend)

    -- 4. Env + parameters via order dispatch.
    (env, params) <- case wOptsOrder of
        FixedUsdm usdm chunkSpec -> do
            params <-
                case tryResolveSwapParameters usdm chunkSpec wOptsRate of
                    Left e -> throwE (ResolveSwapParameters e)
                    Right v -> pure v
            let ri =
                    ResolverInput
                        { riNetwork = networkName
                        , riWalletAddrBech32 = wOptsWalletAddr
                        , riScope = wOptsScope
                        , riAmountLovelace = wspAmountLovelace params
                        , riChunkSizeLovelace =
                            wspChunkSizeLovelace params
                        , riRegistry = rv
                        , riValidityHours = wOptsValidityHours
                        }
            er <-
                liftIO
                    ( resolveWizardEnvIC
                        renv
                        wOptsExcludeSet
                        wOptsForcedSet
                        ri
                    )
            env <- case er of
                Left
                    (ResolverWalletShortfall avail required) ->
                        throwE
                            ( ResolveResolver
                                ( renderWalletShortfall
                                    ri
                                    avail
                                    required
                                )
                            )
                Left
                    ( ResolverWalletShortfallWithExcludes
                            avail
                            required
                            refs
                        ) ->
                        throwE
                            ( ResolveResolver
                                ( renderWalletShortfallWithExcludes
                                    ( renderWalletShortfall
                                        ri
                                        avail
                                        required
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
            pure (env, params)
        AllAda split -> do
            rateParams <-
                case tryResolveRateParameters wOptsRate of
                    Left e -> throwE (ResolveSwapParameters e)
                    Right v -> pure v
            let rai =
                    ResolverAllAdaInput
                        { raiNetwork = networkName
                        , raiWalletAddrBech32 = wOptsWalletAddr
                        , raiScope = wOptsScope
                        , raiSplit = split
                        , raiRateNumerator =
                            wrpRateNumerator rateParams
                        , raiRateDenominator =
                            wrpRateDenominator rateParams
                        , raiRegistry = rv
                        , raiValidityHours = wOptsValidityHours
                        }
            er <-
                liftIO
                    ( resolveWizardEnvAllAdaIC
                        renv
                        wOptsExcludeSet
                        wOptsForcedSet
                        rai
                    )
            (env, plan) <- case er of
                Left
                    ( ResolverWalletShortfallWithExcludes
                            avail
                            required
                            refs
                        ) ->
                        throwE
                            ( ResolveResolver
                                ( renderWalletShortfallWithExcludes
                                    ( "wallet shortfall available="
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
                Right (e, plan', _outcome) -> pure (e, plan')
            pure
                ( env
                , WizardSwapParameters
                    { wspAmountLovelace = aapAmountLovelace plan
                    , wspChunkSizeLovelace =
                        aapChunkSizeLovelace plan
                    , wspRateNumerator = aapRateNumerator plan
                    , wspRateDenominator = aapRateDenominator plan
                    }
                )

    liftIO (traceEnv tr env)

    -- 5. Translate operator answers into the typed intent.
    let answers =
            SwapWizardQ
                { wqScope = wOptsScope
                , wqAmountLovelace = wspAmountLovelace params
                , wqChunkSizeLovelace =
                    wspChunkSizeLovelace params
                , wqRateNumerator = wspRateNumerator params
                , wqRateDenominator = wspRateDenominator params
                , wqValidityHours = wOptsValidityHours
                , wqRationale =
                    RationaleAnswers
                        { raDescription = wOptsDescription
                        , raJustification = wOptsJustification
                        , raDestinationLabel =
                            wOptsDestinationLabel
                        , raEvent = wOptsEvent
                        , raLabel = wOptsLabel
                        }
                , wqExtraSigners = wOptsSigners
                }
    intent <-
        case wizardToTreasuryIntent env answers of
            Left we ->
                throwE
                    ( InternalTranslate
                        ( "translate: "
                            <> T.pack (show (we :: WizardError))
                        )
                    )
            Right i -> pure i

    -- 6. Trailing trace events (CLI byte-identity).
    let p = tiPayload intent
        total = swiAmountLovelace p
        cs = swiChunkSizeLovelace p
        full = total `div` cs
        rem' = total `mod` cs
    liftIO
        ( traceWith tr $
            WeUpperBoundResolved
                (tiValidityUpperBoundSlot intent)
        )
    liftIO
        ( traceWith tr $
            WeChunksComputed total cs (fromInteger full) rem'
        )
    liftIO (traceWith tr (WeIntentReady wOptsOut))

    pure (SomeTreasuryIntent SSwap intent)
