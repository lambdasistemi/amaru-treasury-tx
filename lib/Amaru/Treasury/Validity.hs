{- |
Module      : Amaru.Treasury.Validity
Description : Compute the @invalid_hereafter@ slot
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Returns the upper validity bound as
@currentSlot + ttlSeconds@, derived from the system
wall-clock and the node's hard-fork interpreter.

Justified divergence from the bash recipe
[`compute_validity_period.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/lib/compute_validity_period.sh)
is documented in
[`research.md` R4](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/specs/001-treasury-tx-cli/research.md#r4--provider-capability-gap-analysis):
the bash uses @slotsToEpochEnd@ which 'Provider' does not
expose; a wall-clock-driven TTL is correct for any era and
matches what light wallets emit. Default 1 hour, configurable
via the CLI's @--ttl-seconds@ flag.
-}
module Amaru.Treasury.Validity
    ( computeUpperBound
    ) where

import Data.Time.Clock.POSIX (getPOSIXTime)

import Amaru.Treasury.Backend (Backend, Provider (..), SlotNo)

{- | Compute the @invalid_hereafter@ slot for a tx
built right now: ask the backend for the slot at the
current wall-clock time, then add the user-supplied
TTL in seconds (typically @3600@).
-}
computeUpperBound
    :: Backend
    -- ^ provider exposing @posixMsToSlot@
    -> Integer
    -- ^ TTL in seconds (e.g. @3600@ for one hour)
    -> IO SlotNo
computeUpperBound backend ttlSeconds = do
    nowMs <- nowPosixMs
    let bound = nowMs + ttlSeconds * 1000
    posixMsToSlot backend bound

-- | Current wall-clock time as POSIX milliseconds.
nowPosixMs :: IO Integer
nowPosixMs = do
    t <- getPOSIXTime
    pure $ floor (realToFrac t * 1000 :: Double)
