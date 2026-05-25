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

= Slice 2 wiring (this commit)

The chain-sync follower from
'Cardano.Node.Client.UTxOIndexer.Follower' is now wired
in-process: 'withApiIndexer' opens RocksDB, brings the
follower up via 'Follower.withChainSyncFollower' against
the caller-owned handle, and runs a small bridge thread
that projects the upstream
'Follower.Readiness' into the local 'Readiness' record
the handlers consume. Both the upstream follower
'Async' and the bridge are 'link'ed inside the bracket so
exceptions propagate to the API container's main thread
and trigger a clean container restart.

The 'aiReadiness' 'TVar' shape, 'setReadinessForTest'
helper, and 'checkReady' / 'waitReady' / 'snapshotAt'
public API are unchanged from Slice 1, so the test suite
that drove them stays green.
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
    , snapshotUtxosAt

      -- * Internal helpers (exposed for tests)
    , toChainSyncCfg
    ) where

import Cardano.Crypto.Hash.Class (hashFromBytes)
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
    , unsafeMakeSafeHash
    )
import Cardano.Ledger.TxIn qualified as Ledger
import Cardano.Node.Client.N2C.Probe (ProbeConfig)
import Cardano.Node.Client.N2C.Reconnect
    ( ReconnectPolicy
    , UpstreamStatus (..)
    )
import Cardano.Node.Client.N2C.Trace (N2CEvent)
import Cardano.Node.Client.UTxOIndexer.Follower
    ( ChainSyncConfig (..)
    , FollowerHandle (..)
    )
import Cardano.Node.Client.UTxOIndexer.Follower qualified as Follower
import Cardano.Node.Client.UTxOIndexer.Indexer
    ( IndexerHandle
    )
import Cardano.Node.Client.UTxOIndexer.Indexer qualified as Indexer
import Cardano.Node.Client.UTxOIndexer.Types
    ( Address (..)
    , SlotNo (..)
    , TxIn
    , TxOut (..)
    )
import Cardano.Node.Client.UTxOIndexer.Types qualified as IxTypes
import Control.Concurrent.Async (Async, link, withAsync)
import Control.Concurrent.STM
    ( STM
    , TVar
    , atomically
    , check
    , newTVarIO
    , readTVar
    , readTVarIO
    , retry
    , writeTVar
    )
import Control.Monad (void)
import Control.Tracer (Tracer)
import Data.ByteString qualified as BS
import Data.Maybe (fromMaybe)
import Data.Time.Clock (UTCTime, getCurrentTime)
import Data.Void (Void)
import Data.Word (Word16, Word64)
import Ouroboros.Network.Magic (NetworkMagic)

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
    , icStartSlot :: !SlotNo
    -- ^ Cold-boot starting slot. Ignored once the
    -- on-disk store has a prior cursor (the follower's
    -- @getResumePoints@ wins).
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

{- | Live readiness snapshot. The follower's bridge
thread writes this 'TVar' after every roll-forward and
on every supervisor status transition.

@rUpstreamUp = False@ is the sentinel "no rollForward
yet" state. Until the bridge has seen the upstream
follower advance, 'checkReady' returns 'Pending' and
the readiness gate keeps warp from binding.
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
    -- ^ True only when the bridge has observed an
    -- upstream @UpstreamConnected@ AND a non-'Nothing'
    -- processed slot. False covers both "follower hasn't
    -- rolled yet" and "upstream is currently
    -- disconnected".
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
      -- "not yet listening"; warp does not bind until
      -- 'waitReady' returns.
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
'Handlers' record. The fields are exposed so the handler
layer can pass through to the underlying indexer and so
the API container can 'link' the follower thread if it
wants exceptions to propagate.
-}
data ApiIndexer = ApiIndexer
    { aiHandle :: !IndexerHandle
    -- ^ Underlying @utxo-indexer-lib@ handle. Shared
    -- between the follower writer and the handler
    -- readers; the upstream library guarantees
    -- thread-safety on reads.
    , aiReadiness :: !(TVar Readiness)
    -- ^ Updated by the bridge thread after each upstream
    -- 'Follower.Readiness' transition; read by
    -- 'checkReady' and 'waitReady'.
    , aiFollower :: !(Async ())
    -- ^ The upstream follower's supervised chain-sync
    -- thread. 'link'ed inside 'withApiIndexer'; callers
    -- typically don't need to link it again.
    , aiBridge :: !(Async ())
    -- ^ The 'bridgeReadiness' thread that mirrors the
    -- upstream 'Follower.Readiness' into 'aiReadiness'.
    -- Exposed so the test helper
    -- 'Amaru.Treasury.Api.Indexer.Internal.setReadinessForTest'
    -- can 'cancel' it before injecting a deterministic
    -- readiness value — otherwise the bridge can
    -- overwrite the test's write between the helper
    -- returning and the handler reading.
    -- Production handlers MUST NOT cancel this.
    , aiConfig :: !IndexerConfig
    -- ^ The configuration this indexer was opened with.
    }

-- ---------------------------------------------------------------------------
-- Bring-up

