{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Api.LagGuard
Description : WAI 503 middleware for indexer readiness lag
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Middleware that samples the API indexer readiness state
before each request and fail-closes with HTTP 503 while
the embedded indexer is too far behind the upstream tip.
-}
module Amaru.Treasury.Api.LagGuard
    ( withLagGuard
    , encodeLaggingBody
    ) where

import Control.Concurrent.STM (readTVarIO)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Word (Word64)
import Network.HTTP.Types (status503)
import Network.Wai (Middleware, responseLBS)

import Cardano.Node.Client.UTxOIndexer.Types (SlotNo (..))

import Amaru.Treasury.Api.Readiness
    ( Readiness (..)
    , ReadinessHandle (..)
    , ReadyState (..)
    , checkReady
    )

{- | WAI middleware that short-circuits every request with
HTTP 503 + structured JSON body when the embedded
indexer's readiness verdict is 'Lagging'.

The 503 body shape matches @contracts/api-extension.md@:
@{error,processed_slot,tip_slot,lag_slots,threshold_slots,
updated_at}@ with @additionalProperties: false@. The
response is set @Content-Type: application/json;
charset=utf-8@; @Accept@-negotiation is intentionally
skipped — the 503 body is JSON regardless of what the
client asked for, mirroring the spec's intake decision
("dashboard frontend detects the 503 status and surfaces
an error state").

When the verdict is 'Pending' or 'Ready', the request is
passed through unchanged. 'Pending' is supposed to be
prevented from being observed by external clients because
warp doesn't bind until 'waitReady' returns; the middleware
nonetheless treats 'Pending' as "let through" (a
defence-in-depth choice — the contract is silent on what
to do during pre-bind probes).
-}
withLagGuard :: ReadinessHandle -> Middleware
withLagGuard readiness app req respond = do
    state <- checkReady readiness
    case state of
        Lagging lag threshold -> do
            r <- readTVarIO (rhReadiness readiness)
            let body = encodeLaggingBody r lag threshold
                hdrs =
                    [
                        ( "Content-Type"
                        , "application/json; charset=utf-8"
                        )
                    ]
            respond (responseLBS status503 hdrs body)
        _ -> app req respond

{- | Encode the HTTP 503 body the lag-guard returns. The
schema is fixed by @contracts/api-extension.md@; consumers
can rely on the field set being exactly the six listed
keys and on @additionalProperties: false@. Tests pin this
shape directly via @aeson-keymap@ lookups.
-}
encodeLaggingBody
    :: Readiness -> Word64 -> Word64 -> LBS.ByteString
encodeLaggingBody r lag threshold =
    Aeson.encode $
        Aeson.object
            [ "error" .= ("indexer_lagging" :: Text)
            , "processed_slot" .= unSlotNo (rProcessedSlot r)
            , "tip_slot" .= unSlotNo (rTipSlot r)
            , "lag_slots" .= lag
            , "threshold_slots" .= threshold
            , "updated_at" .= rUpdatedAt r
            ]
