{- |
Module      : Amaru.Treasury.Wizard.Event
Description : Stable import path for typed wizard + build
              tracer events (#259 / #269).
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Two typed event sums tell a tracer consumer (operator's
stderr, an HTTP log, a UI step indicator) exactly which
phase of the swap pipeline is in flight.  Both are
informational only — control flow never branches on
tracer presence; running with 'nullTracer' must produce
the same result as a recording tracer.

  * 'WizardEvent' — intent-construction phase
    ('buildSwapIntent').  Re-exported from the existing
    'Amaru.Treasury.Tx.SwapWizard.Trace' under this
    stable import path symmetric with
    'Amaru.Treasury.Wizard.Failure'.

  * 'BuildEvent' — tx-build phase ('buildSwapTx').
    Re-exported from the existing
    'Amaru.Treasury.Build.Trace' which already carries
    the full per-step taxonomy used by the @tx-build@
    CLI subcommand.  Adding a parallel sum-type here
    would have forced consumers to convert; the
    re-export keeps one canonical surface.
-}
module Amaru.Treasury.Wizard.Event
    ( -- * Intent-construction events
      WizardEvent (..)
    , renderEvent
    , eventTracer

      -- * Tx-build events (#269)
    , BuildEvent (..)
    , renderBuildEvent
    , buildEventTracer
    ) where

import Amaru.Treasury.Build.Trace
    ( BuildEvent (..)
    , buildEventTracer
    , renderBuildEvent
    )
import Amaru.Treasury.Tx.SwapWizard.Trace
    ( WizardEvent (..)
    , eventTracer
    , renderEvent
    )
