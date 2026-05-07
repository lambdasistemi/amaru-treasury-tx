{- |
Module      : Amaru.Treasury.ChainContext
Description : Frozen-or-live ledger context for tx building
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Everything 'Cardano.Node.Client.TxBuild.build' needs from
"reality":

* the protocol parameters at a moment in time,
* the resolved input + reference UTxOs at that moment,
* a script evaluator that can run Plutus redeemers
  against a draft tx.

In production this comes from a live cardano-node via
'Amaru.Treasury.Backend.N2C'. For offline regression
tests, the same fields can be filled in from a frozen
fixture so the build is deterministic across chain
drift, fork transitions, or even when the original
inputs have been spent.

The two constructors below are the only blessed ways to
build a 'ChainContext':

* 'liveContext' — query a 'Provider' for everything
  needed by a known set of 'TxIn's.
* 'frozenContext' — pre-supply pparams, UTxOs, and a
  pure evaluator (typically returning ExUnits captured
  during a previous live run).

Consumers ('Amaru.Treasury.TreasuryBuild.runSwap')
take a 'ChainContext' and don't care which constructor
made it.
-}
module Amaru.Treasury.ChainContext
    ( -- * Type
      ChainContext (..)

      -- * Constructors
    , liveContext
    , frozenContext
    ) where

import Control.Exception (throwIO)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set

import Cardano.Ledger.Api.Tx.Out (TxOut)
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (PParams)
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Node.Client.Ledger (ConwayTx)
import Cardano.Node.Client.Provider
    ( EvaluateTxResult
    , Provider (..)
    )

{- | The chain-side inputs to a tx build, frozen as
plain data. Either the rows are filled in by querying a
live node ('liveContext'), or they're loaded from a
fixture ('frozenContext').

The build pipeline never reaches past these fields, so a
'ChainContext' is the *full* surface of "reality" that a
deterministic tx build depends on — pin one and the
build becomes reproducible regardless of chain state.
-}
data ChainContext = ChainContext
    { ccPParams :: !(PParams ConwayEra)
    -- ^ Protocol parameters at the snapshot point.
    , ccUtxos :: !(Map TxIn (TxOut ConwayEra))
    -- ^ Resolved spend + reference UTxOs. The map
    --     must contain every 'TxIn' the build refers
    --     to (wallet, treasury, scopes, permissions,
    --     treasury-deployed, registry); missing
    --     entries surface as a build-time error.
    , ccEvaluateTx :: !(ConwayTx -> IO (EvaluateTxResult ConwayEra))
    -- ^ Script evaluator. Live mode delegates to the
    --     node's @EvaluateTx@; frozen mode looks up
    --     pre-recorded 'ExUnits' keyed by redeemer
    --     purpose.
    }

{- | Capture a 'ChainContext' from a live 'Provider' for a known set of
'TxIn's. Fails fast if any input is missing (spent or never existed).
-}
liveContext
    :: Provider IO
    -> Set TxIn
    -> IO ChainContext
liveContext prov needed = do
    pp <- queryProtocolParams prov
    utxos <- queryUTxOByTxIn prov needed
    let missing =
            Set.difference needed (Map.keysSet utxos)
    if not (Set.null missing)
        then
            throwIO . userError $
                "liveContext: missing UTxOs: "
                    <> show (Set.toList missing)
        else
            pure
                ChainContext
                    { ccPParams = pp
                    , ccUtxos = utxos
                    , ccEvaluateTx = evaluateTx prov
                    }

{- | Build a 'ChainContext' from frozen fixtures.

The evaluator is supplied by the caller: typically a
@const (pure recordedResults)@ that returns the
'ExUnits' / failure map captured during an earlier live
run, so 'build' can patch the redeemers and balance
without touching the network.
-}
frozenContext
    :: PParams ConwayEra
    -> Map TxIn (TxOut ConwayEra)
    -> (ConwayTx -> IO (EvaluateTxResult ConwayEra))
    -> ChainContext
frozenContext pp utxos eval =
    ChainContext
        { ccPParams = pp
        , ccUtxos = utxos
        , ccEvaluateTx = eval
        }
