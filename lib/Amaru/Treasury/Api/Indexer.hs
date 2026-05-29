{-# LANGUAGE RankNTypes #-}

{- |
Module      : Amaru.Treasury.Api.Indexer
Description : Runner + query API for the embedded API indexer
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
'Indexer.IndexerHandle' with the chain-sync follower
that writes into it.

The chain-sync follower from
'Cardano.Node.Client.UTxOIndexer.Follower' is now wired
in-process: 'withApiIndexer' opens RocksDB, brings the
follower up via 'Follower.withChainSyncFollower' against
the caller-owned handle, and exposes the follower's
readiness STM for the API readiness bridge to consume.
The upstream follower 'Async' is 'link'ed inside the
bracket so exceptions propagate to the API container's
main thread and trigger a clean container restart.
-}
module Amaru.Treasury.Api.Indexer
    ( -- * Configuration and state
      IndexerConfig (..)
    , ApiIndexer (..)

      -- * Bring-up
    , withApiIndexer

      -- * Read operations
    , snapshotAt
    , snapshotUtxosAt
    , snapshotUtxosByTxIn

      -- * Internal helpers (exposed for tests)
    , toChainSyncCfg
    ) where

import Cardano.Crypto.Hash.Class (hashFromBytes, hashToBytes)
import Cardano.Ledger.Address (Addr, serialiseAddr)
import Cardano.Ledger.Api.Era (eraProtVerLow)
import Cardano.Ledger.BaseTypes (TxIx (..))
import Cardano.Ledger.Binary
    ( DecoderError
    , decodeFull'
    )
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core qualified as Ledger
import Cardano.Ledger.Hashes
    ( SafeHash
    , extractHash
    , unsafeMakeSafeHash
    )
import Cardano.Ledger.TxIn qualified as Ledger
import Cardano.Node.Client.N2C.Probe (ProbeConfig)
import Cardano.Node.Client.N2C.Reconnect
    ( ReconnectPolicy
    )
import Cardano.Node.Client.N2C.Trace (N2CEvent)
import Cardano.Node.Client.UTxOIndexer.Columns (Cols)
import Cardano.Node.Client.UTxOIndexer.Follower
    ( ChainSyncConfig (..)
    )
import Cardano.Node.Client.UTxOIndexer.Follower qualified as Follower
import Cardano.Node.Client.UTxOIndexer.Indexer
    ( IndexerHandle
    )
import Cardano.Node.Client.UTxOIndexer.Indexer qualified as Indexer
import Cardano.Node.Client.UTxOIndexer.Types
    ( Address (..)
    , BlockHash
    , SlotNo (..)
    , TxIn
    , TxOut (..)
    )
import Cardano.Node.Client.UTxOIndexer.Types qualified as IxTypes
import Control.Concurrent.Async (Async, link)
import Control.Concurrent.STM
    ( STM
    )
import Control.Tracer (Tracer (Tracer), nullTracer)
import Data.ByteString qualified as BS
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Word (Word64)
import Database.KV.Transaction (RunTransaction)
import Ouroboros.Network.Magic (NetworkMagic)
import System.IO (hPutStrLn, stderr)

-- ---------------------------------------------------------------------------
-- Types

{- | Static configuration captured from CLI flags and
environment. Built once at boot by
@app\/amaru-treasury-tx-api\/Main.hs@ and threaded into
'withApiIndexer'.

The first five fields surface as operator CLI flags; the
last four are internally defaulted to mainnet values
(documented per field) so the operator surface stays
small. A later polish ticket can promote the internals
to flags if real tuning need arises.
-}
data IndexerConfig = IndexerConfig
    { icDbPath :: !FilePath
    -- ^ RocksDB directory. Created if missing.
    , icSocketPath :: !FilePath
    -- ^ Path to the node N2C socket the chain-sync
    -- follower connects to.
    , icNetworkMagic :: !NetworkMagic
    -- ^ Network magic for the chain-sync handshake.
    , icStartPoint :: !(Maybe (SlotNo, BlockHash))
    -- ^ Cold-boot intersection point. Ignored once the
    -- on-disk store has a prior cursor (the follower's
    -- @getResumePoints@ wins). 'Nothing' starts at Origin.
    , icLagThresholdSlots :: !Word64
    -- ^ Drift threshold. When
    -- @tip_slot - processed_slot > this value@,
    -- 'checkReady' returns 'Lagging' and the handler
    -- layer answers HTTP 503.
    , icByronEpochSlots :: !Word64
    -- ^ Byron @EpochSlots@. Default 21_600 matches mainnet
    -- (@10·k@ where @k = 2160@; mainnet @k@ comes from
    -- @byron-genesis.json@ @protocolConsts.k@). The Byron
    -- CBOR decoder threads this as a structural parameter;
    -- mismatch yields a divergent block hash on every roll
    -- and the chain-sync server disconnects with
    -- @ApplyConflict@.
    , icSecurityParamK :: !Int
    -- ^ Cardano security parameter @k@. Default 2160
    -- matches mainnet; caps the rollback-log length and
    -- bounds the depth of in-flight chain rewinds the
    -- follower will replay.
    , icReconnectPolicy :: !ReconnectPolicy
    -- ^ Backoff policy for the in-process reconnect
    -- supervisor wrapped around the chain-sync session.
    -- Default 'Cardano.Node.Client.N2C.Reconnect.defaultReconnectPolicy'.
    , icProbeConfig :: !ProbeConfig
    -- ^ LSQ tip-probe configuration that gates each
    -- reconnect attempt. Default
    -- 'Cardano.Node.Client.N2C.Probe.defaultProbeConfig'
    -- (chain-replay-tolerant; unbounded total timeout).
    , icInterestSet :: !Follower.InterestSet
    -- ^ Apply-time address filter (issue #158). The API
    -- container constructs an 'IndexAddressSet' from the
    -- 4 treasury scope addresses plus the SundaeSwap
    -- order address, so the embedded indexer's RocksDB
    -- stays bounded to the addresses the dashboard ever
    -- queries. Tests typically pass 'IndexAll' to keep
    -- the fixture surface minimal.
    }

{- | Opaque handle the API container threads through its
'Handlers' record. The fields are exposed so the handler
layer can pass through to the underlying indexer and so
the API container can 'link' the follower thread if it
wants exceptions to propagate.
-}
data ApiIndexer cf op = ApiIndexer
    { aiHandle :: !IndexerHandle
    -- ^ Underlying @utxo-indexer-lib@ handle. Shared
    -- between the follower writer and the handler
    -- readers; the upstream library guarantees
    -- thread-safety on reads.
    , aiFollowerReadiness :: !(STM Follower.Readiness)
    -- ^ STM snapshot published by the upstream follower.
    -- The API readiness module consumes this to maintain
    -- the HTTP-server readiness state; this indexer layer
    -- deliberately does not classify readiness itself.
    , aiFollower :: !(Async ())
    -- ^ The upstream follower's supervised chain-sync
    -- thread. 'link'ed inside 'withApiIndexer'; callers
    -- typically don't need to link it again.
    , aiConfig :: !IndexerConfig
    -- ^ The configuration this indexer was opened with.
    , aiRunner :: !(RunTransaction IO cf Cols op)
    -- ^ Transaction runner for the same indexer store as
    -- 'aiHandle'. The API provider adapter uses this for
    -- typed indexer reads while the follower mutates the
    -- store through 'aiHandle'.
    }

-- ---------------------------------------------------------------------------
-- Bring-up

{- | Bring up the indexer: open the RocksDB store, spawn
the upstream chain-sync follower against it, and hand a
fully wired 'ApiIndexer' to the action.

Resource-bracketed: on exit the follower is cancelled and
the RocksDB handle is closed. The follower is 'link'ed
inside the bracket so its exceptions propagate to the
action's thread and trigger a container restart.
-}
withApiIndexer
    :: Tracer IO N2CEvent
    -- ^ Tracer for follower lifecycle events.
    -> IndexerConfig
    -> (forall cf op. ApiIndexer cf op -> IO a)
    -> IO a
withApiIndexer tracer cfg action =
    Indexer.withRocksDBIndexerRunner (icDbPath cfg) $ \handle runner ->
        Follower.withChainSyncFollower
            tracer
            (toChainSyncCfg cfg)
            handle
            $ \fh -> do
                link (Follower.fhAsync fh)
                action
                    ApiIndexer
                        { aiHandle = handle
                        , aiFollowerReadiness =
                            Follower.fhReadiness fh
                        , aiFollower = Follower.fhAsync fh
                        , aiConfig = cfg
                        , aiRunner = runner
                        }

{- | Project the runner's 'IndexerConfig' into the
upstream follower's 'ChainSyncConfig'. The transformation
is field-by-field; the threshold is shared so the
follower and the readiness gate stay in lock-step.
-}
toChainSyncCfg :: IndexerConfig -> ChainSyncConfig
toChainSyncCfg cfg =
    ChainSyncConfig
        { csRelaySocket = icSocketPath cfg
        , csNetworkMagic = icNetworkMagic cfg
        , csByronEpochSlots = icByronEpochSlots cfg
        , csReadyThresholdSlots = icLagThresholdSlots cfg
        , csSecurityParamK = icSecurityParamK cfg
        , csReconnectPolicy = icReconnectPolicy cfg
        , csProbeConfig = icProbeConfig cfg
        , csInterestSet = icInterestSet cfg
        , -- Upstream handler-list seam
          -- (cardano-node-clients#168/#169). The API
          -- container still wants the standard UTxO
          -- columns, so it registers the live UTxO
          -- handler explicitly. Future tx-history slices
          -- can append their own handler here without
          -- opening a second chain-sync follower.
          csHandlers =
            Indexer.liveUtxoHandler (icInterestSet cfg)
                :| []
        , -- Cold-boot intersection seed (upstream
          -- cardano-node-clients#162). 'Nothing' means
          -- intersect at Origin and walk forward (the EBB
          -- skip from #163 prevents the Byron-era
          -- ApplyConflict that otherwise blocks cold sync
          -- from mainnet).
          csStartPoint = icStartPoint cfg
        , -- Per-block tracer (upstream
          -- cardano-node-clients#165 round-2). Silenced for
          -- now: a roll-forward stream during cold-sync
          -- emits thousands of events/sec which would
          -- overflow docker's rotating log. Future
          -- enhancement: throttle by slot-modulus to log
          -- one milestone per ~10k slots.
          csBlockTracer = nullTracer
        , -- Upstream tip tracer. Fires on every chain-tip
          -- update from the cardano-node (~once per 20s on
          -- mainnet). Surfaces 'lag visible to upstream'
          -- in container logs so operators can see whether
          -- the indexer is keeping up.
          -- Per-MsgRollForward tracer. Fires once per
          -- block received by the chain-sync follower (NOT
          -- only on tip change). During cold-sync this is
          -- the only proxy for indexer throughput, so we
          -- enable it for dev validation despite the
          -- per-block stderr syscall + docker json-log
          -- write overhead. A future enhancement should
          -- replace this with a throttled bridge-thread
          -- heartbeat that reads the readiness STM at a
          -- fixed cadence instead of firing per block.
          csTipTracer = Tracer $ \slot ->
            hPutStrLn
                stderr
                ( "amaru-treasury-tx-api: \
                  \upstream tip slot="
                    <> show slot
                )
        }

-- ---------------------------------------------------------------------------
-- Read operations

{- | Per-request UTxO scan at an indexer-typed address.
Thin pass-through to 'Indexer.snapshotAt' on the
underlying 'IndexerHandle'.

The indexer's 'TxOut' is the raw CBOR bytes the follower
recorded on apply-block. Consumers that need
@Conway.TxOut@-typed values should call 'snapshotUtxosAt'
instead.
-}
snapshotAt
    :: ApiIndexer cf op
    -> Address
    -> IO [(TxIn, TxOut)]
snapshotAt apiIdx = Indexer.snapshotAt (aiHandle apiIdx)

{- | Per-request UTxO scan at a ledger-typed address,
returned in the @(TxIn, TxOut ConwayEra)@ shape the
handler layer's existing 'runInspectFromBackend'
machinery consumes.

Conversion at the boundary:

* @'Ledger.Addr'@ → raw address bytes via 'serialiseAddr'
  — the same encoder
  'Cardano.Node.Client.UTxOIndexer.BlockExtract' uses on
  the apply path, so the round-trip is bit-stable.
* Indexer @'TxOut'@ raw bytes → @'Ledger.TxOut'
  ConwayEra@ via 'decodeFull'' against
  @'eraProtVerLow' \@ConwayEra@ — same protocol version
  the upstream encoder pinned on serialisation, so the
  decode is round-trip-stable.
* Indexer @'TxIn'@ (32-byte tx id + 'Word16' ix) →
  @'Ledger.TxIn'@ — wrap the bytes in a Blake2b 'SafeHash'
  and the ix in a 'TxIx'.

Throws an 'IOError' on a decode failure: that signals
a serious upstream\/downstream version skew (the
follower wrote bytes the handler cannot read), which
the operator must triage. A graceful "best-effort skip"
is the wrong default — it would mask data loss.
-}
snapshotUtxosAt
    :: ApiIndexer cf op
    -> Addr
    -> IO [(Ledger.TxIn, Ledger.TxOut ConwayEra)]
snapshotUtxosAt apiIdx addr = do
    raw <-
        Indexer.snapshotAt
            (aiHandle apiIdx)
            (Address (serialiseAddr addr))
    traverse convertEntry raw

{- | Point lookup for ledger-typed UTxOs by exact input,
served from the embedded indexer.

This wraps upstream 'Indexer.awaitTxIn' with a zero-second
timeout: already indexed, still-unspent inputs return
immediately; missing or spent inputs return 'Nothing'
without waiting for future chain events. That gives build
finalization the same current-snapshot semantics as a live
@queryUTxOByTxIn@ call while keeping the API request path
off address and exact-input queries against the production
node.
-}
snapshotUtxosByTxIn
    :: ApiIndexer cf op
    -> Set.Set Ledger.TxIn
    -> IO (Map.Map Ledger.TxIn (Ledger.TxOut ConwayEra))
snapshotUtxosByTxIn apiIdx txIns =
    Map.fromList
        <$> traverseMaybe lookupOne (Set.toList txIns)
  where
    lookupOne ledgerTxIn = do
        mObs <-
            Indexer.awaitTxIn
                (aiHandle apiIdx)
                (toIndexerTxIn ledgerTxIn)
                (Just 0)
        case mObs of
            Nothing -> pure Nothing
            Just obs -> do
                txOut <- decodeIndexerTxOut (Indexer.aoTxOut obs)
                pure (Just (ledgerTxIn, txOut))

traverseMaybe :: (a -> IO (Maybe b)) -> [a] -> IO [b]
traverseMaybe f =
    fmap foldMaybes . traverse f
  where
    foldMaybes [] = []
    foldMaybes (Nothing : xs) = foldMaybes xs
    foldMaybes (Just x : xs) = x : foldMaybes xs

convertEntry
    :: (TxIn, TxOut)
    -> IO (Ledger.TxIn, Ledger.TxOut ConwayEra)
convertEntry (ixTxIn, IxTypes.TxOut bytes) = do
    txOut <- decodeIndexerTxOut (IxTypes.TxOut bytes)
    pure (convertTxIn ixTxIn, txOut)

decodeIndexerTxOut
    :: TxOut
    -> IO (Ledger.TxOut ConwayEra)
decodeIndexerTxOut (IxTypes.TxOut bytes) =
    case decodeConwayTxOut bytes of
        Right o -> pure o
        Left err ->
            ioError $
                userError $
                    "snapshotUtxosAt: failed to decode \
                    \indexer TxOut bytes as ConwayEra TxOut: "
                        <> show err

decodeConwayTxOut
    :: BS.ByteString
    -> Either DecoderError (Ledger.TxOut ConwayEra)
decodeConwayTxOut = decodeFull' (eraProtVerLow @ConwayEra)

convertTxIn :: TxIn -> Ledger.TxIn
convertTxIn (IxTypes.TxIn idBytes ix) =
    Ledger.TxIn
        (Ledger.TxId (mkSafeHash idBytes))
        (TxIx ix)

toIndexerTxIn :: Ledger.TxIn -> TxIn
toIndexerTxIn (Ledger.TxIn (Ledger.TxId txIdHash) txIx) =
    IxTypes.TxIn
        (hashToBytes (extractHash txIdHash))
        (unTxIx txIx)

{- | Re-wrap the indexer's 32-byte raw tx-id bytes as a
ledger 'SafeHash'. 'unsafeMakeSafeHash' is the right
constructor here: the upstream indexer wrote these exact
bytes from a known-good 'Ledger.TxId' via
'extractHash' on the apply path, so reassembling on the
read path round-trips byte-identically.
-}
mkSafeHash :: BS.ByteString -> SafeHash a
mkSafeHash bs =
    case hashFromBytes bs of
        Just h -> unsafeMakeSafeHash h
        Nothing ->
            error
                "Amaru.Treasury.Api.Indexer.mkSafeHash: \
                \indexer wrote a tx-id that is not a \
                \valid Blake2b_256 digest; this is a \
                \cardano-node-clients invariant violation"
