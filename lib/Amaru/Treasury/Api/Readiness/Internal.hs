{- |
Module      : Amaru.Treasury.Api.Readiness.Internal
Description : Test-only helpers for API readiness
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Test-only entry points into
"Amaru.Treasury.Api.Readiness" that production callers
MUST NOT import. The @.Internal@ suffix is the project's
signal that the module is exempted from semver and
provides escape hatches the public surface does not.
-}
module Amaru.Treasury.Api.Readiness.Internal
    ( setReadinessForTest
    ) where

import Control.Concurrent.Async (cancel)
import Control.Concurrent.STM (atomically, writeTVar)

import Amaru.Treasury.Api.Readiness
    ( Readiness
    , ReadinessHandle (..)
    )

{- | Deterministically replace the readiness 'TVar'
contents. Cancels the in-process bridge thread first so
the upstream follower can no longer mirror its
@Follower.Readiness@ over the test's write.

Production code MUST NOT call this helper. Cancelling the
bridge in a long-running container would freeze the
readiness gate at whatever value the bridge last mirrored,
defeating the FR-009 lag-503 contract.
-}
setReadinessForTest :: ReadinessHandle -> Readiness -> IO ()
setReadinessForTest readiness r = do
    cancel (rhBridge readiness)
    atomically $ writeTVar (rhReadiness readiness) r
