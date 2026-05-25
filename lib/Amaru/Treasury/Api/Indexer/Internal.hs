{- |
Module      : Amaru.Treasury.Api.Indexer.Internal
Description : Test-only helpers for the API indexer runner
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Test-only entry points into "Amaru.Treasury.Api.Indexer"
that production callers MUST NOT import. The
@.Internal@ suffix is the project's signal that the
module is exempted from semver and provides escape
hatches the public surface does not.

Currently exposes 'setReadinessForTest', the
follower-equivalent write used by the unit suite to
simulate readiness transitions without spinning up a
real chain-sync client.
-}
module Amaru.Treasury.Api.Indexer.Internal
    ( setReadinessForTest
    ) where

import Control.Concurrent.Async (cancel)
import Control.Concurrent.STM (atomically, writeTVar)

import Amaru.Treasury.Api.Indexer
    ( ApiIndexer (..)
    , Readiness
    )

{- | Deterministically replace the readiness 'TVar'
contents. Cancels the in-process bridge thread first so
the upstream follower can no longer mirror its
@Follower.Readiness@ over the test's write.

The race motivation: 'withApiIndexer' spawns a
'bridgeReadiness' thread that wakes on every upstream
readiness change and projects it into 'aiReadiness'.
Tests that open 'withApiIndexer' against a missing-socket
config get the supervisor's probe loop emitting
@UpstreamDisconnected@ events, which the bridge projects
to @rUpstreamUp = False@ — overwriting any test write
that asked for 'Ready' or 'Lagging'. The fix is to kill
the bridge before the test writes; after that, the
'TVar' reflects exactly what the test injected for the
remainder of the action.

The cancel is idempotent ('Control.Concurrent.Async.cancel'
on an already-finished 'Async' is a no-op), so calling
'setReadinessForTest' multiple times in one test is
safe — only the first call actually kills the bridge.

Production code MUST NOT call this helper. Cancelling
the bridge in a long-running container would freeze the
readiness gate at whatever value the bridge last
mirrored, defeating the FR-009 lag-503 contract.
-}
setReadinessForTest :: ApiIndexer -> Readiness -> IO ()
setReadinessForTest apiIdx r = do
    cancel (aiBridge apiIdx)
    atomically $ writeTVar (aiReadiness apiIdx) r
