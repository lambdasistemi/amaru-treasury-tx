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

import Control.Concurrent.STM (atomically, writeTVar)

import Amaru.Treasury.Api.Indexer
    ( ApiIndexer (..)
    , Readiness
    )

{- | Atomically replace the readiness 'TVar' contents.
Used by the unit suite to step the readiness state
machine through the transitions the real chain-sync
follower (Slice 3) will drive.
-}
setReadinessForTest :: ApiIndexer -> Readiness -> IO ()
setReadinessForTest apiIdx r =
    atomically $ writeTVar (aiReadiness apiIdx) r
