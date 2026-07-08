{- |
Module      : Amaru.Treasury.ChainContext
Description : Frozen-or-live ledger context for tx building
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Everything 'Cardano.Tx.Build.build' needs from
"reality":

* the protocol parameters at a moment in time,
* the resolved input + reference UTxOs at that moment,
* the ledger network and slot sampled at that moment,
* a script evaluator that can run Plutus redeemers
  against a draft tx from the same sampled snapshot.

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
* 'withLiveContext' — like 'liveContext', but keeps the
  provider's acquired snapshot open while the caller builds.
* 'frozenContext' — pre-supply pparams, UTxOs, and a
  pure evaluator (typically returning ExUnits captured
  during a previous live run).

Consumers ('Amaru.Treasury.Build.runSwap')
take a 'ChainContext' and don't care which constructor
made it.
-}
module Amaru.Treasury.ChainContext
    ( -- * Type
      ChainContext (..)

      -- * Constructors
    , withLiveContext
    , liveContext
    , frozenContext
    , frozenContextAt
    , networkFromMagic
    ) where

import Control.Exception (throwIO)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Ouroboros.Network.Magic (NetworkMagic (..))

import Cardano.Ledger.Api.Tx.Out (TxOut)
import Cardano.Ledger.BaseTypes (Network (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (PParams)
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Node.Client.Provider
    ( EvaluateTxResult
    , LedgerSnapshot (..)
    , Provider (..)
    , QueryHandle
    , evaluateTxH
    , queryLedgerSnapshotH
    , queryProtocolParamsH
    , queryUTxOByTxInH
    )
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Tx.Ledger (ConwayTx)

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
    { ccNetwork :: !Network
    -- ^ Ledger network family sampled from the CLI/N2C magic.
    , ccTipSlot :: !SlotNo
    -- ^ Tip slot from the same ledger snapshot used for pparams,
    --     UTxOs, and evaluation.
    , ccPParams :: !(PParams ConwayEra)
    -- ^ Protocol parameters at the snapshot point.
    , ccUtxos :: !(Map TxIn (TxOut ConwayEra))
    -- ^ Resolved spend + reference UTxOs. The map
    --     must contain every 'TxIn' the build refers
    --     to (wallet, treasury, scopes, permissions,
    --     treasury-deployed, registry); missing
    --     entries surface as a build-time error.
    , ccEvaluateTx :: !(ConwayTx -> IO (EvaluateTxResult ConwayEra))
    -- ^ Script evaluator. 'withLiveContext' delegates to the
    --     acquired N2C handle; frozen mode looks up
    --     pre-recorded 'ExUnits' keyed by redeemer
    --     purpose.
    }

{- | Run an action with a live 'ChainContext' sampled from one acquired
provider snapshot.

The callback shape is intentional: an acquired N2C query handle is only
valid inside the provider's acquired callback, and the build loop calls
the evaluator multiple times. Keeping the build inside this callback
means protocol parameters, UTxOs, tip slot, and script evaluation all
come from one sampled ledger view.
-}
withLiveContext
    :: Network
    -> Provider IO
    -> Set TxIn
    -> (ChainContext -> IO a)
    -> IO a
withLiveContext network prov needed action =
    withAcquired prov $ \handle -> do
        ctx <- liveContextFromHandle network needed handle
        action ctx

{- | Capture a 'ChainContext' from a live 'Provider' for a known set of
'TxIn's. Prefer 'withLiveContext' for production builds so the acquired
N2C handle remains open while 'ccEvaluateTx' is used.
-}
liveContext
    :: Network
    -> Provider IO
    -> Set TxIn
    -> IO ChainContext
liveContext network prov needed = do
    pp <- queryProtocolParams prov
    utxos <- queryUTxOByTxIn prov needed
    snapshot <- queryLedgerSnapshot prov
    mkContext
        network
        (ledgerTipSlot snapshot)
        needed
        pp
        utxos
        (evaluateTx prov)

liveContextFromHandle
    :: Network
    -> Set TxIn
    -> QueryHandle IO
    -> IO ChainContext
liveContextFromHandle network needed handle = do
    pp <- queryProtocolParamsH handle
    utxos <- queryUTxOByTxInH handle needed
    snapshot <- queryLedgerSnapshotH handle
    mkContext
        network
        (ledgerTipSlot snapshot)
        needed
        pp
        utxos
        (evaluateTxH handle)

mkContext
    :: Network
    -> SlotNo
    -> Set TxIn
    -> PParams ConwayEra
    -> Map TxIn (TxOut ConwayEra)
    -> (ConwayTx -> IO (EvaluateTxResult ConwayEra))
    -> IO ChainContext
mkContext network slot needed pp utxos eval = do
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
                    { ccNetwork = network
                    , ccTipSlot = slot
                    , ccPParams = pp
                    , ccUtxos = utxos
                    , ccEvaluateTx = eval
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
frozenContext =
    frozenContextAt Mainnet (SlotNo 0)

frozenContextAt
    :: Network
    -> SlotNo
    -> PParams ConwayEra
    -> Map TxIn (TxOut ConwayEra)
    -> (ConwayTx -> IO (EvaluateTxResult ConwayEra))
    -> ChainContext
frozenContextAt network slot pp utxos eval =
    ChainContext
        { ccNetwork = network
        , ccTipSlot = slot
        , ccPParams = pp
        , ccUtxos = utxos
        , ccEvaluateTx = eval
        }

-- | Map a Cardano network magic to the ledger's network family.
networkFromMagic :: NetworkMagic -> Network
networkFromMagic (NetworkMagic 764_824_073) = Mainnet
networkFromMagic _ = Testnet
