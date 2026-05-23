{- |
Module      : Amaru.Treasury.Wizard.Event
Description : Stable import path for typed wizard tracer
              events (#259).
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Re-exports the existing 'WizardEvent' typed event sum and
its renderer/adapter from
'Amaru.Treasury.Tx.SwapWizard.Trace', so callers under the
'Amaru.Treasury.Wizard.*' tree (the refactored 'buildSwap*'
entry points and their consumers) have one stable import
path symmetric with 'Amaru.Treasury.Wizard.Failure'.

== BuildEvent

Intentionally not introduced here.  The existing
@tx-build@ pipeline ('Amaru.Treasury.Build.Swap') is
already 'ExceptT'-based and emits no tracer events; a
'BuildEvent' sum will be added in Phase 3 of #259 when
'buildSwapTx' lands and the per-step events it actually
emits are known.  Adding an uninhabited placeholder type
now would be busywork without a consumer.
-}
module Amaru.Treasury.Wizard.Event
    ( WizardEvent (..)
    , renderEvent
    , eventTracer
    ) where

import Amaru.Treasury.Tx.SwapWizard.Trace
    ( WizardEvent (..)
    , eventTracer
    , renderEvent
    )
