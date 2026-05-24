{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

{- |
Module      : Main
Description : HTTP entry point for the #239 dashboard
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Thin binary that:

  * parses a small CLI surface (@--bind@, @--socket@,
    @--metadata@, @--manifest@, @--build-identity@,
    @--static@);
  * loads the three read-only JSON artefacts the image bakes
    in;
  * opens a single N2C session against the cardano mainnet
    node and reuses it across every HTTP request;
  * runs the servant 'mkApplication' from
    'Amaru.Treasury.Api.Server' on warp at the requested bind
    address.

Refuses to start against any non-mainnet network magic
(FR-025).
-}
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (withAsync)
import Control.Exception (SomeException, throwIO, try)
import Control.Monad (forM_, forever)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as LBS
import Data.IORef
    ( IORef
    , atomicModifyIORef'
    , newIORef
    , readIORef
    )
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Streaming.Network (HostPreference)
import Data.String (IsString (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time
    ( UTCTime
    , getCurrentTime
    )
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
import Options.Applicative
    ( Parser
    , auto
    , execParser
    , fullDesc
    , help
    , helper
    , info
    , long
    , metavar
    , option
    , progDesc
    , short
    , strOption
    , value
    , (<**>)
    )
import Servant.Server.StaticFiles (serveDirectoryFileServer)
import System.Exit (die)
import System.IO
    ( BufferMode (..)
    , hSetBuffering
    , stderr
    , stdout
    )
import System.Timeout (timeout)

import Ouroboros.Network.Magic (NetworkMagic (..))

import Cardano.Ledger.Address (Addr)

import Amaru.Treasury.Api.BuildDisburse (runBuildDisburse)
import Amaru.Treasury.Api.BuildSwap (runBuildSwap)
import Amaru.Treasury.Api.Server
    ( Handlers (..)
    , mkApplication
    )
import Amaru.Treasury.Api.Types
    ( BuildIdentity
    , RecentTxManifest
    )
import Amaru.Treasury.Backend (Backend)
import Amaru.Treasury.Backend.N2C (withLocalNodeBackend)
import Amaru.Treasury.Cli.Common (GlobalOpts (..))
import Amaru.Treasury.Cli.TreasuryInspect
    ( runInspectFromBackend
    )
import Amaru.Treasury.Constants
    ( sundaeOrderAddressMainnet
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
import Amaru.Treasury.Scope (ScopeId, allScopes, scopeText)

-- ---------------------------------------------------------------------------
-- CLI

data Opts = Opts
    { optsHost :: String
    , optsPort :: Int
    , optsSocket :: FilePath
    , optsMetadata :: FilePath
    , optsManifest :: FilePath
    , optsBuildIdentity :: FilePath
    , optsStatic :: FilePath
    }
    deriving (Show)

optsP :: Parser Opts
optsP =
    Opts
        <$> strOption
            ( long "host"
                <> metavar "ADDR"
                <> help "Bind host (default 0.0.0.0)"
                <> value "0.0.0.0"
            )
        <*> option
            auto
            ( long "port"
                <> short 'p'
                <> metavar "PORT"
                <> help "TCP port (default 8080)"
                <> value 8080
            )
        <*> strOption
            ( long "socket"
                <> metavar "PATH"
                <> help "Cardano N2C socket path"
            )
        <*> strOption
            ( long "metadata"
                <> metavar "PATH"
                <> help "journal/2026/metadata.json (baked in)"
            )
        <*> strOption
            ( long "manifest"
                <> metavar "PATH"
                <> help "recent-txs.json (baked in)"
            )
        <*> strOption
            ( long "build-identity"
                <> metavar "PATH"
                <> help "build-identity.json (baked in)"
            )
        <*> strOption
            ( long "static"
                <> metavar "DIR"
                <> help "Halogen bundle directory (baked in)"
            )

-- ---------------------------------------------------------------------------
-- Main

mainnetMagic :: NetworkMagic
mainnetMagic = NetworkMagic 764_824_073

{- | Server-side per-scope cache. Background loop refreshes
| every 'cacheTtlSeconds'; handlers read from the IORef
| instantly. If a refresh fails, the previous successful
| snapshot is served (stale-while-revalidate).
-}
type InspectCache = IORef (Map ScopeId (UTCTime, InspectReport))

-- Sleep between refresh tick starts.
refreshIntervalSeconds :: Int
refreshIntervalSeconds = 30

main :: IO ()
main = do
    hSetBuffering stdout LineBuffering
    hSetBuffering stderr LineBuffering
    opts <-
        execParser $
            info
                (optsP <**> helper)
                ( fullDesc
                    <> progDesc
                        "Run the amaru-treasury read-only \
                        \HTTP dashboard backend."
                )

    metadata <- readMetadataFile (optsMetadata opts)
    anchor <- parseAnchorOrDie (tmScopeOwners metadata)
    swapAddr <- case parseAddr sundaeOrderAddressMainnet of
        Right a -> pure a
        Left e ->
            die $
                "amaru-treasury-tx-api: built-in \
                \sundaeOrderAddressMainnet failed to \
                \parse: "
                    <> e

    manifest <- readJsonOrDie (optsManifest opts) :: IO RecentTxManifest
    buildId <- readJsonOrDie (optsBuildIdentity opts) :: IO BuildIdentity

    let host :: HostPreference
        host = fromString (optsHost opts)
        warpSettings =
            setHost host
                . setPort (optsPort opts)
                $ defaultSettings

    putStrLn $
        "amaru-treasury-tx-api: opening N2C session on "
            <> optsSocket opts
    let g =
            GlobalOpts
                { goSocketPath = Just (optsSocket opts)
                , goNetworkMagic = mainnetMagic
                , goNetworkName = Just "mainnet"
                }
    withLocalNodeBackend mainnetMagic (optsSocket opts) $
        \backend -> do
            cache <- newIORef Map.empty
            -- No startup prime: cardano-node post-replay is
            -- CPU-bound and prime can take minutes. Start
            -- warp immediately; the background refreshLoop
            -- fills the cache as queries succeed, handlers
            -- queue or serve stale until then.
            putStrLn
                "amaru-treasury-tx-api: cache deferred to \
                \background worker"
            let handlers =
                    Handlers
                        { hInspectReport =
                            cachedInspect
                                cache
                                backend
                                metadata
                                anchor
                                swapAddr
                        , hRecentTxs = manifest
                        , hBuildIdentity = buildId
                        , hBuildSwap = runBuildSwap g backend
                        , hBuildDisburse =
                            runBuildDisburse g backend
                        , hRawHandler =
                            serveDirectoryFileServer
                                (optsStatic opts)
                        }
            -- Background refresh loop. Stays inside the N2C
            -- session for the lifetime of warp.
            withAsync
                ( refreshLoop
                    backend
                    metadata
                    anchor
                    swapAddr
                    cache
                )
                $ \_ -> do
                    putStrLn $
                        "amaru-treasury-tx-api: listening on "
                            <> optsHost opts
                            <> ":"
                            <> show (optsPort opts)
                    runSettings
                        warpSettings
                        ( spaFallback
                            (addFrameAncestors (mkApplication handlers))
                        )

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
    spaPaths = [["operate"], ["view"]]

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
-- Cache logic

{- | Lookup-or-fill: if the cache has a recent entry, return
| it; otherwise query the chain inline and store. Used by
| the request handler.
-}
cachedInspect
    :: InspectCache
    -> Backend
    -> TreasuryMetadata
    -> DeploymentAnchor
    -> Addr
    -> ScopeId
    -> IO InspectReport
cachedInspect cache backend metadata anchor swapAddr scope = do
    m <- readIORef cache
    case Map.lookup scope m of
        -- Always serve from the cache when anything is there
        -- (true stale-while-revalidate). The background
        -- refreshLoop keeps trying to update entries; failed
        -- refreshes don't invalidate, so the dashboard
        -- remains responsive even while cardano-node is slow.
        Just (_, r) -> pure r
        Nothing -> do
            -- First-ever request for this scope: query inline
            -- and remember the result. queryOne caps at
            -- queryTimeoutSeconds so this can't hang forever.
            r <- queryOne backend metadata anchor swapAddr scope
            now <- getCurrentTime
            atomicModifyIORef' cache $ \cur ->
                (Map.insert scope (now, r) cur, ())
            pure r

{- | Query the chain for one scope. Times out after
| 'queryTimeoutSeconds' so a stale N2C session doesn't
| block forever — the refresh loop keeps going, the
| handler returns the previous (stale) cache entry.
-}
queryOne
    :: Backend
    -> TreasuryMetadata
    -> DeploymentAnchor
    -> Addr
    -> ScopeId
    -> IO InspectReport
queryOne backend metadata anchor swapAddr scope = do
    mr <-
        timeout (queryTimeoutSeconds * 1_000_000) $
            runInspectFromBackend
                metadata
                anchor
                swapAddr
                (Just scope)
                backend
    case mr of
        Just r -> pure r
        Nothing ->
            throwIO $
                userError $
                    "queryOne: N2C query for "
                        <> T.unpack (scopeText scope)
                        <> " timed out after "
                        <> show queryTimeoutSeconds
                        <> " s"

queryTimeoutSeconds :: Int
queryTimeoutSeconds = 60

{- | Refresh every scope, swallowing per-scope exceptions so
| one failure doesn't take down the loop.
-}
refreshAll
    :: Backend
    -> TreasuryMetadata
    -> DeploymentAnchor
    -> Addr
    -> InspectCache
    -> IO ()
refreshAll backend metadata anchor swapAddr cache =
    forM_ allScopes $ \scope -> do
        e <-
            try @SomeException
                (queryOne backend metadata anchor swapAddr scope)
        case e of
            Right r -> do
                now <- getCurrentTime
                atomicModifyIORef' cache $ \cur ->
                    (Map.insert scope (now, r) cur, ())
            Left ex ->
                putStrLn $
                    "amaru-treasury-tx-api: refresh "
                        <> T.unpack (scopeText scope)
                        <> " failed: "
                        <> show ex

{- | Forever: refresh, sleep, repeat. Refreshes IMMEDIATELY
| at startup so the cache fills as soon as the chain is
| reachable.
-}
refreshLoop
    :: Backend
    -> TreasuryMetadata
    -> DeploymentAnchor
    -> Addr
    -> InspectCache
    -> IO ()
refreshLoop backend metadata anchor swapAddr cache = forever do
    putStrLn "amaru-treasury-tx-api: refresh tick start"
    refreshAll backend metadata anchor swapAddr cache
    m <- readIORef cache
    putStrLn $
        "amaru-treasury-tx-api: refresh tick done; cache size = "
            <> show (Map.size m)
    threadDelay (refreshIntervalSeconds * 1_000_000)

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
