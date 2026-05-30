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
    , ScopeHistoryQueryResponse (..)
    , ScopeHistoryShaclResponse (..)

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
    -- ^ Absolute chain slot recorded by the tx-history indexer.
    , sheTxId :: Text
    -- ^ Lowercase hex Cardano transaction id.
    , sheRole :: Text
    -- ^ Treasury role label, e.g. @disburse@, @reorganize@, or
    --   @-@ for inbound funding without a treasury redeemer role.
    , sheDirection :: Text
    -- ^ Direction label from the history indexer, currently
    --   @inbound@ or @outbound@.
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

{- | Response returned by a named RDF/SPARQL history query.

The query itself is selected from a fixed server-side catalog; this
carrier only exposes the selected name and its result table.
-}
data ScopeHistoryQueryResponse = ScopeHistoryQueryResponse
    { shqrScope :: ScopeId
    -- ^ Treasury scope whose indexed rows formed the RDF lattice.
    , shqrQuery :: Text
    -- ^ Stable server-side query name, e.g. @asset-flow@ or
    --   @spend-edges@. This is not caller-supplied SPARQL text.
    , shqrColumns :: [Text]
    -- ^ TSV/SPARQL result variable names without the leading @?@.
    , shqrRows :: [[Text]]
    -- ^ SPARQL result cells, one inner list per row, in
    --   'shqrColumns' order.
    }
    deriving stock (Eq, Show)

instance ToJSON ScopeHistoryQueryResponse where
    toJSON r =
        object
            [ "scope" .= shqrScope r
            , "query" .= shqrQuery r
            , "columns" .= shqrColumns r
            , "rows" .= shqrRows r
            ]

instance FromJSON ScopeHistoryQueryResponse where
    parseJSON =
        withObject "ScopeHistoryQueryResponse" $ \o ->
            ScopeHistoryQueryResponse
                <$> o .: "scope"
                <*> o .: "query"
                <*> o .: "columns"
                <*> o .: "rows"

{- | Response returned by a named RDF/SHACL history validation.

The shape set is selected from a fixed server-side catalog; this carrier
does not expose arbitrary SHACL supplied by the caller.
-}
data ScopeHistoryShaclResponse = ScopeHistoryShaclResponse
    { shsrScope :: ScopeId
    -- ^ Treasury scope whose indexed rows formed the RDF lattice.
    , shsrShape :: Text
    -- ^ Stable server-side SHACL shape name, e.g. @history-entry@
    --   or @indexed-tx-body@.
    , shsrConforms :: Bool
    -- ^ True when the SHACL engine found no violation.
    , shsrReport :: Text
    -- ^ Raw SHACL report text. Empty when the selected shape conforms
    --   cleanly.
    }
    deriving stock (Eq, Show)

instance ToJSON ScopeHistoryShaclResponse where
    toJSON r =
        object
            [ "scope" .= shsrScope r
            , "shape" .= shsrShape r
            , "conforms" .= shsrConforms r
            , "report" .= shsrReport r
            ]

instance FromJSON ScopeHistoryShaclResponse where
    parseJSON =
        withObject "ScopeHistoryShaclResponse" $ \o ->
            ScopeHistoryShaclResponse
                <$> o .: "scope"
                <*> o .: "shape"
                <*> o .: "conforms"
                <*> o .: "report"

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
