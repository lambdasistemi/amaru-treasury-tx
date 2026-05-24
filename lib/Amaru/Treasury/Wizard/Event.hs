{- |
Module      : Amaru.Treasury.Wizard.Event
Description : Stable import path for typed wizard + build
              tracer events (#259 / #269 / #277).
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Three typed event sums tell a tracer consumer (operator's
stderr, an HTTP log, a UI step indicator) exactly which
phase of a wizard pipeline is in flight.  All three are
informational only — control flow never branches on
tracer presence; running with 'nullTracer' must produce
the same result as a recording tracer.

  * 'WizardEvent' — swap intent-construction phase
    ('buildSwapIntent').  Re-exported from the existing
    'Amaru.Treasury.Tx.SwapWizard.Trace' under this
    stable import path symmetric with
    'Amaru.Treasury.Wizard.Failure'.

  * 'BuildEvent' — tx-build phase ('buildSwapTx' /
    'buildDisburseTx').  Re-exported from the existing
    'Amaru.Treasury.Build.Trace' which already carries
    the full per-step taxonomy used by the @tx-build@
    CLI subcommand.  Adding a parallel sum-type here
    would have forced consumers to convert; the
    re-export keeps one canonical surface.

  * 'DisburseWizardEvent' — disburse intent-construction
    phase ('buildDisburseIntent').  Re-exported from the
    existing 'Amaru.Treasury.Tx.DisburseWizard.Trace'
    symmetric with 'WizardEvent' (#277).

  * 'ReorganizeWizardEvent' — reorganize intent-construction
    phase ('buildReorganizeIntent').  Re-exported from
    'Amaru.Treasury.Tx.ReorganizeWizard.Trace' symmetric
    with the swap- and disburse-side events (#280).
-}
module Amaru.Treasury.Wizard.Event
    ( -- * Swap intent-construction events
      WizardEvent (..)
    , renderEvent
    , eventTracer

      -- * Tx-build events (#269)
    , BuildEvent (..)
    , renderBuildEvent
    , buildEventTracer

      -- * Disburse intent-construction events (#277)
    , DisburseWizardEvent (..)
    , renderDisburseWizardEvent
    , renderDisburseWizardEventWithPrefix
    , disburseWizardEventTracer
    , disburseEventTracerWithPrefix

      -- * Reorganize intent-construction events (#280)
    , ReorganizeWizardEvent (..)
    , renderReorganizeWizardEvent
    , reorganizeWizardEventTracer
    ) where

import Amaru.Treasury.Build.Trace
    ( BuildEvent (..)
    , buildEventTracer
    , renderBuildEvent
    )
import Amaru.Treasury.Tx.DisburseWizard.Trace
    ( DisburseWizardEvent (..)
    , disburseEventTracerWithPrefix
    , disburseWizardEventTracer
    , renderDisburseWizardEvent
    , renderDisburseWizardEventWithPrefix
    )
import Amaru.Treasury.Tx.ReorganizeWizard.Trace
    ( ReorganizeWizardEvent (..)
    , renderReorganizeWizardEvent
    , reorganizeWizardEventTracer
    )
import Amaru.Treasury.Tx.SwapWizard.Trace
    ( WizardEvent (..)
    , eventTracer
    , renderEvent
    )
