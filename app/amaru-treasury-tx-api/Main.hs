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

import Data.Aeson qualified as Aeson
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Streaming.Network (HostPreference)
import Data.String (IsString (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word16)
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
import Cardano.Node.Client.Provider (Provider)
import Cardano.Node.Client.UTxOIndexer.Follower
    ( InterestSet (..)
    )
import Cardano.Node.Client.UTxOIndexer.Types (SlotNo (..))

import Amaru.Treasury.Api.BuildDisburse (runBuildDisburse)
import Amaru.Treasury.Api.BuildReorganize (runBuildReorganize)
import Amaru.Treasury.Api.BuildSwap (runBuildSwap)
import Amaru.Treasury.Api.Config
    ( ApiIndexerRuntimeConfig (..)
    , ApiRuntimeConfig (..)
    , execApiConfig
    )
import Amaru.Treasury.Api.History
    ( queryScopeHistoryResponse
    )
import Amaru.Treasury.Api.Indexer
    ( ApiIndexer (..)
    , IndexerConfig (..)
    , withApiIndexer
    )
import Amaru.Treasury.Api.LagGuard
    ( withLagGuard
    )
import Amaru.Treasury.Api.Readiness
    ( waitReady
    , withReadinessBridge
    )
import Amaru.Treasury.Api.Server
    ( BuildHandlers (..)
    , Handlers (..)
    , mkApplication
    , mkBuildHandlers
    , mkInspectHandler
    )
import Amaru.Treasury.Api.Types
    ( BuildIdentity
    , RecentTxManifest
    )
import Amaru.Treasury.Backend.N2C (withLocalNodeBackend)
import Amaru.Treasury.Cli.Common (GlobalOpts (..))
import Amaru.Treasury.Constants
    ( sundaeOrderAddressMainnet
    )
import Amaru.Treasury.Indexer.Decoder
    ( registryScopeMappingsFromMetadata
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
                            let buildHandlers =
                                    mkBuildHandlers
                                        apiIdx
                                        backend
                                        (runBuildSwap g)
                                        (runBuildDisburse g)
                                        (runBuildReorganize g)
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
                                        , hScopeHistory =
                                            queryScopeHistoryResponse
                                                (aiHistory apiIdx)
                                        , hBuildSwap =
                                            bhBuildSwap buildHandlers
                                        , hBuildDisburse =
                                            bhBuildDisburse buildHandlers
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
    -> IndexerConfig
mkIndexerConfig socket globalOpts cli interestSet registryScopeMappings =
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
    spaPaths = [["operate"], ["view"], ["books"]]

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
