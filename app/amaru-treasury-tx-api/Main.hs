{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Main
Description : HTTP entry point for the #239 dashboard
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Thin binary that:

  * parses a small CLI surface (@--bind@, @--socket@,
    @--metadata@, @--manifest@, @--build-identity@,
    @--static@) plus the embedded-indexer flags introduced
    by #242 (@--indexer-db@,
    @--indexer-lag-threshold-slots@,
    @--indexer-start-slot@,
    @--indexer-start-block-hash@);
  * loads the three read-only JSON artefacts the image
    bakes in;
  * opens a single N2C session against the cardano mainnet
    node and reuses it across every HTTP request for
    'nowTip' on the @/v1/treasury-inspect@ response only —
    treasury UTxOs are served from the embedded indexer
    (#242);
  * brings up the embedded chain-sync follower against a
    local RocksDB store via 'withApiIndexer', blocks warp
    bind until 'waitReady' returns, and wraps the wai
    application with 'withLagGuard' so every endpoint
    fail-closes with HTTP 503 during follower drift.

Refuses to start against any non-mainnet network magic
(FR-025).
-}
module Main (main) where

import Control.Concurrent.STM (readTVarIO)
import Data.Aeson qualified as Aeson
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Streaming.Network (HostPreference)
import Data.String (IsString (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word16, Word64)
import Network.Wai
    ( Middleware
    , mapResponseHeaders
    , pathInfo
    )
import Network.Wai.Handler.Warp
    ( defaultSettings
    , runSettings
    , setHost
    , setPort
    )
import Ouroboros.Network.Magic (NetworkMagic)
import Servant.Server (runHandler)
import Servant.Server.StaticFiles (serveDirectoryFileServer)
import System.Exit (die)
import System.IO
    ( BufferMode (..)
    , hSetBuffering
    , stderr
    , stdout
    )

import Cardano.Ledger.Address (Addr)
import Cardano.Node.Client.N2C.Probe (defaultProbeConfig)
import Cardano.Node.Client.N2C.Reconnect
    ( defaultReconnectPolicy
    )
import Cardano.Node.Client.N2C.Trace (defaultStderrTracer)
import Cardano.Node.Client.Provider (Provider (..))
import Cardano.Node.Client.UTxOIndexer.Follower
    ( InterestSet (..)
    )
import Cardano.Node.Client.UTxOIndexer.Types (SlotNo (..))

import Amaru.Treasury.Api.Attach (attachTx)
import Amaru.Treasury.Api.BuildContingencyDisburse
    ( runBuildContingencyDisburse
    )
import Amaru.Treasury.Api.BuildDisburse (runBuildDisburse)
import Amaru.Treasury.Api.BuildReorganize (runBuildReorganize)
import Amaru.Treasury.Api.BuildSwap (runBuildSwap)
import Amaru.Treasury.Api.Config
    ( ApiIndexerRuntimeConfig (..)
    , ApiRuntimeConfig (..)
    , execApiConfig
    )
import Amaru.Treasury.Api.History
    ( queryScopeHistoryFilteredResponse
    , queryScopeHistoryQueryResponse
    , queryScopeHistoryShaclResponse
    , queryTxDetailResponse
    )
import Amaru.Treasury.Api.Indexer
    ( ApiIndexer (..)
    , IndexerConfig (..)
    , snapshotUtxosByTxIn
    , withApiIndexer
    )
import Amaru.Treasury.Api.Introspect (introspectTx)
import Amaru.Treasury.Api.LagGuard
    ( withLagGuard
    )
import Amaru.Treasury.Api.Readiness
    ( Readiness (..)
    , ReadinessHandle (..)
    , ReadyState (..)
    , checkReady
    , waitReady
    , withReadinessBridge
    )
import Amaru.Treasury.Api.Server
    ( BuildHandlers (..)
    , Handlers (..)
    , mkApplication
    , mkBuildHandlers
    , mkBuildProvider
    , mkInspectHandler
    )
import Amaru.Treasury.Api.State
    ( queryPending
    , queryScopeState
    , queryScopeUtxos
    , registryResponseFromMetadata
    , scriptsResponseFromMetadata
    )
import Amaru.Treasury.Api.Types
    ( BuildIdentity
    , HealthResponse (..)
    , ParamsResponse (..)
    , RecentTxManifest
    , SubmitRequest (..)
    , SubmitResponse (..)
    , TipResponse (..)
    )
import Amaru.Treasury.Api.VerifyWitness (verifyWitness)
import Amaru.Treasury.Backend.N2C (withLocalNodeBackend)
import Amaru.Treasury.Cli.Common
    ( GlobalOpts (..)
    , nowTip
    )
import Amaru.Treasury.Constants
    ( sundaeOrderAddressMainnet
    )
import Amaru.Treasury.Indexer.Decoder
    ( registryScopeMappingsFromMetadata
    , scopeAddressMappingsFromMetadata
    )
import Amaru.Treasury.Inspect.Types
    ( DeploymentAnchor (..)
    , InspectReport
    , Outref (..)
    )
import Amaru.Treasury.IntentJSON.Common (parseAddr)
import Amaru.Treasury.Metadata
    ( TreasuryMetadata (..)
    , readMetadataFile
    )
import Amaru.Treasury.Scope (ScopeId)
import Amaru.Treasury.Tx.Submit
    ( SubmitOutcome (..)
    , renderSubmitOutcome
    , renderTxId
    , submitSignedTx
    )

-- Main

main :: IO ()
main = do
    hSetBuffering stdout LineBuffering
    hSetBuffering stderr LineBuffering
    opts <- execApiConfig

    metadata <- readMetadataFile (arcMetadata opts)
    anchor <- parseAnchorOrDie (tmScopeOwners metadata)
    swapAddr <- case parseAddr sundaeOrderAddressMainnet of
        Right a -> pure a
        Left e ->
            die $
                "amaru-treasury-tx-api: built-in \
                \sundaeOrderAddressMainnet failed to \
                \parse: "
                    <> e

    manifest <- readJsonOrDie (arcManifest opts) :: IO RecentTxManifest
    buildId <- readJsonOrDie (arcBuildIdentity opts) :: IO BuildIdentity

    interestSet <- computeInterestSet metadata swapAddr

    let host :: HostPreference
        host = fromString (arcHost opts)
        warpSettings =
            setHost host
                . setPort (arcPort opts)
                $ defaultSettings
        indexerCfg =
            mkIndexerConfig
                (arcSocket opts)
                (arcGlobalOpts opts)
                (arcIndexer opts)
                interestSet
                (registryScopeMappingsFromMetadata metadata)
                (scopeAddressMappingsFromMetadata metadata)

    putStrLn $
        "amaru-treasury-tx-api: opening N2C session on "
            <> arcSocket opts
    let g = arcGlobalOpts opts
    withLocalNodeBackend (goNetworkMagic g) (arcSocket opts) $
        \backend -> do
            putStrLn $
                "amaru-treasury-tx-api: bringing up \
                \embedded indexer at "
                    <> icDbPath indexerCfg
            withApiIndexer defaultStderrTracer indexerCfg $
                \apiIdx ->
                    withReadinessBridge
                        (icLagThresholdSlots indexerCfg)
                        (aiFollowerReadiness apiIdx)
                        $ \readiness -> do
                            putStrLn
                                "amaru-treasury-tx-api: waiting for \
                                \indexer readiness before binding \
                                \warp"
                            waitReady readiness
                            putStrLn
                                "amaru-treasury-tx-api: indexer \
                                \ready; binding warp"
                            -- The build runners read metadata from
                            -- the SERVER's own --metadata; the HTTP
                            -- surface carries no client path.
                            let metadataPath = arcMetadata opts
                                buildHandlers =
                                    mkBuildHandlers
                                        apiIdx
                                        (Just metadata)
                                        backend
                                        (runBuildSwap g metadataPath)
                                        (runBuildDisburse g metadataPath)
                                        ( runBuildContingencyDisburse
                                            g
                                            metadataPath
                                        )
                                        (runBuildReorganize g metadataPath)
                                readProvider =
                                    mkBuildProvider apiIdx backend
                                handlers =
                                    Handlers
                                        { hInspectReport =
                                            runInspectScope
                                                apiIdx
                                                backend
                                                metadata
                                                anchor
                                                swapAddr
                                        , hRecentTxs = manifest
                                        , hBuildIdentity = buildId
                                        , hIntrospect =
                                            introspectTx (Just metadata)
                                        , hVerifyWitness = verifyWitness
                                        , hAttach = attachTx
                                        , hTxDetail =
                                            queryTxDetailResponse
                                                (snapshotUtxosByTxIn apiIdx)
                                                (aiHistory apiIdx)
                                                (Just metadata)
                                        , hRegistry =
                                            pure $
                                                registryResponseFromMetadata
                                                    metadata
                                        , hScripts =
                                            pure $
                                                scriptsResponseFromMetadata
                                                    metadata
                                        , hPending =
                                            queryPending
                                                readProvider
                                                metadata
                                                swapAddr
                                        , hTip =
                                            TipResponse <$> nowTip backend
                                        , hParams = do
                                            params <-
                                                queryProtocolParams backend
                                            pure
                                                ParamsResponse
                                                    { parEra = "conway"
                                                    , parSummary =
                                                        T.pack (show params)
                                                    }
                                        , hSubmit =
                                            runSubmitRequest
                                                (goNetworkMagic g)
                                                (arcSocket opts)
                                        , hHealth =
                                            healthResponse readiness
                                        , hScopeState =
                                            queryScopeState
                                                readProvider
                                                metadata
                                                swapAddr
                                        , hScopeUtxos =
                                            queryScopeUtxos
                                                readProvider
                                                metadata
                                                swapAddr
                                        , hScopeHistory =
                                            queryScopeHistoryFilteredResponse
                                                (aiHistory apiIdx)
                                        , hScopeHistoryQuery =
                                            queryScopeHistoryQueryResponse
                                                (aiHistory apiIdx)
                                                (Just metadata)
                                        , hScopeHistoryShacl =
                                            queryScopeHistoryShaclResponse
                                                (aiHistory apiIdx)
                                                (Just metadata)
                                        , hBuildSwap =
                                            bhBuildSwap buildHandlers
                                        , hBuildDisburse =
                                            bhBuildDisburse buildHandlers
                                        , hBuildContingencyDisburse =
                                            bhBuildContingencyDisburse
                                                buildHandlers
                                        , hBuildReorganize =
                                            bhBuildReorganize
                                                buildHandlers
                                        , hRawHandler =
                                            serveDirectoryFileServer
                                                (arcStatic opts)
                                        }
                            putStrLn $
                                "amaru-treasury-tx-api: listening on "
                                    <> arcHost opts
                                    <> ":"
                                    <> show (arcPort opts)
                            runSettings
                                warpSettings
                                ( withLagGuard readiness $
                                    spaFallback $
                                        addFrameAncestors $
                                            mkApplication handlers
                                )

{- | Run 'mkInspectHandler' against the embedded indexer
and the live provider, then unwrap the resulting
'Servant.Handler' back into 'IO InspectReport' — the
shape the 'Handlers' record's @hInspectReport@ field
expects. The shim is a one-liner because
'mkInspectHandler' is built so its only escape route is
the indexer (via 'snapshotUtxosAt') and 'nowTip' on the
backend.
-}
runInspectScope
    :: ApiIndexer cf op
    -> Provider IO
    -> TreasuryMetadata
    -> DeploymentAnchor
    -> Addr
    -> ScopeId
    -> IO InspectReport
runInspectScope apiIdx backend metadata anchor swapAddr scope = do
    r <-
        runHandler $
            mkInspectHandler
                apiIdx
                backend
                metadata
                anchor
                swapAddr
                scope
    case r of
        Right rep -> pure rep
        Left e ->
            -- Should never happen in practice — the inspect
            -- handler doesn't throwError. Surface loudly if
            -- it ever does.
            ioError $
                userError $
                    "amaru-treasury-tx-api: mkInspectHandler \
                    \threw a Servant.ServerError; this is \
                    \unexpected: "
                        <> show e

runSubmitRequest
    :: NetworkMagic
    -> FilePath
    -> SubmitRequest
    -> IO SubmitResponse
runSubmitRequest magic socketPath (SubmitRequest cborHex) = do
    outcome <- submitSignedTx magic socketPath (TE.encodeUtf8 cborHex)
    pure $ case outcome of
        SubmitAccepted txId ->
            SubmitResponse
                { subStatus = "accepted"
                , subTxId = Just (renderTxId txId)
                , subReason = Nothing
                }
        SubmitRejected _ ->
            SubmitResponse
                { subStatus = "rejected"
                , subTxId = Nothing
                , subReason = Just (renderSubmitOutcome outcome)
                }
        SubmitDecodeFailed _ ->
            SubmitResponse
                { subStatus = "decode_failed"
                , subTxId = Nothing
                , subReason = Just (renderSubmitOutcome outcome)
                }

healthResponse :: ReadinessHandle -> IO HealthResponse
healthResponse readiness = do
    status <- checkReady readiness
    snapshot <- readTVarIO (rhReadiness readiness)
    pure
        HealthResponse
            { hrStatus = readyStateText status
            , hrProcessedSlot = slotWord64 (rProcessedSlot snapshot)
            , hrTipSlot = slotWord64 (rTipSlot snapshot)
            , hrLagSlots = rLagSlots snapshot
            , hrThresholdSlots = rhLagThresholdSlots readiness
            , hrUpdatedAt = rUpdatedAt snapshot
            }

readyStateText :: ReadyState -> Text
readyStateText = \case
    Pending -> "pending"
    Ready -> "ready"
    Lagging{} -> "lagging"

slotWord64 :: SlotNo -> Word64
slotWord64 (SlotNo slot) = slot

{- | Build the runner's 'IndexerConfig' from the operator
flags. The four internally-defaulted fields
('icByronEpochSlots', 'icSecurityParamK',
'icReconnectPolicy', 'icProbeConfig') match the upstream
daemon's mainnet defaults; documented in
'Amaru.Treasury.Api.Indexer.IndexerConfig'. The final
argument carries the @registry-policy → scope@ mappings
recovered from the deployment metadata, so the embedded
tx-history decoder can classify treasury txs whose
registry policies are not the pinned-seed statics.
-}
mkIndexerConfig
    :: FilePath
    -> GlobalOpts
    -> ApiIndexerRuntimeConfig
    -> InterestSet
    -> [(ByteString, ScopeId)]
    -> [(ByteString, ScopeId)]
    -> IndexerConfig
mkIndexerConfig
    socket
    globalOpts
    cli
    interestSet
    registryScopeMappings
    scopeAddressMappings =
        IndexerConfig
            { icDbPath = aircDbPath cli
            , icSocketPath = socket
            , icNetworkMagic = goNetworkMagic globalOpts
            , icStartPoint =
                first SlotNo <$> aircStartPoint cli
            , icLagThresholdSlots = aircLagThresholdSlots cli
            , icByronEpochSlots = 21_600
            , icSecurityParamK = 2160
            , icReconnectPolicy = defaultReconnectPolicy
            , icProbeConfig = defaultProbeConfig
            , icInterestSet = interestSet
            , icRegistryScopeMappings = registryScopeMappings
            , icScopeAddressMappings = scopeAddressMappings
            }

{- | Build the apply-time interest set the embedded
indexer uses when @amaru-treasury-tx-api@ starts.

Wizard-backed API flows can ask for arbitrary wallet
UTxOs, not only treasury and swap-order addresses, so
the embedded follower must retain the full UTxO set.
-}
computeInterestSet
    :: TreasuryMetadata
    -> Addr
    -- ^ The pre-parsed SundaeSwap order address.
    -> IO InterestSet
computeInterestSet _metadata _sundaeAddr = do
    putStrLn
        "amaru-treasury-tx-api: indexer interest set = IndexAll \
        \(wizard takes arbitrary wallet; needs every UTxO)"
    pure IndexAll

-- ---------------------------------------------------------------------------
-- SPA fallback middleware

{- | Rewrite known SPA routes (currently only @\/build@) to
@\/@ so the existing static-asset Raw handler returns the
Halogen bundle's @index.html@.  Without this, a direct GET
\/build returns a 404 from servant since no route matches.

The list is intentionally tiny; expand only when the SPA
adds another top-level path.
-}
spaFallback :: Middleware
spaFallback app req respond
    | pathInfo req `elem` spaPaths =
        app req{pathInfo = []} respond
    | otherwise = app req respond
  where
    spaPaths :: [[Text]]
    spaPaths = [["operate"], ["view"], ["books"], ["audit"]]

-- ---------------------------------------------------------------------------
-- Response-header middleware

{- | Inject a CSP @frame-ancestors@ directive on every
response so a design collaborator can embed the dashboard
in Claude's preview sandbox.  No @X-Frame-Options@ header is
set (legacy, superseded by @frame-ancestors@); if a reverse
proxy ever adds one, strip it there.

This is a *dev*-leaning permissive list; tighten for prod.
-}
addFrameAncestors :: Middleware
addFrameAncestors app req respond =
    app req $ \res ->
        respond (mapResponseHeaders (cspHeader :) res)
  where
    cspHeader =
        ( "Content-Security-Policy"
        , "frame-ancestors 'self' \
          \https://*.claudeusercontent.com \
          \https://claude.ai"
        )

-- ---------------------------------------------------------------------------
-- Helpers

readJsonOrDie :: (Aeson.FromJSON a) => FilePath -> IO a
readJsonOrDie path = do
    bytes <- LBS.readFile path
    case Aeson.eitherDecode bytes of
        Right v -> pure v
        Left e ->
            die $
                "amaru-treasury-tx-api: failed to decode "
                    <> path
                    <> ": "
                    <> e

parseAnchorOrDie :: Text -> IO DeploymentAnchor
parseAnchorOrDie raw =
    case T.splitOn "#" raw of
        [txid, ix] ->
            case reads (T.unpack ix) :: [(Word16, String)] of
                [(n, "")] ->
                    pure
                        ( DeploymentAnchor
                            Outref
                                { orTxId = txid
                                , orIx = n
                                }
                        )
                _ ->
                    die $
                        "amaru-treasury-tx-api: \
                        \metadata.scope_owners ix not \
                        \numeric: "
                            <> T.unpack raw
        _ ->
            die $
                "amaru-treasury-tx-api: \
                \metadata.scope_owners not txid#ix: "
                    <> T.unpack raw
