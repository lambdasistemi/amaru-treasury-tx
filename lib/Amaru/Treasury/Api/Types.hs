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

      -- * Indexed transaction detail
    , TxIdParam (..)
    , txIdParamHex
    , IntrospectRequest (..)
    , IntrospectResponse (..)
    , VerifyWitnessRequest (..)
    , VerifyWitnessResponse (..)
    , AttachRequest (..)
    , AttachResponse (..)
    , TxDetailResponse (..)
    , TxDetailInput (..)
    , TxDetailOutput (..)

      -- * Indexed state reads
    , ScopeUtxosResponse (..)
    , PendingResponse (..)
    , PendingScope (..)
    , RegistryResponse (..)
    , RegistryScope (..)
    , ScriptsResponse (..)
    , ScopeScripts (..)
    , ScriptRefResponse (..)

      -- * Node utility reads
    , TipResponse (..)
    , ParamsResponse (..)
    , SubmitRequest (..)
    , SubmitResponse (..)
    , HealthResponse (..)

      -- * Errors
    , ApiError (..)
    ) where

import Cardano.Node.Client.TxHistoryIndexer.Types
    ( TxId (..)
    )
import Data.Aeson
    ( FromJSON (..)
    , ToJSON (..)
    , object
    , withObject
    , (.:)
    , (.:?)
    , (.=)
    )
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime)
import Data.Word (Word64)
import GHC.Generics (Generic)
import Web.HttpApiData (FromHttpApiData (..))

import Amaru.Treasury.Inspect.SwapOrderProjection
    ( ProjectedSwapOrder
    )
import Amaru.Treasury.Inspect.TreasurySpendProjection
    ( ProjectedTreasurySpend
    )
import Amaru.Treasury.Inspect.Types
    ( PendingSwapOrder
    , TreasuryUtxo
    )
import Amaru.Treasury.Report.Accounting (ValueSummary)
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

-- | Parsed @/v1/tx/<txid>@ path segment.
newtype TxIdParam = TxIdParam
    { unTxIdParam :: TxId
    }
    deriving stock (Eq, Show)

instance FromHttpApiData TxIdParam where
    parseUrlPiece raw =
        case B16.decode (TE.encodeUtf8 raw) of
            Right bytes
                | BS.length bytes == 32 -> Right (TxIdParam (TxId bytes))
                | otherwise ->
                    Left
                        "txid must be a 32-byte transaction id encoded as hex"
            Left err -> Left ("txid must be hex: " <> T.pack err)

-- | Render a parsed path txid back to lowercase hex.
txIdParamHex :: TxIdParam -> Text
txIdParamHex (TxIdParam (TxId bytes)) =
    TE.decodeUtf8 (B16.encode bytes)

-- | Request body accepted by @POST /v1/tx/introspect@.
newtype IntrospectRequest = IntrospectRequest
    { itrCborHex :: Text
    }
    deriving stock (Eq, Show)

instance ToJSON IntrospectRequest where
    toJSON r = object ["cborHex" .= itrCborHex r]

instance FromJSON IntrospectRequest where
    parseJSON =
        withObject "IntrospectRequest" $ \o ->
            IntrospectRequest <$> o .: "cborHex"

-- | Response returned by @POST /v1/tx/introspect@.
data IntrospectResponse = IntrospectResponse
    { irTxid :: Text
    , irRequiredSigners :: [Text]
    , irInvalidHereafter :: Maybe Word64
    , irScope :: Maybe Text
    }
    deriving stock (Eq, Show)

instance ToJSON IntrospectResponse where
    toJSON r =
        object
            [ "txid" .= irTxid r
            , "requiredSigners" .= irRequiredSigners r
            , "invalidHereafter" .= irInvalidHereafter r
            , "scope" .= irScope r
            ]

instance FromJSON IntrospectResponse where
    parseJSON =
        withObject "IntrospectResponse" $ \o ->
            IntrospectResponse
                <$> o .: "txid"
                <*> o .: "requiredSigners"
                <*> o .:? "invalidHereafter"
                <*> o .:? "scope"

-- | Request body accepted by @POST /v1/verify-witness@.
data VerifyWitnessRequest = VerifyWitnessRequest
    { vwrUnsignedTx :: Text
    , vwrWitness :: Text
    }
    deriving stock (Eq, Show)

instance ToJSON VerifyWitnessRequest where
    toJSON r =
        object
            [ "unsignedTx" .= vwrUnsignedTx r
            , "witness" .= vwrWitness r
            ]

instance FromJSON VerifyWitnessRequest where
    parseJSON =
        withObject "VerifyWitnessRequest" $ \o ->
            VerifyWitnessRequest
                <$> o .: "unsignedTx"
                <*> o .: "witness"

