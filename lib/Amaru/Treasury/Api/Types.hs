{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE StrictData #-}

{- |
Module      : Amaru.Treasury.Api.Types
Description : Carrier types for the #239 dashboard HTTP API
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

JSON-only carriers consumed by the @amaru-treasury-tx-api@
servant surface declared in 'Amaru.Treasury.Api.Server'. The
build identity and recent transaction manifest preserve the
field-name shapes emitted by @nix/build-identity.nix@ and
@nix/recent-txs.nix@ at build time. New HTTP-owned carriers
define explicit JSON instances so their wire contract is not
tied to Haskell record prefixes.
-}
module Amaru.Treasury.Api.Types
    ( -- * Build identity
      BuildIdentity (..)

      -- * Recent transactions manifest
    , RecentTxManifest (..)
    , RecentTxEntry (..)

      -- * Indexed tx history
    , ScopeHistoryResponse (..)
    , ScopeHistoryEntry (..)

      -- * Errors
    , ApiError (..)
    ) where

import Data.Aeson
    ( FromJSON (..)
    , ToJSON (..)
    , object
    , withObject
    , (.:)
    , (.=)
    )
import Data.Text (Text)
import Data.Time (UTCTime)
import Data.Word (Word64)
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

{- | Response returned by @GET /v1/scope/<scope>/txs@.
It is backed by the local tx-history RocksDB store, not
the baked recent transaction manifest.
-}
data ScopeHistoryResponse = ScopeHistoryResponse
    { shrScope :: ScopeId
    , shrEntries :: [ScopeHistoryEntry]
    }
    deriving stock (Eq, Show)

instance ToJSON ScopeHistoryResponse where
    toJSON r =
        object
            [ "scope" .= shrScope r
            , "entries" .= shrEntries r
            ]

instance FromJSON ScopeHistoryResponse where
    parseJSON =
        withObject "ScopeHistoryResponse" $ \o ->
            ScopeHistoryResponse
                <$> o .: "scope"
                <*> o .: "entries"

-- | One indexed treasury history row.
data ScopeHistoryEntry = ScopeHistoryEntry
    { sheSlot :: Word64
    , sheTxId :: Text
    , sheRole :: Text
    , sheDirection :: Text
    }
    deriving stock (Eq, Show)

instance ToJSON ScopeHistoryEntry where
    toJSON e =
        object
            [ "slot" .= sheSlot e
            , "txid" .= sheTxId e
            , "role" .= sheRole e
            , "direction" .= sheDirection e
            ]

instance FromJSON ScopeHistoryEntry where
    parseJSON =
        withObject "ScopeHistoryEntry" $ \o ->
            ScopeHistoryEntry
                <$> o .: "slot"
                <*> o .: "txid"
                <*> o .: "role"
                <*> o .: "direction"

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
