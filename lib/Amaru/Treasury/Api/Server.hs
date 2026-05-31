{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeOperators #-}

{- |
Module      : Amaru.Treasury.Api.Server
Description : Servant API type + handler wiring for the #239 dashboard
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Single source of truth for the HTTP surface served by
@amaru-treasury-tx-api@:

  * @GET \/v1\/treasury-inspect?scope=\<name\>@ — live
    'InspectReport' for one of the registered scopes.
  * @GET \/v1\/recent-txs@ — read-only 'RecentTxManifest'
    baked into the image at build time.
  * @GET \/v1\/version@ — read-only 'BuildIdentity' carrying
    the deployed image's pinned metadata sha + git sha.
  * @GET \/v1\/scope\/\<scope\>\/txs@ — indexed treasury
    history rows from the embedded tx-history store.
  * @GET \/v1\/scope\/\<scope\>\/txs\/query?name=\<query\>@
    — named RDF/SPARQL history analysis.
  * @GET \/v1\/scope\/\<scope\>\/txs\/shacl?name=\<shape\>@
    — named RDF/SHACL history validation.
  * Anything else — static assets served by the 'rawHandler'
    supplied by the caller (typically the PureScript bundle).
-}
module Amaru.Treasury.Api.Server
    ( -- * API
      DashboardAPI
    , dashboardAPI
    , JsonAPI
    , jsonAPI

      -- * Content types
    , InspectJSON

      -- * Server
    , Handlers (..)
    , BuildHandlers (..)
    , mkServer
    , mkApplication

      -- * Indexer-served handler (#242)
    , mkInspectHandler
    , withIndexerProvider
    , mkBuildProvider
    , mkBuildHandlers
    ) where

import Cardano.Ledger.Address (Addr)
import Cardano.Node.Client.Provider
    ( Provider (..)
    , QueryHandleBackend (..)
    , mkQueryHandle
    )
import Cardano.Node.Client.Provider qualified as Provider
import Cardano.Node.Client.UTxOIndexer.Provider qualified as IndexedProvider
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (throwE)
import Data.Proxy (Proxy (..))
import Data.Tagged (Tagged)
import Data.Text (Text)
import Data.Word (Word64)
import Database.KV.Transaction (RunTransaction (..))
import Network.HTTP.Media ((//))
import Network.Wai (Application)
import Servant
    ( Server
    , err404
    , serve
    , (:<|>) (..)
    )
import Servant.API
    ( Accept (..)
    , Capture
    , Get
    , JSON
    , MimeRender (..)
    , Post
    , QueryParam
    , QueryParam'
    , Raw
    , ReqBody
    , Required
    , Strict
    , type (:>)
    )
import Servant.Server.Internal.Handler (Handler (..))

import Amaru.Treasury.Api.BuildDisburse
    ( DisburseBuildRequest
    , DisburseBuildResponse
    )
import Amaru.Treasury.Api.BuildReorganize
    ( ReorganizeBuildRequest
    , ReorganizeBuildResponse
    )
import Amaru.Treasury.Api.BuildSwap
    ( SwapBuildRequest
    , SwapBuildResponse
    )
import Amaru.Treasury.Api.Indexer
    ( ApiIndexer (..)
    )
import Amaru.Treasury.Api.State
    ( ScopeUtxoFilter (..)
    )
import Amaru.Treasury.Api.Types
    ( BuildIdentity
    , HealthResponse
    , ParamsResponse
    , PendingResponse
    , RecentTxManifest
    , RegistryResponse
    , ScopeHistoryQueryResponse
    , ScopeHistoryResponse
    , ScopeHistoryShaclResponse
    , ScopeUtxosResponse
    , ScriptsResponse
    , SubmitRequest
    , SubmitResponse
    , TipResponse
    , TxDetailResponse
    , TxIdParam
    )
import Amaru.Treasury.Cli.TreasuryInspect (runInspectFromBackend)
import Amaru.Treasury.History.Sparql
    ( HistoryFilter (..)
    , HistoryQueryName
    , HistoryShapeName
    )
import Amaru.Treasury.Inspect.Render (encodeReport)
import Amaru.Treasury.Inspect.Types
    ( DeploymentAnchor
    , InspectReport
    , ScopeSection
    )
import Amaru.Treasury.Metadata (TreasuryMetadata)
import Amaru.Treasury.Scope (ScopeId)

{- | A servant content type that emits an 'InspectReport' via
the project's existing 'encodeReport' (4-space indent,
alphabetical keys, trailing newline). Used for the
@\/v1\/treasury-inspect@ endpoint so the bytes returned over
HTTP are byte-identical to @treasury-inspect --format json@
(SC-002).
-}
data InspectJSON

instance Accept InspectJSON where
    contentType _ = "application" // "json"

instance MimeRender InspectJSON InspectReport where
    mimeRender _ = encodeReport

{- | The JSON-only surface of the API. Kept separate from
'DashboardAPI' so handler tests can drive the JSON endpoints
without dragging the static-asset layer in.
-}
type JsonAPI =
    "v1"
        :> ( "treasury-inspect"
                :> QueryParam' '[Required, Strict] "scope" ScopeId
                :> Get '[InspectJSON] InspectReport
                :<|> "recent-txs"
                    :> Get '[JSON] RecentTxManifest
                :<|> "version"
                    :> Get '[JSON] BuildIdentity
                :<|> "tx"
                    :> Capture "txid" TxIdParam
                    :> Get '[JSON] TxDetailResponse
                :<|> "registry"
                    :> Get '[JSON] RegistryResponse
                :<|> "scripts"
                    :> Get '[JSON] ScriptsResponse
                :<|> "pending"
                    :> QueryParam "scope" ScopeId
                    :> Get '[JSON] PendingResponse
                :<|> "tip"
                    :> Get '[JSON] TipResponse
                :<|> "params"
                    :> Get '[JSON] ParamsResponse
                :<|> "submit"
                    :> ReqBody '[JSON] SubmitRequest
                    :> Post '[JSON] SubmitResponse
                :<|> "health"
                    :> Get '[JSON] HealthResponse
                :<|> "scope"
                    :> Capture "scope" ScopeId
                    :> "state"
                    :> Get '[JSON] ScopeSection
                :<|> "scope"
                    :> Capture "scope" ScopeId
                    :> "utxos"
                    :> QueryParam "asset" Text
                    :> QueryParam "min_lovelace" Integer
                    :> QueryParam "limit" Int
                    :> Get '[JSON] ScopeUtxosResponse
                :<|> "scope"
                    :> Capture "scope" ScopeId
                    :> "txs"
                    :> QueryParam "role" Text
                    :> QueryParam "asset" Text
                    :> QueryParam "direction" Text
                    :> QueryParam "since" Word64
                    :> QueryParam "until" Word64
                    :> QueryParam "limit" Int
                    :> Get '[JSON] ScopeHistoryResponse
                :<|> "scope"
                    :> Capture "scope" ScopeId
                    :> "txs"
                    :> "query"
                    :> QueryParam' '[Required, Strict] "name" HistoryQueryName
                    :> Get '[JSON] ScopeHistoryQueryResponse
                :<|> "scope"
                    :> Capture "scope" ScopeId
                    :> "txs"
                    :> "shacl"
                    :> QueryParam' '[Required, Strict] "name" HistoryShapeName
                    :> Get '[JSON] ScopeHistoryShaclResponse
                :<|> "build"
                    :> "swap"
                    :> ReqBody '[JSON] SwapBuildRequest
                    :> Post '[JSON] SwapBuildResponse
                :<|> "build"
                    :> "disburse"
                    :> ReqBody '[JSON] DisburseBuildRequest
                    :> Post '[JSON] DisburseBuildResponse
                :<|> "build"
                    :> "reorganize"
                    :> ReqBody '[JSON] ReorganizeBuildRequest
                    :> Post '[JSON] ReorganizeBuildResponse
           )

-- | Witness for 'JsonAPI'.
jsonAPI :: Proxy JsonAPI
jsonAPI = Proxy

{- | The full surface: JSON endpoints first, then a catch-all
'Raw' route that serves the PureScript bundle directory at
@\/@. Path-precedence in servant means the JSON endpoints
always match before the @Raw@ fallback.
-}
type DashboardAPI =
    JsonAPI :<|> Raw

-- | Witness for 'DashboardAPI'.
dashboardAPI :: Proxy DashboardAPI
dashboardAPI = Proxy

{- | The runtime dependencies the API needs.

The InspectReport is produced behind 'hInspectReport' so the
caller chooses whether to back it by a live 'Provider IO' (in
the binary) or by a fixed value (in tests).

The 'BuildIdentity' and 'RecentTxManifest' are read-only and
embedded at image-build time, so they live in the record by
value rather than behind an action.
-}
data Handlers = Handlers
    { hInspectReport :: ScopeId -> IO InspectReport
    , hRecentTxs :: RecentTxManifest
    , hBuildIdentity :: BuildIdentity
    , hTxDetail :: TxIdParam -> IO (Maybe TxDetailResponse)
    , hRegistry :: IO RegistryResponse
    , hScripts :: IO ScriptsResponse
    , hPending :: Maybe ScopeId -> IO PendingResponse
    , hTip :: IO TipResponse
    , hParams :: IO ParamsResponse
    , hSubmit :: SubmitRequest -> IO SubmitResponse
    , hHealth :: IO HealthResponse
    , hScopeState :: ScopeId -> IO ScopeSection
    , hScopeUtxos :: ScopeId -> ScopeUtxoFilter -> IO ScopeUtxosResponse
    , hScopeHistory :: ScopeId -> HistoryFilter -> IO ScopeHistoryResponse
    , hScopeHistoryQuery
        :: ScopeId
        -> HistoryQueryName
        -> IO ScopeHistoryQueryResponse
    , hScopeHistoryShacl
        :: ScopeId
        -> HistoryShapeName
        -> IO ScopeHistoryShaclResponse
    , hBuildSwap :: SwapBuildRequest -> IO SwapBuildResponse
    -- ^ Build a swap intent from a wire-shape request.  The
    --   binary's implementation calls
    --   'Amaru.Treasury.Wizard.Swap.buildSwapIntent' against
    --   the server's long-lived 'Backend'; tests pass a fixed
    --   value or a stub.
    , hBuildDisburse
        :: DisburseBuildRequest
        -> IO DisburseBuildResponse
    -- ^ Build a disburse intent + tx from a wire-shape
    --   request (#277).  Same shape as 'hBuildSwap'; the
    --   binary's implementation calls
    --   'Amaru.Treasury.Wizard.Disburse.buildDisburseIntent'
    --   then 'buildDisburseTx' against the server's
    --   long-lived 'Backend'.
    , hBuildReorganize
        :: ReorganizeBuildRequest
        -> IO ReorganizeBuildResponse
    -- ^ Build a reorganize intent + tx from a wire-shape
    --   request (#280).  Same shape as 'hBuildDisburse';
    --   the binary's implementation calls
    --   'Amaru.Treasury.Wizard.Reorganize.buildReorganizeIntent'
    --   then 'buildReorganizeTx' against the server's
    --   long-lived 'Backend'.
    , hRawHandler :: Tagged Handler Application
    -- ^ The static-asset fallback for @\/@. In the binary
    --   this is a 'Servant.Server.StaticFiles'
    --   directory-server; in tests it is a tiny 404 stub.
    }

-- | The three API build endpoints after provider wiring.
data BuildHandlers = BuildHandlers
    { bhBuildSwap :: SwapBuildRequest -> IO SwapBuildResponse
    , bhBuildDisburse
        :: DisburseBuildRequest
        -> IO DisburseBuildResponse
    , bhBuildReorganize
        :: ReorganizeBuildRequest
        -> IO ReorganizeBuildResponse
    }

{- | Construct the three build handlers from one shared
provider.
-}
mkBuildHandlers
    :: ApiIndexer cf op
    -> Provider IO
    -> (Provider IO -> SwapBuildRequest -> IO SwapBuildResponse)
    -> (Provider IO -> DisburseBuildRequest -> IO DisburseBuildResponse)
    -> (Provider IO -> ReorganizeBuildRequest -> IO ReorganizeBuildResponse)
    -> BuildHandlers
mkBuildHandlers apiIdx realProvider buildSwap buildDisburse buildReorganize =
    BuildHandlers
        { bhBuildSwap = buildSwap buildProvider
        , bhBuildDisburse = buildDisburse buildProvider
        , bhBuildReorganize = buildReorganize buildProvider
        }
  where
    buildProvider = mkBuildProvider apiIdx realProvider

-- | Build the servant 'Server' from the 'Handlers' record.
mkServer :: Handlers -> Server DashboardAPI
mkServer Handlers{..} =
    ( inspectH
        :<|> pure hRecentTxs
        :<|> pure hBuildIdentity
        :<|> txDetailH
        :<|> liftIO hRegistry
        :<|> liftIO hScripts
        :<|> pendingH
        :<|> liftIO hTip
        :<|> liftIO hParams
        :<|> submitH
        :<|> liftIO hHealth
        :<|> scopeStateH
        :<|> scopeUtxosH
        :<|> scopeHistoryH
        :<|> scopeHistoryQueryH
        :<|> scopeHistoryShaclH
        :<|> buildSwapH
        :<|> buildDisburseH
        :<|> buildReorganizeH
    )
        :<|> hRawHandler
  where
    inspectH :: ScopeId -> Handler InspectReport
    inspectH scope = liftIO (hInspectReport scope)

    txDetailH :: TxIdParam -> Handler TxDetailResponse
    txDetailH txid = do
        mDetail <- liftIO (hTxDetail txid)
        case mDetail of
            Just detail -> pure detail
            Nothing -> Handler (throwE err404)

    pendingH :: Maybe ScopeId -> Handler PendingResponse
    pendingH scope = liftIO (hPending scope)

    submitH :: SubmitRequest -> Handler SubmitResponse
    submitH req = liftIO (hSubmit req)

    scopeStateH :: ScopeId -> Handler ScopeSection
    scopeStateH scope = liftIO (hScopeState scope)

    scopeUtxosH
        :: ScopeId
        -> Maybe Text
        -> Maybe Integer
        -> Maybe Int
        -> Handler ScopeUtxosResponse
    scopeUtxosH scope asset minLovelace limitRows =
        liftIO $
            hScopeUtxos
                scope
                ScopeUtxoFilter
                    { sufAsset = asset
                    , sufMinLovelace = minLovelace
                    , sufLimit = limitRows
                    }

    scopeHistoryH
        :: ScopeId
        -> Maybe Text
        -> Maybe Text
        -> Maybe Text
        -> Maybe Word64
        -> Maybe Word64
        -> Maybe Int
        -> Handler ScopeHistoryResponse
    scopeHistoryH scope role asset direction since untilSlot limitRows =
        liftIO $
            hScopeHistory
                scope
                HistoryFilter
                    { hfRole = role
                    , hfAsset = asset
                    , hfDirection = direction
                    , hfSince = since
                    , hfUntil = untilSlot
                    , hfLimit = limitRows
                    }

    scopeHistoryQueryH
        :: ScopeId -> HistoryQueryName -> Handler ScopeHistoryQueryResponse
    scopeHistoryQueryH scope queryName =
        liftIO (hScopeHistoryQuery scope queryName)

    scopeHistoryShaclH
        :: ScopeId -> HistoryShapeName -> Handler ScopeHistoryShaclResponse
    scopeHistoryShaclH scope shapeName =
        liftIO (hScopeHistoryShacl scope shapeName)

    buildSwapH :: SwapBuildRequest -> Handler SwapBuildResponse
    buildSwapH req = liftIO (hBuildSwap req)

    buildDisburseH
        :: DisburseBuildRequest -> Handler DisburseBuildResponse
    buildDisburseH req = liftIO (hBuildDisburse req)

    buildReorganizeH
        :: ReorganizeBuildRequest
        -> Handler ReorganizeBuildResponse
    buildReorganizeH req = liftIO (hBuildReorganize req)

{- | Bake the 'Handlers' into a WAI 'Application' ready to be
run by warp.
-}
mkApplication :: Handlers -> Application
mkApplication = serve dashboardAPI . mkServer

-- ---------------------------------------------------------------------------
-- Indexer-served inspect handler (#242)

{- | Build the @\/v1\/treasury-inspect@ handler closure that
the API container uses post-#242. The handler reads
treasury / swap-order UTxOs from the embedded indexer (via
the typed indexer provider) instead of from the production node, and
sources only the @chain_tip@ field from the existing
'Provider IO' session (via the unchanged 'nowTip' field —
FR-005).

Implementation strategy: rather than touch the existing
'runInspectFromBackend' (out of #242 Slice 2's owned set), we
construct a thin **synthetic** 'Provider' that:

* delegates 'nowTip' to the caller's real provider,
* routes address UTxO scans through the in-process indexer
  via 'queryUTxOs',
* routes exact input lookup through the same indexer via
  'queryUTxOByTxIn',
* keeps the live provider for non-UTxO ledger data such as
  tip, protocol parameters, evaluation, rewards, votes, and
  governance queries.

The rest of the 'Provider' fields are inherited from the
real provider; they aren't touched by
'runInspectFromBackend''s read path, so this is harmless.
-}
mkInspectHandler
    :: ApiIndexer cf op
    -> Provider IO
    -> TreasuryMetadata
    -> DeploymentAnchor
    -> Addr
    -- ^ swap-order address
    -> ScopeId
    -> Handler InspectReport
mkInspectHandler apiIdx realProvider metadata anchor swapAddr scope =
    liftIO $
        runInspectFromBackend
            metadata
            anchor
            swapAddr
            (Just scope)
            (indexerProvider apiIdx realProvider)

{- | Build the provider used by @POST /v1/build/*@
handlers.
-}
mkBuildProvider :: ApiIndexer cf op -> Provider IO -> Provider IO
mkBuildProvider = indexerProvider

{- | Run an action with a legacy 'Provider IO' whose UTxO
queries are backed by the embedded indexer.

This is the transitional adapter for the existing ATX
wizard/build code. It keeps the live provider for non-UTxO ledger
queries, but both direct UTxO reads and acquired-handle UTxO reads
go through the indexer transaction runner.
-}
withIndexerProvider
    :: ApiIndexer cf op
    -> Provider IO
    -> (Provider IO -> IO a)
    -> IO a
withIndexerProvider apiIdx realProvider action =
    action (indexerProvider apiIdx realProvider)

{- | Build the synthetic 'Provider' described in
'mkInspectHandler''s Haddock: real provider for 'nowTip',
indexer-backed 'queryUTxOs' / 'queryUTxOByTxIn', and live
provider delegation for non-address ledger data.
-}
indexerProvider :: ApiIndexer cf op -> Provider IO -> Provider IO
indexerProvider apiIdx realProvider =
    realProvider
        { withAcquired = \callback ->
            Provider.withAcquired realProvider $ \handle ->
                callback $
                    mkQueryHandle
                        QueryHandleBackend
                            { backendQueryUTxOs = queryIndexedUTxOs
                            , backendQueryUTxOsAt = queryIndexedUTxOsAt
                            , backendQueryUTxOByTxIn =
                                queryIndexedUTxOByTxIn
                            , backendQueryProtocolParams =
                                Provider.queryProtocolParamsH handle
                            , backendQueryLedgerSnapshot =
                                Provider.queryLedgerSnapshotH handle
                            , backendQueryStakeRewards =
                                Provider.queryStakeRewardsH handle
                            , backendQueryRewardAccounts =
                                Provider.queryRewardAccountsH handle
                            , backendQueryVoteDelegatees =
                                Provider.queryVoteDelegateesH handle
                            , backendQueryTreasury =
                                Provider.queryTreasuryH handle
                            , backendQueryGovernanceState =
                                Provider.queryGovernanceStateH handle
                            , backendEvaluateTx =
                                Provider.evaluateTxH handle
                            , backendPosixMsToSlot =
                                Provider.posixMsToSlotH handle
                            , backendPosixMsCeilSlot =
                                Provider.posixMsCeilSlotH handle
                            }
        , queryUTxOs = queryIndexedUTxOs
        , queryUTxOByTxIn = queryIndexedUTxOByTxIn
        }
  where
    RunTransaction{runTransaction} = aiRunner apiIdx
    indexer = IndexedProvider.indexerProvider

    queryIndexedUTxOs =
        runTransaction
            . IndexedProvider.queryIndexedUTxOs indexer

    queryIndexedUTxOsAt =
        runTransaction
            . IndexedProvider.queryIndexedUTxOsAt indexer

    queryIndexedUTxOByTxIn =
        runTransaction
            . IndexedProvider.queryIndexedUTxOByTxIn indexer
