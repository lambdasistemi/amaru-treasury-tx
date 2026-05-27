{- |
Module      : Amaru.Treasury.Api.Readiness
Description : Readiness state machine for the embedded API indexer
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Bridges the upstream
'Cardano.Node.Client.UTxOIndexer.Follower.Readiness'
snapshot published by the embedded indexer into the
HTTP-server readiness state consumed by the API entry
point and lag guard.
-}
module Amaru.Treasury.Api.Readiness
    ( -- * State
      Readiness (..)
    , ReadyState (..)
    , ReadinessHandle (..)

      -- * Bridge
    , withReadinessBridge
    , bridgeReadiness

      -- * Queries
    , waitReady
    , checkReady
    ) where

import Cardano.Node.Client.N2C.Reconnect
    ( UpstreamStatus (..)
    )
import Cardano.Node.Client.UTxOIndexer.Follower qualified as Follower
import Cardano.Node.Client.UTxOIndexer.Types (SlotNo (..))
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
import Data.Maybe (fromMaybe)
import Data.Time.Clock (UTCTime, getCurrentTime)
import Data.Void (Void)
import Data.Word (Word64)

{- | Live readiness snapshot. The bridge thread writes
this 'TVar' after every roll-forward and on every
supervisor status transition.

@rUpstreamUp = False@ is the sentinel "no rollForward
yet" state. Until the bridge has seen the upstream
follower advance, 'checkReady' returns 'Pending' and the
readiness gate keeps warp from binding.
-}
data Readiness = Readiness
    { rProcessedSlot :: !SlotNo
    -- ^ Highest slot the follower has applied.
    , rTipSlot :: !SlotNo
    -- ^ Latest tip slot observed from the upstream node.
    , rLagSlots :: !Word64
    -- ^ @rTipSlot - rProcessedSlot@, kept alongside the
    -- raw slots so the lag guard can echo it in the HTTP
    -- 503 body without re-deriving.
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
request. Derived from 'Readiness' by 'checkReady' against
the configured lag threshold.
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
      -- configured threshold. Handlers should answer HTTP
      -- 503 with both numbers in the body.
      Lagging !Word64 !Word64
    deriving stock (Eq, Show)

{- | Handle for the API readiness bridge. The API main
thread uses it to block before binding warp, and the lag
guard samples it per request.
-}
data ReadinessHandle = ReadinessHandle
    { rhReadiness :: !(TVar Readiness)
    -- ^ Local readiness state maintained by the bridge.
    , rhBridge :: !(Async ())
    -- ^ Bridge thread mirroring the upstream follower
    -- readiness STM into 'rhReadiness'.
    , rhLagThresholdSlots :: !Word64
    -- ^ Drift threshold used by 'checkReady' and
    -- 'waitReady'.
    }

{- | Run the readiness bridge for the lifetime of the
action. The bridge is linked so an unexpected failure
propagates to the caller's thread.
-}
withReadinessBridge
    :: Word64
    -- ^ Lag threshold in slots.
    -> STM Follower.Readiness
    -- ^ Upstream follower readiness STM exposed by the
    -- embedded indexer.
    -> (ReadinessHandle -> IO a)
    -> IO a
withReadinessBridge threshold upstreamReadiness action = do
    now <- getCurrentTime
    local <- newTVarIO (initialReadiness now)
    withAsync
        (void $ bridgeReadiness upstreamReadiness local)
        $ \bridge -> do
            link bridge
            action
                ReadinessHandle
                    { rhReadiness = local
                    , rhBridge = bridge
                    , rhLagThresholdSlots = threshold
                    }

{- | Long-running bridge: block on changes to the upstream
follower's readiness STM and project each new snapshot
into the local 'TVar'.

The upstream 'Follower.Readiness' record has a
'Follower.rUpdatedAt' timestamp that is written every
time the follower mutates its 'TVar', so equality on that
field is sufficient to detect "no change yet" — we don't
need an 'Eq' instance on the upstream record.
-}
bridgeReadiness
    :: STM Follower.Readiness
    -> TVar Readiness
    -> IO Void
bridgeReadiness upstreamReadiness local = do
    initial <- atomically upstreamReadiness
    nowFirst <- getCurrentTime
    atomically $
        writeTVar local (projectReadiness initial nowFirst)
    go (Follower.rUpdatedAt initial)
  where
    go prevTime = do
        next <- atomically $ do
            current <- upstreamReadiness
            if Follower.rUpdatedAt current == prevTime
                then retry
                else pure current
        now <- getCurrentTime
        atomically $
            writeTVar local (projectReadiness next now)
        go (Follower.rUpdatedAt next)

{- | Block until 'checkReady' would return 'Ready'. Called
once at boot before warp binds; MUST NOT be called from
per-request handler code — use 'checkReady' there.
-}
waitReady :: ReadinessHandle -> IO ()
waitReady rh =
    atomically $ do
        r <- readTVar (rhReadiness rh)
        check (classifyReadiness (rhLagThresholdSlots rh) r == Ready)

{- | Per-request readiness verdict. Non-blocking snapshot
of the current 'Readiness' classified against the
configured lag threshold.
-}
checkReady :: ReadinessHandle -> IO ReadyState
checkReady rh = do
    r <- readTVarIO (rhReadiness rh)
    pure $
        classifyReadiness
            (rhLagThresholdSlots rh)
            r

initialReadiness :: UTCTime -> Readiness
initialReadiness now =
    Readiness
        { rProcessedSlot = SlotNo 0
        , rTipSlot = SlotNo 0
        , rLagSlots = 0
        , rUpstreamUp = False
        , rUpdatedAt = now
        }

{- | Map an upstream 'Follower.Readiness' snapshot into the
local 'Readiness' shape. Conservative on the upstream
state: 'rUpstreamUp' is 'True' only when the supervisor is
'UpstreamConnected' AND the follower has reported at least
one processed slot. The lag is computed as
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

{- | Translate a raw 'Readiness' snapshot into the
'ReadyState' verdict the handler layer consumes. Pure;
the inputs are the threshold and the snapshot, the output
is one of the three states.

The order matters: when the follower has never reported,
@rUpstreamUp = False@ wins over the lag arithmetic (which
would otherwise read as @0 - 0 = 0 <= threshold@ and
falsely classify the pre-readiness state as 'Ready').
-}
classifyReadiness :: Word64 -> Readiness -> ReadyState
classifyReadiness threshold r
    | not (rUpstreamUp r) = Pending
    | rLagSlots r > threshold =
        Lagging (rLagSlots r) threshold
    | otherwise = Ready
