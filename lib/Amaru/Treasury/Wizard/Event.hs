{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

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

  * 'BuildEvent' — tx-build phase ('buildSwapTx').  Mirrors
    the per-step structure that #269 introduces.  Six
    constructors, one per discrete pipeline step.
-}
module Amaru.Treasury.Wizard.Event
    ( -- * Intent-construction events (re-exported)
      WizardEvent (..)
    , renderEvent
    , eventTracer

      -- * Tx-build events (#269)
    , BuildEvent (..)
    , renderBuildEvent
    ) where

import Data.Text (Text)
import Data.Text qualified as T

import Amaru.Treasury.Tx.SwapWizard.Trace
    ( WizardEvent (..)
    , eventTracer
    , renderEvent
    )

{- | Per-step event emitted along the tx-build pipeline
('Amaru.Treasury.Wizard.Swap.buildSwapTx').

One constructor per discrete step in the order they
fire on the happy path.  A consumer that streams them
to stderr / a UI sees the full life-cycle of one swap
tx-build call.
-}
data BuildEvent
    = -- | About to query the backend for protocol parameters.
      BeResolvingPParams
    | -- | About to scan the wallet's UTxO set for fuel + collateral.
      BeSelectingWalletInputs !Text
      -- ^ wallet bech32 address
    | -- | About to construct the sundae order datum.
      BeBuildingSundaeOrder !Text
      -- ^ direction: @\"ADA->USDM\"@ or @\"USDM->ADA\"@
    | -- | About to call the ledger's balancing routine.
      BeBalancingTx !Int !Int
      -- ^ input count, output count
    | -- | About to encode the balanced body to CBOR.
      BeSerialisingTx
    | -- | About to assemble the 'Report' value and finalise.
      BeWritingReport !Text
      -- ^ txid hex
    deriving (Eq, Show)

{- | Single-line human-readable render used for stderr
output by the @tx-build@ CLI wrapper and the api's
stderr 'Tracer'.
-}
renderBuildEvent :: BuildEvent -> Text
renderBuildEvent = \case
    BeResolvingPParams ->
        "resolving protocol parameters"
    BeSelectingWalletInputs addr ->
        "selecting wallet inputs at " <> addr
    BeBuildingSundaeOrder direction ->
        "building sundae order (" <> direction <> ")"
    BeBalancingTx ins outs ->
        "balancing tx ("
            <> T.pack (show ins)
            <> " in, "
            <> T.pack (show outs)
            <> " out)"
    BeSerialisingTx ->
        "serialising tx body"
    BeWritingReport txid ->
        "writing report for tx " <> txid