{- | Response returned by @POST /v1/verify-witness@.

The type is intentionally pure data: all negative verification outcomes
are represented as @ok = false@ rather than exceptions.
-}
data VerifyWitnessResponse = VerifyWitnessResponse
    { vwrOk :: Bool
    , vwrSignerKeyHash :: Maybe Text
    , vwrReason :: Maybe Text
    }
    deriving stock (Eq, Show)

instance ToJSON VerifyWitnessResponse where
    toJSON r =
        object
            [ "ok" .= vwrOk r
            , "signerKeyHash" .= vwrSignerKeyHash r
            , "reason" .= vwrReason r
            ]

instance FromJSON VerifyWitnessResponse where
    parseJSON =
        withObject "VerifyWitnessResponse" $ \o ->
            VerifyWitnessResponse
                <$> o .: "ok"
                <*> o .: "signerKeyHash"
                <*> o .: "reason"

-- | Request body accepted by @POST /v1/attach@.
data AttachRequest = AttachRequest
    { arUnsignedTx :: Text
    , arWitnesses :: [Text]
    }
    deriving stock (Eq, Show)

instance ToJSON AttachRequest where
    toJSON r =
        object
            [ "unsignedTx" .= arUnsignedTx r
            , "witnesses" .= arWitnesses r
            ]

instance FromJSON AttachRequest where
    parseJSON =
        withObject "AttachRequest" $ \o ->
            AttachRequest
                <$> o .: "unsignedTx"
                <*> o .: "witnesses"

-- | Response returned by @POST /v1/attach@.
newtype AttachResponse = AttachResponse
    { arCborHex :: Text
    }
    deriving stock (Eq, Show)

instance ToJSON AttachResponse where
    toJSON r = object ["cborHex" .= arCborHex r]

instance FromJSON AttachResponse where
    parseJSON =
        withObject "AttachResponse" $ \o ->
            AttachResponse <$> o .: "cborHex"

-- | Response returned by @GET /v1/tx/<txid>@.
data TxDetailResponse = TxDetailResponse
    { tdrSlot :: Word64
    , tdrTxId :: Text
    , tdrScope :: Text
    , tdrRole :: Text
    , tdrDirection :: Text
    , tdrBlockHash :: Maybe Text
    , tdrFee :: Maybe Word64
    , tdrRequiredSigners :: [Text]
    , tdrRedeemer :: Maybe Text
    , tdrProjectedRedeemers :: [ProjectedTreasurySpend]
    , tdrInputs :: [TxDetailInput]
    , tdrOutputs :: [TxDetailOutput]
    , tdrLines :: [Text]
    }
    deriving stock (Eq, Show)

instance ToJSON TxDetailResponse where
    toJSON r =
        object
            [ "slot" .= tdrSlot r
            , "txid" .= tdrTxId r
            , "scope" .= tdrScope r
            , "role" .= tdrRole r
            , "direction" .= tdrDirection r
            , "blockHash" .= tdrBlockHash r
            , "fee" .= tdrFee r
            , "requiredSigners" .= tdrRequiredSigners r
            , "redeemer" .= tdrRedeemer r
            , "projectedRedeemers" .= tdrProjectedRedeemers r
            , "inputs" .= tdrInputs r
            , "outputs" .= tdrOutputs r
            , "lines" .= tdrLines r
            ]

instance FromJSON TxDetailResponse where
    parseJSON =
        withObject "TxDetailResponse" $ \o ->
            TxDetailResponse
                <$> o .: "slot"
                <*> o .: "txid"
                <*> o .: "scope"
                <*> o .: "role"
                <*> o .: "direction"
                <*> o .:? "blockHash"
                <*> o .:? "fee"
                <*> o .: "requiredSigners"
                <*> o .:? "redeemer"
                <*> o .: "projectedRedeemers"
                <*> o .: "inputs"
                <*> o .: "outputs"
                <*> o .: "lines"

{- | One indexed input in a transaction detail response.

@scope@/@role@ name the owning treasury entity when the input's
source UTxO was resolved from the indexed UTxO state and its address
is a known on-chain identity (resolved from verified metadata,
mirroring the @atx:TreasuryEntity@ vocabulary the outputs use); they
are 'Nothing' for a resolved input outside the treasury, and along
with @value@ all 'Nothing' when the indexer no longer holds the spent
source UTxO. @value@, when present, is the structured ledger value of
the produced output the @txIn@ outref points at. @resolved@ is the
explicit marker: 'True' when the source UTxO was found and labelled,
'False' when it is spent and pruned from the indexed state.
-}
data TxDetailInput = TxDetailInput
    { tdiTxIn :: Text
    , tdiScope :: Maybe Text
    , tdiRole :: Maybe Text
    , tdiValue :: Maybe ValueSummary
    , tdiResolved :: Bool
    }
    deriving stock (Eq, Show)

