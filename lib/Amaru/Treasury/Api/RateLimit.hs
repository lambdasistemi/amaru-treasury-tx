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

import Amaru.Treasury.Api.Types (ApiError (..))

-- | A single-slot limiter shared by API mutating endpoints.
newtype ApiLimiter = ApiLimiter (MVar ())

-- | Allocate an unsaturated API limiter.
newApiLimiter :: IO ApiLimiter
newApiLimiter = ApiLimiter <$> newMVar ()

{- | Run an action only if the limiter's single slot can be acquired
immediately.

When the slot is already held, the action is not executed and a
global 'ApiError' is returned. The slot is released after the action
returns or throws.
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
            Just () ->
                restore action `finally` putMVar slot ()
