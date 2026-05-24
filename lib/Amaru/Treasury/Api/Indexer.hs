{- |
Module      : Amaru.Treasury.Api.Indexer
Description : Runner + readiness gate for the API indexer
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

The @amaru-treasury-tx-api@ container embeds the
'Cardano.Node.Client.UTxOIndexer.Indexer' module from
@cardano-node-clients:utxo-indexer-lib@ in the same OS
process as the warp HTTP server, so the
@GET \/v1\/treasury-inspect@ hot path resolves UTxOs from
a local RocksDB store rather than from
@GetUTxOByAddress@ on the production node. This module is
the bring-up shim that wraps the upstream
'Indexer.IndexerHandle' with an in-process 'Readiness'
'TVar' the handler layer consults to decide between 200
and HTTP 503.

= Slice 1 limitation

The chain-sync follower wiring is deferred to Slice 3
(downstream of the paired upstream PR for
@withChainSyncFollower@ in @cardano-node-clients@).
'withApiIndexer' brings the indexer up with a
short-lived placeholder 'Async' in 'aiFollower' and
never writes to 'aiReadiness'; the readiness 'TVar'
starts at @rUpstreamUp = False@ so 'checkReady'
correctly reports 'Pending' until a test (or Slice 3's
follower) updates it via
"Amaru.Treasury.Api.Indexer.Internal".
-}
module Amaru.Treasury.Api.Indexer
    ( -- * Configuration and state
      IndexerConfig (..)
    , Readiness (..)
    , ReadyState (..)
    , ApiIndexer (..)

      -- * Bring-up
    , withApiIndexer

      -- * Readiness
    , waitReady
    , checkReady

      -- * Read operations
    , snapshotAt
    ) where

import Cardano.Node.Client.N2C.Trace (N2CEvent)
import Cardano.Node.Client.UTxOIndexer.Indexer
    ( IndexerHandle
    )
import Cardano.Node.Client.UTxOIndexer.Indexer qualified as Indexer
import Cardano.Node.Client.UTxOIndexer.Types
    ( Address
    , SlotNo (..)
    , TxIn
    , TxOut
    )
import Control.Concurrent.Async (Async, withAsync)
import Control.Concurrent.STM
    ( TVar
    , atomically
    , check
    , newTVarIO
    , readTVar
    , readTVarIO
    )
import Control.Tracer (Tracer)
import Data.Time.Clock (UTCTime, getCurrentTime)
import Data.Word (Word64)
import Ouroboros.Network.Magic (NetworkMagic)

-- ---------------------------------------------------------------------------
-- Types

{- | Static configuration captured from CLI flags and
environment. Built once at boot by
@app\/amaru-treasury-tx-api\/Main.hs@ (Slice 3) and
threaded into 'withApiIndexer'.
-}
data IndexerConfig = IndexerConfig
    { icDbPath :: !FilePath
    -- ^ RocksDB directory. Created if missing.
    , icSocketPath :: !FilePath
    -- ^ Node N2C socket the chain-sync follower will
    -- connect to (Slice 3). Stored but not yet consumed.
    , icNetworkMagic :: !NetworkMagic
    -- ^ Network magic for the chain-sync follower
    -- (Slice 3). Stored but not yet consumed.
    , icStartSlot :: !SlotNo
    -- ^ Cold-boot starting slot (Slice 3). Ignored when
    -- the on-disk store has a prior cursor, in which
    -- case @getResumePoints@ wins.
    , icLagThresholdSlots :: !Word64
    -- ^ Drift threshold. When
    -- @tip_slot - processed_slot > this value@,
    -- 'checkReady' returns 'Lagging' and the handler
    -- layer answers HTTP 503.
    }
    deriving stock (Eq, Show)

{- | Live readiness snapshot. The follower (Slice 3) will
update this 'TVar' after every batch apply. Until then
the initial value has @rUpstreamUp = False@, which
'classifyReadiness' translates to 'Pending'.
-}
data Readiness = Readiness
    { rProcessedSlot :: !SlotNo
    -- ^ Highest slot the follower has applied.
    , rTipSlot :: !SlotNo
    -- ^ Latest tip slot observed from the upstream node.
    , rLagSlots :: !Word64
    -- ^ @rTipSlot - rProcessedSlot@, kept alongside the
    -- raw slots so the handler layer can echo it in the
    -- HTTP 503 body without re-deriving.
    , rUpstreamUp :: !Bool
    -- ^ False until the follower has both connected to
    -- the node and observed at least one tip. Sentinel
    -- for the pre-readiness 'Pending' state.
    , rUpdatedAt :: !UTCTime
    -- ^ Wall-clock time of the last 'TVar' write.
    }
    deriving stock (Eq, Show)

