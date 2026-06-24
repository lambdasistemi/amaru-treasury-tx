{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE StrictData #-}

{- |
Module      : Amaru.Treasury.Api.BuildSwapRerate
Description : JSON carriers for @POST /v1/build/swap-rerate@
              (#401).
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Shallow HTTP request and response types for the swap re-rate
build endpoint.  This first API slice wires the route and
returns a structured placeholder from the production runner;
the next slice replaces that placeholder with the merged
re-rate planner and builder.
-}
module Amaru.Treasury.Api.BuildSwapRerate
    ( -- * Request
      SwapRerateBuildRequest (..)

      -- * Response
    , SwapRerateBuildResponse (..)

      -- * Handler runner
    , runBuildSwapRerate
    ) where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import GHC.Generics (Generic)
import System.IO (stderr)

import Amaru.Treasury.Backend (Backend)
import Amaru.Treasury.Scope (ScopeId)

-- ---------------------------------------------------------------------------
-- Request

{- | Operator-supplied swap re-rate inputs over HTTP.

The selected order and wallet inputs are plain @txid#index@
texts in this slice.  The later runner slice is responsible
for parsing them into the pure re-rate core's input types and
returning typed input failures.
-}
data SwapRerateBuildRequest = SwapRerateBuildRequest
    { srrScope :: ScopeId
    , srrSelectedOrders :: [Text]
    , srrNewRate :: Double
    , srrWalletTxIn :: Text
    , srrCollateralTxIn :: Maybe Text
    }
    deriving (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

-- ---------------------------------------------------------------------------
-- Response

{- | Shape of @POST /v1/build/swap-rerate@ response for the
route-and-stub slice.

Exactly one high-level outcome should be present.  Until the
real runner lands, the production runner returns the typed
failure arm while tests can still prove that the route decodes
a request and returns the handler's typed response.
-}
data SwapRerateBuildResponse = SwapRerateBuildResponse
    { srrCborHex :: Maybe Text
    -- ^ Hex-encoded unsigned Conway tx body on success.
    , srrCborEnvelope :: Maybe Text
    -- ^ Cardano CLI text-envelope JSON for the unsigned body.
    , srrReport :: Maybe Text
    -- ^ Pretty-printed build report on success.
    , srrDecision :: Maybe Text
    -- ^ Machine-readable decision, e.g. @single_tx@ or @split@.
    , srrFailureTag :: Maybe Text
    -- ^ Stable typed failure tag.
    , srrFailureReason :: Maybe Text
    -- ^ Human-readable diagnostic for the failure tag.
    }
    deriving (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

-- ---------------------------------------------------------------------------
-- Handler runner

{- | Service-side runner used by the @amaru-treasury-tx-api@
binary.

The endpoint surface is real in this slice, but the actual
planner/builder integration is intentionally deferred to the
next bisect-safe slice.  Returning a typed placeholder keeps
the HTTP contract structured and makes accidental success
impossible before the build logic is wired.
-}
runBuildSwapRerate
    :: Backend
    -> SwapRerateBuildRequest
    -> IO SwapRerateBuildResponse
runBuildSwapRerate _ SwapRerateBuildRequest{..} = do
    TIO.hPutStrLn
        stderr
        ( "amaru-treasury-tx-api: POST /v1/build/swap-rerate scope="
            <> T.pack (show srrScope)
        )
    pure
        SwapRerateBuildResponse
            { srrCborHex = Nothing
            , srrCborEnvelope = Nothing
            , srrReport = Nothing
            , srrDecision = Nothing
            , srrFailureTag = Just "BuildSwapRerateUnavailable"
            , srrFailureReason =
                Just "swap-rerate build runner is not wired yet"
            }
