{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Api.RateLimit
Description : Shared nonblocking limiter for mutating API actions
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Small API-owned single-flight limiter used to keep mutating HTTP
operations from overlapping. Read-only endpoints do not use it.
-}
module Amaru.Treasury.Api.RateLimit
    ( -- * Limiter
      ApiLimiter
    , newApiLimiter
    , withApiLimiter
    ) where

import Control.Concurrent.MVar
    ( MVar
    , newMVar
    , putMVar
    , tryTakeMVar
    )
import Control.Exception
    ( finally
    , mask
    )
import System.Timeout (timeout)

import Amaru.Treasury.Api.Types (ApiError (..))

-- | A single-slot limiter shared by API mutating endpoints.
newtype ApiLimiter = ApiLimiter (MVar ())

-- | Allocate an unsaturated API limiter.
newApiLimiter :: IO ApiLimiter
newApiLimiter = ApiLimiter <$> newMVar ()

{- | Hard ceiling on one mutating request, in microseconds.

A provider call on the build/verify path has been observed (#449)
hanging indefinitely — no exception, ever — which starves this
limiter's single slot forever (every subsequent build/submit gets
rejected with \"another build or submit request is already
running\" until the process is restarted). A real build completes
in well under a second; 60s is generous headroom for a slow node
while still guaranteeing the slot is always reclaimed.
-}
buildTimeoutMicros :: Int
buildTimeoutMicros = 60 * 1_000_000

{- | Run an action only if the limiter's single slot can be acquired
immediately.

When the slot is already held, the action is not executed and a
global 'ApiError' is returned. The action is bounded by
'buildTimeoutMicros': on timeout it is cancelled and a distinct
'ApiError' is returned instead of hanging the caller too. Either
way, the slot is released after the action returns, throws, or
times out.
-}
withApiLimiter
    :: ApiLimiter
    -> IO (Either ApiError a)
    -> IO (Either ApiError a)
withApiLimiter (ApiLimiter slot) action =
    mask $ \restore -> do
        acquired <- tryTakeMVar slot
        case acquired of
            Nothing ->
                pure $
                    Left
                        ApiError
                            { aeMessage =
                                "another build or submit request is already running"
                            , aeField = Nothing
                            }
            Just () -> do
                result <-
                    restore (timeout buildTimeoutMicros action)
                        `finally` putMVar slot ()
                case result of
                    Nothing ->
                        pure $
                            Left
                                ApiError
                                    { aeMessage =
                                        "build/submit request timed out after 60s (server-side node connection likely stuck; this is a server bug, not an input error)"
                                    , aeField = Nothing
                                    }
                    Just r -> pure r