{- | Three-state verdict the handler layer consumes per
request. Derived from 'Readiness' by 'checkReady'
against 'icLagThresholdSlots'.
-}
data ReadyState
    = -- | Cold boot — the follower has not yet observed
      -- the upstream tip. Handlers should treat this as
      -- "not yet listening" (warp does not bind in
      -- Slice 3).
      Pending
    | -- | Within the lag threshold of tip. Handlers
      -- serve normally.
      Ready
    | -- | Beyond the lag threshold. The first 'Word64'
      -- is the observed @lag_slots@; the second is the
      -- configured threshold. Handlers should answer
      -- HTTP 503 with both numbers in the body.
      Lagging !Word64 !Word64
    deriving stock (Eq, Show)

{- | Opaque handle the API container threads through its
'Handlers' record. The fields are exposed so 'snapshotAt'
can pass through to 'aiHandle' and Slice 3's follower
can write to 'aiReadiness'.
-}
data ApiIndexer = ApiIndexer
    { aiHandle :: !IndexerHandle
    -- ^ Underlying @utxo-indexer-lib@ handle. Shared
    -- between the (future) follower writer and the
    -- handler readers; the upstream library guarantees
    -- thread-safety on reads.
    , aiReadiness :: !(TVar Readiness)
    -- ^ Updated by the follower thread after each batch
    -- apply (Slice 3); read by 'checkReady' and
    -- 'waitReady'.
    , aiFollower :: !(Async ())
    -- ^ Slice 1: a short-lived placeholder 'Async' that
    -- returns immediately. Slice 3 will replace this
    -- with the real chain-sync follower thread the
    -- caller is expected to 'link' so follower
    -- exceptions propagate.
    , aiConfig :: !IndexerConfig
    -- ^ The configuration this indexer was opened with.
    }

-- ---------------------------------------------------------------------------
-- Bring-up

{- | Bring up the indexer: open the RocksDB store,
allocate the readiness 'TVar', and run the action with
a fully wired 'ApiIndexer'. Resource-bracketed: on exit
the placeholder follower is torn down and the RocksDB
handle is closed.

Slice 1 limitation: no real chain-sync follower thread
is spawned. The readiness 'TVar' starts at
@rUpstreamUp = False@ (so 'checkReady' returns
'Pending') and is not updated until a test (or Slice 3's
follower) writes to it.
-}
withApiIndexer
    :: Tracer IO N2CEvent
    -- ^ Tracer for indexer lifecycle events. Stored
    -- for Slice 3 wiring; not yet consumed.
    -> IndexerConfig
    -> (ApiIndexer -> IO a)
    -> IO a
withApiIndexer _tracer cfg action = do
    now <- getCurrentTime
    readinessVar <-
        newTVarIO
            Readiness
                { rProcessedSlot = SlotNo 0
                , rTipSlot = SlotNo 0
                , rLagSlots = 0
                , rUpstreamUp = False
                , rUpdatedAt = now
                }
    Indexer.withRocksDBIndexer (icDbPath cfg) $ \handle ->
        withAsync (pure ()) $ \placeholder ->
            action
                ApiIndexer
                    { aiHandle = handle
                    , aiReadiness = readinessVar
                    , aiFollower = placeholder
                    , aiConfig = cfg
                    }

-- ---------------------------------------------------------------------------
-- Readiness

{- | Block until 'checkReady' would return 'Ready'. Called
once at boot before warp binds (Slice 3); MUST NOT be
called from per-request handler code — use 'checkReady'
there.
-}
waitReady :: ApiIndexer -> IO ()
waitReady apiIdx =
    atomically $ do
        r <- readTVar (aiReadiness apiIdx)
        let threshold =
                icLagThresholdSlots (aiConfig apiIdx)
        check (classifyReadiness threshold r == Ready)

{- | Per-request readiness verdict. Non-blocking snapshot
of the current 'Readiness' classified against
'icLagThresholdSlots'.
-}
checkReady :: ApiIndexer -> IO ReadyState
checkReady apiIdx = do
    r <- readTVarIO (aiReadiness apiIdx)
    pure $
        classifyReadiness
            (icLagThresholdSlots (aiConfig apiIdx))
            r

{- | Translate a raw 'Readiness' snapshot into the
'ReadyState' verdict the handler layer consumes. Pure;
the inputs are the threshold and the snapshot, the
output is one of the three states.

The order matters: when the follower has never reported,
@rUpstreamUp = False@ wins over the lag arithmetic
(which would otherwise read as @0 - 0 = 0 ≤ threshold@
and falsely classify the pre-readiness state as
'Ready').
-}
classifyReadiness :: Word64 -> Readiness -> ReadyState
classifyReadiness threshold r
    | not (rUpstreamUp r) = Pending
    | rLagSlots r > threshold =
        Lagging (rLagSlots r) threshold
    | otherwise = Ready

-- ---------------------------------------------------------------------------
-- Read operations

{- | Per-request UTxO scan at an address. Thin pass-through
to 'Indexer.snapshotAt' on the underlying 'IndexerHandle'.

The indexer-local 'TxOut' is a raw CBOR-encoded
transaction output; Slice 3's handler layer is
responsible for deserialising it to a Conway-era value
if needed.
-}
snapshotAt
    :: ApiIndexer
    -> Address
    -> IO [(TxIn, TxOut)]
snapshotAt apiIdx = Indexer.snapshotAt (aiHandle apiIdx)