{- | Bring up the indexer: open the RocksDB store, spawn
the upstream chain-sync follower against it, run a
bridge thread that mirrors the upstream
'Follower.Readiness' into the local 'TVar', and hand a
fully wired 'ApiIndexer' to the action.

Resource-bracketed: on exit the bridge is cancelled, the
follower is cancelled, and the RocksDB handle is closed.
Follower and bridge are 'link'ed inside the bracket so
their exceptions propagate to the action's thread and
trigger a container restart.
-}
withApiIndexer
    :: Tracer IO N2CEvent
    -- ^ Tracer for follower lifecycle events.
    -> IndexerConfig
    -> (ApiIndexer -> IO a)
    -> IO a
withApiIndexer tracer cfg action = do
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
        Follower.withChainSyncFollower
            tracer
            (toChainSyncCfg cfg)
            handle
            $ \fh ->
                withAsync
                    ( void $
                        bridgeReadiness
                            (fhReadiness fh)
                            readinessVar
                    )
                    $ \bridge -> do
                        link bridge
                        link (fhAsync fh)
                        action
                            ApiIndexer
                                { aiHandle = handle
                                , aiReadiness = readinessVar
                                , aiFollower = fhAsync fh
                                , aiBridge = bridge
                                , aiConfig = cfg
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
        }

{- | Long-running bridge: block on changes to the
upstream follower's readiness STM and project each new
snapshot into the local 'TVar'.

The upstream 'Follower.Readiness' record has a
'Follower.rUpdatedAt' timestamp that is written every
time the follower mutates its 'TVar', so equality on
that field is sufficient to detect "no change yet" —
we don't need an 'Eq' instance on the upstream record.

Returns 'absurd' on its 'Void' loop to silence the
unused-result warning at the call site; in practice the
loop only exits when 'withAsync' cancels it on
'withApiIndexer' exit.
-}
bridgeReadiness
    :: STM Follower.Readiness
    -> TVar Readiness
    -> IO Void
bridgeReadiness fhRead local = do
    initial <- atomically fhRead
    nowFirst <- getCurrentTime
    atomically $
        writeTVar local (projectReadiness initial nowFirst)
    go (Follower.rUpdatedAt initial)
  where
    go prevTime = do
        next <- atomically $ do
            current <- fhRead
            if Follower.rUpdatedAt current == prevTime
                then retry
                else pure current
        now <- getCurrentTime
        atomically $
            writeTVar local (projectReadiness next now)
        go (Follower.rUpdatedAt next)

{- | Map an upstream 'Follower.Readiness' snapshot into the
local 'Readiness' shape. Conservative on the upstream
state: 'rUpstreamUp' is 'True' only when the supervisor
is 'UpstreamConnected' AND the follower has reported at
least one processed slot. The lag is computed as
@max 0 (tip - processed)@.
-}
projectReadiness :: Follower.Readiness -> UTCTime -> Readiness
projectReadiness fr now =
    Readiness
        { rProcessedSlot = fromMaybeSlot processed
        , rTipSlot = fromMaybeSlot tip
        , rLagSlots = computeLag processed tip
        , rUpstreamUp = case (Follower.rUpstream fr, processed) of
            (UpstreamConnected, Just _) -> True
            _ -> False
        , rUpdatedAt = now
        }
  where
    processed = Follower.rProcessedSlot fr
    tip = Follower.rTipSlot fr

fromMaybeSlot :: Maybe SlotNo -> SlotNo
fromMaybeSlot = fromMaybe (SlotNo 0)

computeLag :: Maybe SlotNo -> Maybe SlotNo -> Word64
computeLag (Just (SlotNo p)) (Just (SlotNo t))
    | t > p = t - p
    | otherwise = 0
computeLag _ _ = 0

-- ---------------------------------------------------------------------------
-- Readiness

{- | Block until 'checkReady' would return 'Ready'. Called
once at boot before warp binds; MUST NOT be called from
per-request handler code — use 'checkReady' there.
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

{- | Per-request UTxO scan at an indexer-typed address.
Thin pass-through to 'Indexer.snapshotAt' on the
underlying 'IndexerHandle'.

The indexer's 'TxOut' is the raw CBOR bytes the follower
recorded on apply-block. Consumers that need
@Conway.TxOut@-typed values should call 'snapshotUtxosAt'
instead.
-}
snapshotAt
    :: ApiIndexer
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
    :: ApiIndexer
    -> Addr
    -> IO [(Ledger.TxIn, Ledger.TxOut ConwayEra)]
snapshotUtxosAt apiIdx addr = do
    raw <-
        Indexer.snapshotAt
            (aiHandle apiIdx)
            (Address (serialiseAddr addr))
    traverse convertEntry raw

convertEntry
    :: (TxIn, TxOut)
    -> IO (Ledger.TxIn, Ledger.TxOut ConwayEra)
convertEntry (ixTxIn, IxTypes.TxOut bytes) = do
    txOut <- case decodeConwayTxOut bytes of
        Right o -> pure o
        Left err ->
            ioError $
                userError $
                    "snapshotUtxosAt: failed to decode \
                    \indexer TxOut bytes as ConwayEra TxOut: "
                        <> show err
    pure (convertTxIn ixTxIn, txOut)

decodeConwayTxOut
    :: BS.ByteString
    -> Either DecoderError (Ledger.TxOut ConwayEra)
decodeConwayTxOut = decodeFull' (eraProtVerLow @ConwayEra)

convertTxIn :: TxIn -> Ledger.TxIn
convertTxIn (IxTypes.TxIn idBytes ix) =
    Ledger.TxIn
        (Ledger.TxId (mkSafeHash idBytes))
        (TxIx ix)

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