instance ToJSON TxDetailInput where
    toJSON i =
        object
            [ "txIn" .= tdiTxIn i
            , "scope" .= tdiScope i
            , "role" .= tdiRole i
            , "value" .= tdiValue i
            , "resolved" .= tdiResolved i
            ]

instance FromJSON TxDetailInput where
    parseJSON =
        withObject "TxDetailInput" $ \o ->
            TxDetailInput
                <$> o .: "txIn"
                <*> o .:? "scope"
                <*> o .:? "role"
                <*> o .:? "value"
                <*> o .: "resolved"

{- | One indexed output in a transaction detail response.

@scope@/@role@ name the owning treasury entity when the output
address is a known on-chain identity (resolved from verified
metadata, mirroring the RDF @atx:TreasuryEntity@ vocabulary); both
are 'Nothing' for an address outside the treasury. @value@ is the
structured ledger value (lovelace + native assets), surfaced as a
nested object rather than a stringified blob so clients can render
it ADA-denominated.
-}
data TxDetailOutput = TxDetailOutput
    { tdoIndex :: Int
    , tdoAddress :: Text
    , tdoScope :: Maybe Text
    , tdoRole :: Maybe Text
    , tdoValue :: ValueSummary
    , tdoDatum :: Maybe Text
    , tdoProjectedDatum :: Maybe ProjectedSwapOrder
    -- ^ Decoded SundaeSwap order datum (recipient, min-received,
    -- scooper fee) when the output carries a swap-order inline datum;
    -- 'Nothing' otherwise.
    }
    deriving stock (Eq, Show)

instance ToJSON TxDetailOutput where
    toJSON o =
        object
            [ "index" .= tdoIndex o
            , "address" .= tdoAddress o
            , "scope" .= tdoScope o
            , "role" .= tdoRole o
            , "value" .= tdoValue o
            , "datum" .= tdoDatum o
            , "projectedDatum" .= tdoProjectedDatum o
            ]

instance FromJSON TxDetailOutput where
    parseJSON =
        withObject "TxDetailOutput" $ \o ->
            TxDetailOutput
                <$> o .: "index"
                <*> o .: "address"
                <*> o .:? "scope"
                <*> o .:? "role"
                <*> o .: "value"
                <*> o .:? "datum"
                <*> o .:? "projectedDatum"

-- | Response returned by @GET /v1/scope/<scope>/utxos@.
data ScopeUtxosResponse = ScopeUtxosResponse
    { surScope :: ScopeId
    , surEntries :: [TreasuryUtxo]
    }
    deriving stock (Eq, Show)

instance ToJSON ScopeUtxosResponse where
    toJSON r =
        object
            [ "scope" .= surScope r
            , "entries" .= surEntries r
            ]

-- | Response returned by @GET /v1/pending@.
data PendingResponse = PendingResponse
    { prScope :: Maybe ScopeId
    , prEntries :: [PendingScope]
    }
    deriving stock (Eq, Show)

instance ToJSON PendingResponse where
    toJSON r =
        object
            [ "scope" .= prScope r
            , "entries" .= prEntries r
            ]

-- | Pending orders grouped by treasury scope.
data PendingScope = PendingScope
    { psScope :: ScopeId
    , psOrders :: [PendingSwapOrder]
    }
    deriving stock (Eq, Show)

instance ToJSON PendingScope where
    toJSON s =
        object
            [ "scope" .= psScope s
            , "orders" .= psOrders s
            ]

-- | Deployment registry metadata for web clients.
data RegistryResponse = RegistryResponse
    { rrScopeOwners :: Text
    , rrScopes :: [RegistryScope]
    }
    deriving stock (Eq, Show)

instance ToJSON RegistryResponse where
    toJSON r =
        object
            [ "scopeOwners" .= rrScopeOwners r
            , "scopes" .= rrScopes r
            ]

instance FromJSON RegistryResponse where
    parseJSON =
        withObject "RegistryResponse" $ \o ->
            RegistryResponse
                <$> o .: "scopeOwners"
                <*> o .: "scopes"

-- | One scope's registry metadata.
data RegistryScope = RegistryScope
    { rsScope :: ScopeId
    , rsOwner :: Maybe Text
    , rsBudget :: Maybe Integer
    , rsAddress :: Text
    }
    deriving stock (Eq, Show)

instance ToJSON RegistryScope where
    toJSON s =
        object
            [ "scope" .= rsScope s
            , "owner" .= rsOwner s
            , "budget" .= rsBudget s
            , "address" .= rsAddress s
            ]

instance FromJSON RegistryScope where
    parseJSON =
        withObject "RegistryScope" $ \o ->
            RegistryScope
                <$> o .: "scope"
                <*> o .:? "owner"
                <*> o .:? "budget"
                <*> o .: "address"

