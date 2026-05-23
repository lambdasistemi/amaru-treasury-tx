{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

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

Phase 3 of #259 lands in incremental commits:

  * /this commit/ — pure-Either helpers
    'tryResolveSwapParameters' and 'tryResolveRateParameters'
    that the existing 'Amaru.Treasury.Cli.SwapWizard' CLI
    helpers delegate to (preserving CLI byte-identity).
  * /next/ — 'buildSwapIntent' itself, consuming the pure
    helpers and the rest of the IO sequence currently inside
    'Amaru.Treasury.Cli.SwapWizard.runWizard'.
  * /next/ — 'buildSwapTx' adapting
    'Amaru.Treasury.Build.Swap.runSwap'.
-}
module Amaru.Treasury.Wizard.Swap
    ( -- * Pure-Either resolver helpers (Phase 3 commit 1)
      tryResolveSwapParameters
    , tryResolveRateParameters

      -- * Intent assembly (Phase 3 — body lands incrementally)
    , buildSwapIntent
    ) where

import Control.Tracer (Tracer)
import Data.Text (Text)
import Data.Text qualified as T

import Amaru.Treasury.Backend (Backend)
import Amaru.Treasury.Cli.Common (GlobalOpts)
import Amaru.Treasury.Cli.SwapWizard
    ( ChunkSpec (..)
    , WizardOpts
    , WizardRate (..)
    , WizardRateParameters (..)
    , WizardSwapParameters (..)
    , rateToFraction
    , swapQuoteRequestChunk
    , usdmToLovelace
    )
import Amaru.Treasury.IntentJSON (SomeTreasuryIntent)
import Amaru.Treasury.Tx.SwapQuote qualified as SQ
import Amaru.Treasury.Tx.SwapWizard.Trace (WizardEvent)
import Amaru.Treasury.Wizard.Failure (WizardFailure (..))

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

{- | Pure-ish entry point for the swap-wizard intent
construction (no process exits).  Returns the typed intent
the existing 'Amaru.Treasury.Cli.SwapWizard.runWizard' would
have serialised to @intent.json@, or a typed
'WizardFailure' the caller can render or convert to an HTTP
response.

== Implementation status

This commit establishes the signature.  The 240-line IO
body currently lives inside
'Amaru.Treasury.Cli.SwapWizard.runWizard'; subsequent
commits in #259 Phase 3 port one section at a time
(validation, network/registry resolve, env resolve,
translate, encode), each replacing one or more @abortTr@
sites with a typed 'WizardFailure' constructor.  The CLI
'runWizard' stays intact until Phase 4 rewires it through
this function; bisect-safety is preserved at every commit.

The stub return shape lets dependent code compile against
the final contract today.
-}
buildSwapIntent
    :: GlobalOpts
    -> WizardOpts
    -> Backend
    -> Tracer IO WizardEvent
    -> IO (Either WizardFailure SomeTreasuryIntent)
buildSwapIntent _g _opts _backend _tr =
    pure
        ( Left
            ( InternalEncodeError
                "buildSwapIntent: implementation pending; \
                \see specs/259-swap-wizard-pure/tasks.md Phase 3"
            )
        )
