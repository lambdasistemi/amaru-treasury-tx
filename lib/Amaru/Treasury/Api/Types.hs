{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

{- |
Module      : Amaru.Treasury.Api.Types
Description : Carrier types for the #239 dashboard HTTP API
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

JSON-only carriers consumed by the @amaru-treasury-tx-api@
servant surface declared in
'Amaru.Treasury.Api.Server'. JSON shapes are derived from the
record field names verbatim via @Generic@ — the same wire
contract @nix/build-identity.nix@ and @nix/recent-txs.nix@
emit at build time.
-}
module Amaru.Treasury.Api.Types
    ( -- * Build identity
      BuildIdentity (..)

      -- * Recent transactions manifest
    , RecentTxManifest (..)
    , RecentTxEntry (..)

      -- * Errors
    , ApiError (..)
    ) where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import Data.Time (UTCTime)
import GHC.Generics (Generic)

import Amaru.Treasury.Scope (ScopeId)

{- | Payload of @GET /v1/version@. Constructed entirely at
image-build time by @nix/build-identity.nix@; the server
reads the embedded bytes verbatim — see slice T008.
-}
data BuildIdentity = BuildIdentity
    { biBuildTime :: UTCTime
    -- ^ ISO-8601 timestamp from the flake's
    --   @self.lastModified@; reproducible.
    , biGitCommit :: Text
    -- ^ Short sha of the amaru-treasury-tx commit used.
    , biMetadataSha256 :: Text
    , biMetadataSource :: Text
    -- ^ @github:pragma-org/amaru-treasury/\<rev\>@.
    , biRecentTxsCount :: Int
    }
    deriving stock (Eq, Show, Generic)
    deriving anyclass (ToJSON, FromJSON)

{- | The envelope returned by @GET /v1/recent-txs@. Holds up to
ten entries; ordering is newest-first.
-}
newtype RecentTxManifest = RecentTxManifest
    { rtmEntries :: [RecentTxEntry]
    }
    deriving stock (Eq, Show, Generic)
    deriving anyclass (ToJSON, FromJSON)

-- | One row of 'RecentTxManifest'.
data RecentTxEntry = RecentTxEntry
    { rteScope :: ScopeId
    , rteTxid :: Text
    , rteSubmittedAt :: UTCTime
    , rteCardanoscanUrl :: Text
    }
    deriving stock (Eq, Show, Generic)
    deriving anyclass (ToJSON, FromJSON)

{- | Uniform 4xx body: human-readable message plus an optional
field name that points the operator at the source of the
failure. Used by every handler in the slice for input-shape
errors (e.g. unknown @?scope=@).
-}
data ApiError = ApiError
    { aeMessage :: Text
    , aeField :: Maybe Text
    }
    deriving stock (Eq, Show, Generic)
    deriving anyclass (ToJSON, FromJSON)