-- | Deployment script metadata for web clients.
newtype ScriptsResponse = ScriptsResponse
    { srScopes :: [ScopeScripts]
    }
    deriving stock (Eq, Show)

instance ToJSON ScriptsResponse where
    toJSON r =
        object ["scopes" .= srScopes r]

instance FromJSON ScriptsResponse where
    parseJSON =
        withObject "ScriptsResponse" $ \o ->
            ScriptsResponse <$> o .: "scopes"

-- | Reference scripts published for one scope.
data ScopeScripts = ScopeScripts
    { ssrScope :: ScopeId
    , ssrTreasury :: ScriptRefResponse
    , ssrPermissions :: ScriptRefResponse
    , ssrRegistry :: ScriptRefResponse
    }
    deriving stock (Eq, Show)

instance ToJSON ScopeScripts where
    toJSON s =
        object
            [ "scope" .= ssrScope s
            , "treasury" .= ssrTreasury s
            , "permissions" .= ssrPermissions s
            , "registry" .= ssrRegistry s
            ]

instance FromJSON ScopeScripts where
    parseJSON =
        withObject "ScopeScripts" $ \o ->
            ScopeScripts
                <$> o .: "scope"
                <*> o .: "treasury"
                <*> o .: "permissions"
                <*> o .: "registry"

-- | One script reference from deployment metadata.
data ScriptRefResponse = ScriptRefResponse
    { srrHash :: Text
    , srrDeployedAt :: Text
    }
    deriving stock (Eq, Show)

instance ToJSON ScriptRefResponse where
    toJSON r =
        object
            [ "hash" .= srrHash r
            , "deployedAt" .= srrDeployedAt r
            ]

instance FromJSON ScriptRefResponse where
    parseJSON =
        withObject "ScriptRefResponse" $ \o ->
            ScriptRefResponse
                <$> o .: "hash"
                <*> o .: "deployedAt"

-- | Response returned by @GET /v1/tip@.
newtype TipResponse = TipResponse
    { trSlot :: Word64
    }
    deriving stock (Eq, Show)

instance ToJSON TipResponse where
    toJSON r = object ["slot" .= trSlot r]

instance FromJSON TipResponse where
    parseJSON =
        withObject "TipResponse" $ \o ->
            TipResponse <$> o .: "slot"

-- | Response returned by @GET /v1/params@.
data ParamsResponse = ParamsResponse
    { parEra :: Text
    , parSummary :: Text
    }
    deriving stock (Eq, Show)

instance ToJSON ParamsResponse where
    toJSON r =
        object
            [ "era" .= parEra r
            , "summary" .= parSummary r
            ]

instance FromJSON ParamsResponse where
    parseJSON =
        withObject "ParamsResponse" $ \o ->
            ParamsResponse
                <$> o .: "era"
                <*> o .: "summary"

-- | Request body accepted by @POST /v1/submit@.
newtype SubmitRequest = SubmitRequest
    { srCborHex :: Text
    }
    deriving stock (Eq, Show)

instance ToJSON SubmitRequest where
    toJSON r = object ["cborHex" .= srCborHex r]

instance FromJSON SubmitRequest where
    parseJSON =
        withObject "SubmitRequest" $ \o ->
            SubmitRequest <$> o .: "cborHex"

-- | Response returned by @POST /v1/submit@.
newtype SubmitResponse = SubmitResponse
    { subTxid :: Text
    }
    deriving stock (Eq, Show)

instance ToJSON SubmitResponse where
    toJSON r = object ["txid" .= subTxid r]

instance FromJSON SubmitResponse where
    parseJSON =
        withObject "SubmitResponse" $ \o ->
            SubmitResponse <$> o .: "txid"

-- | Response returned by @GET /v1/health@.
data HealthResponse = HealthResponse
    { hrStatus :: Text
    , hrProcessedSlot :: Word64
    , hrTipSlot :: Word64
    , hrLagSlots :: Word64
    , hrThresholdSlots :: Word64
    , hrUpdatedAt :: UTCTime
    }
    deriving stock (Eq, Show)

instance ToJSON HealthResponse where
    toJSON r =
        object
            [ "status" .= hrStatus r
            , "processedSlot" .= hrProcessedSlot r
            , "tipSlot" .= hrTipSlot r
            , "lagSlots" .= hrLagSlots r
            , "thresholdSlots" .= hrThresholdSlots r
            , "updatedAt" .= hrUpdatedAt r
            ]

instance FromJSON HealthResponse where
    parseJSON =
        withObject "HealthResponse" $ \o ->
            HealthResponse
                <$> o .: "status"
                <*> o .: "processedSlot"
                <*> o .: "tipSlot"
                <*> o .: "lagSlots"
                <*> o .: "thresholdSlots"
                <*> o .: "updatedAt"

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
