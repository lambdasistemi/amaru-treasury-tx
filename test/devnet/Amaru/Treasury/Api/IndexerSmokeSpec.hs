{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Api.IndexerSmokeSpec
Description : Opt-in live-boundary smoke for the API indexer
License     : Apache-2.0

Mid-fidelity lifecycle smoke for the #242 API container:

* Spawns a local @cardano-node-clients:devnet@ node (live boundary
  1: real chain-sync).
* Opens a 'Provider' IO session against the live node socket
  (live boundary 2: real N2C handshake against the running
  devnet).
* Brings up 'withApiIndexer' on a tmpfs RocksDB volume (live
  boundary 3: real upstream follower thread).
* Runs warp on an OS-assigned free port (live boundary 4: real
  TCP server).
* Hits @\/v1\/treasury-inspect@ over HTTP and asserts HTTP 200
  with a well-formed body (live boundary 5: real HTTP request
  through 'mkApplication' + 'withLagGuard').
* Forces the readiness 'TVar' to @Lagging 200 60@ via
  'setReadinessForTest', hits the endpoint again, asserts HTTP
  503 with the 6-key body schema from
  @contracts/api-extension.md@.
* Resets readiness to a Ready snapshot, hits the endpoint,
  asserts HTTP 200 again — the 503->200 transition is what
  FR-010 calls out as the recovery contract.

= Scope

The byte-level N2C socket recorder that would independently
verify "zero @GetUTxOByAddress@ on the wire" is deliberately
deferred to a follow-up ticket (per orchestrator's
A-001-smoke-scope answer): the slice-2 unit suite already
proves FR-004 at the Provider boundary via the
'trappedProvider' shape, and the byte-level recorder is a
substantial CBOR-frame scanner for diminishing incremental
coverage.

= Opt-in

The smoke is opt-in: the spec is skipped unless
@DEVNET_API_SMOKE_OPT_IN=1@ is set in the environment. The
operator additionally needs:

* @E2E_GENESIS_DIR@ pointing at a @cardano-node-clients@ devnet
  genesis directory.
* @DEVNET_SMOKE_METADATA@ pointing at a metadata JSON the API
  binary parses cleanly (mainnet's @test/fixtures/metadata.json@
  works — the smoke ignores per-address chain content; only
  the address bech32 needs to parse).

Run via:

> nix develop -c just devnet-api-smoke
-}
module Amaru.Treasury.Api.IndexerSmokeSpec (spec) where

import Cardano.Ledger.Address (Addr, serialiseAddr)
import Cardano.Node.Client.E2E.Devnet (withCardanoNode)
import Cardano.Node.Client.E2E.Setup (devnetMagic, genesisDir)
import Cardano.Node.Client.N2C.Probe (defaultProbeConfig)
import Cardano.Node.Client.N2C.Reconnect
    ( defaultReconnectPolicy
    )
import Cardano.Node.Client.N2C.Trace (nullN2CTracer)
import Cardano.Node.Client.Provider (Provider)
import Cardano.Node.Client.UTxOIndexer.Follower
    ( InterestSet (..)
    )
import Cardano.Node.Client.UTxOIndexer.Types qualified as Indexer
import Control.Concurrent.Async (withAsync)
import Control.Exception (bracket)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as LBS
import Data.Set qualified as Set
import Data.Tagged (Tagged (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time
    ( UTCTime (..)
    , fromGregorian
    , getCurrentTime
    , secondsToDiffTime
    )
import Network.HTTP.Client
    ( Manager
    , Response (..)
    , defaultManagerSettings
    , httpLbs
    , newManager
    , parseRequest
    )
import Network.HTTP.Types (status404, statusCode)
import Network.Socket (close)
import Network.Wai (responseLBS)
import Network.Wai.Handler.Warp
    ( defaultSettings
    , openFreePort
    , runSettingsSocket
    , setHost
    )
import Servant.Server qualified as Servant
import System.Environment (lookupEnv)
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , runIO
    , shouldBe
    )

import Amaru.Treasury.Api.BuildDisburse
    ( DisburseBuildResponse (..)
    )
import Amaru.Treasury.Api.BuildReorganize
    ( ReorganizeBuildResponse (..)
    )
import Amaru.Treasury.Api.BuildSwap
    ( SwapBuildResponse (..)
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
    ( Readiness (..)
    , ReadinessHandle
    , waitReady
    , withReadinessBridge
    )
import Amaru.Treasury.Api.Readiness.Internal
    ( setReadinessForTest
    )
import Amaru.Treasury.Api.Server
    ( Handlers (..)
    , mkApplication
    , mkInspectHandler
    )
import Amaru.Treasury.Api.Types
    ( BuildIdentity (..)
    , RecentTxManifest (..)
    )
import Amaru.Treasury.Backend.N2C (withLocalNodeBackend)
import Amaru.Treasury.Constants (sundaeOrderAddressMainnet)
import Amaru.Treasury.Inspect.Types
    ( DeploymentAnchor (..)
    , Outref (..)
    )
import Amaru.Treasury.IntentJSON.Common (parseAddr)
import Amaru.Treasury.Metadata
    ( TreasuryMetadata (..)
    , readMetadataFile
    )

spec :: Spec
spec = describe "api indexer smoke (opt-in)" $ do
    optIn <- runIO (lookupEnv "DEVNET_API_SMOKE_OPT_IN")
    case optIn of
        Nothing ->
            it
                "skipped — set DEVNET_API_SMOKE_OPT_IN=1\
                \ + E2E_GENESIS_DIR + DEVNET_SMOKE_METADATA\
                \ to run"
                (pure () :: IO ())
        Just _ ->
            it
                "boots against a live devnet, serves\
                \ /v1/treasury-inspect with HTTP 200, then\
                \ short-circuits with 503 when readiness\
                \ flips to Lagging, then recovers to 200"
                runSmoke

-- ---------------------------------------------------------------------------
-- Smoke driver

runSmoke :: IO ()
runSmoke = do
    gDir <- genesisDir
    metadataPath <- requireEnv "DEVNET_SMOKE_METADATA"
    metadata <- readMetadataFile metadataPath
    anchor <- parseAnchorOrFail (tmScopeOwners metadata)
    swapAddr <- parseSwapAddrOrFail
    withCardanoNode gDir $ \nodeSock _startMs ->
        withLocalNodeBackend devnetMagic nodeSock $ \backend ->
            withSystemTempDirectory "atx-api-smoke" $ \dir -> do
                let interestSet =
                        IndexAddressSet
                            (Set.singleton (toIxAddr swapAddr))
                    indexerCfg =
                        smokeIndexerConfig
                            dir
                            nodeSock
                            interestSet
                withApiIndexer
                    nullN2CTracer
                    indexerCfg
                    $ \apiIdx ->
                        withReadinessBridge
                            (icLagThresholdSlots indexerCfg)
                            (aiFollowerReadiness apiIdx)
                            $ \readiness -> do
                                waitReady readiness
                                bracket
                                    openFreePort
                                    (close . snd)
                                    $ \(port, sock) -> do
                                        let handlers =
                                                smokeHandlers
                                                    apiIdx
                                                    backend
                                                    metadata
                                                    anchor
                                                    swapAddr
                                            app =
                                                withLagGuard
                                                    readiness
                                                    ( mkApplication
                                                        handlers
                                                    )
                                            settings =
                                                setHost
                                                    "127.0.0.1"
                                                    defaultSettings
                                        manager <-
                                            newManager
                                                defaultManagerSettings
                                        withAsync
                                            ( runSettingsSocket
                                                settings
                                                sock
                                                app
                                            )
                                            $ \_ ->
                                                runScenarios
                                                    manager
                                                    port
                                                    readiness

runScenarios :: Manager -> Int -> ReadinessHandle -> IO ()
runScenarios manager port readiness = do
    -- Scenario 1: live readiness → 200.
    res1 <- getInspect manager port
    statusCode (responseStatus res1) `shouldBe` 200
    case Aeson.decode (responseBody res1) of
        Just (Aeson.Object _) -> pure ()
        other ->
            failWith $
                "scenario 1: response body is not a JSON\
                \ object: "
                    <> show other

    -- Scenario 2: force Lagging → 503 + 6-key body.
    now <- getCurrentTime
    setReadinessForTest readiness $
        Readiness
            { rProcessedSlot = Indexer.SlotNo 100
            , rTipSlot = Indexer.SlotNo 300
            , rLagSlots = 200
            , rUpstreamUp = True
            , rUpdatedAt = now
            }
    res2 <- getInspect manager port
    statusCode (responseStatus res2) `shouldBe` 503
    case Aeson.decode (responseBody res2) of
        Just (Aeson.Object o) -> do
            KM.lookup "error" o
                `shouldBe` Just
                    (Aeson.String "indexer_lagging")
            KM.lookup "processed_slot" o
                `shouldBe` Just (Aeson.Number 100)
            KM.lookup "tip_slot" o
                `shouldBe` Just (Aeson.Number 300)
            KM.lookup "lag_slots" o
                `shouldBe` Just (Aeson.Number 200)
            KM.lookup "threshold_slots" o
                `shouldBe` Just (Aeson.Number 60)
            KM.member "updated_at" o `shouldBe` True
        other ->
            failWith $
                "scenario 2: 503 response body is not the\
                \ expected JSON object: "
                    <> show other

    -- Scenario 3: restore Ready → 200.
    now' <- getCurrentTime
    setReadinessForTest readiness $
        Readiness
            { rProcessedSlot = Indexer.SlotNo 1000
            , rTipSlot = Indexer.SlotNo 1000
            , rLagSlots = 0
            , rUpstreamUp = True
            , rUpdatedAt = now'
            }
    res3 <- getInspect manager port
    statusCode (responseStatus res3) `shouldBe` 200

-- ---------------------------------------------------------------------------
-- Helpers

getInspect
    :: Manager -> Int -> IO (Response LBS.ByteString)
getInspect manager port = do
    req <-
        parseRequest $
            "http://127.0.0.1:"
                <> show port
                <> "/v1/treasury-inspect?scope=middleware"
    httpLbs req manager

smokeIndexerConfig
    :: FilePath
    -> FilePath
    -> InterestSet
    -> IndexerConfig
smokeIndexerConfig dir nodeSock interestSet =
    IndexerConfig
        { icDbPath = dir <> "/rocksdb"
        , icSocketPath = nodeSock
        , icNetworkMagic = devnetMagic
        , icStartPoint = Nothing
        , icLagThresholdSlots = 60
        , icByronEpochSlots = 86_400
        , icSecurityParamK = 432
        , icReconnectPolicy = defaultReconnectPolicy
        , icProbeConfig = defaultProbeConfig
        , icInterestSet = interestSet
        }

smokeHandlers
    :: ApiIndexer
    -> Provider IO
    -> TreasuryMetadata
    -> DeploymentAnchor
    -> Addr
    -> Handlers
smokeHandlers apiIdx backend metadata anchor swapAddr =
    Handlers
        { hInspectReport = \scope -> do
            r <-
                Servant.runHandler $
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
                    error $
                        "smokeHandlers: mkInspectHandler\
                        \ returned ServerError: "
                            <> show e
        , hRecentTxs = RecentTxManifest []
        , hBuildIdentity = stubBuildIdentity
        , hBuildSwap = \_ ->
            pure
                SwapBuildResponse
                    { sbrIntentJson = Nothing
                    , sbrCli = Nothing
                    , sbrCborHex = Nothing
                    , sbrCborEnvelope = Nothing
                    , sbrReport = Nothing
                    , sbrFailureTag = Just "Smoke"
                    , sbrFailureField = Nothing
                    , sbrFailureReason =
                        Just "smoke handler"
                    , sbrBuildFailureTag = Nothing
                    }
        , hBuildDisburse = \_ ->
            pure
                DisburseBuildResponse
                    { dbrIntentJson = Nothing
                    , dbrCli = Nothing
                    , dbrCborHex = Nothing
                    , dbrCborEnvelope = Nothing
                    , dbrReport = Nothing
                    , dbrFailureTag = Just "Smoke"
                    , dbrFailureField = Nothing
                    , dbrFailureReason =
                        Just "smoke handler"
                    , dbrBuildFailureTag = Nothing
                    }
        , hBuildReorganize = \_ ->
            pure
                ReorganizeBuildResponse
                    { rbrIntentJson = Nothing
                    , rbrCli = Nothing
                    , rbrCborHex = Nothing
                    , rbrCborEnvelope = Nothing
                    , rbrReport = Nothing
                    , rbrFailureTag = Just "Smoke"
                    , rbrFailureField = Nothing
                    , rbrFailureReason =
                        Just "smoke handler"
                    , rbrBuildFailureTag = Nothing
                    }
        , hRawHandler =
            Tagged $ \_req respond ->
                respond $
                    responseLBS
                        status404
                        [("Content-Type", "text/plain")]
                        "smoke: raw not served"
        }

stubBuildIdentity :: BuildIdentity
stubBuildIdentity =
    BuildIdentity
        { biBuildTime =
            UTCTime
                (fromGregorian 2026 5 25)
                (secondsToDiffTime 0)
        , biGitCommit = "smoke"
        , biMetadataSha256 = T.replicate 64 "0"
        , biMetadataSource = "smoke"
        , biRecentTxsCount = 0
        }

toIxAddr :: Addr -> Indexer.Address
toIxAddr = Indexer.Address . serialiseAddr

requireEnv :: String -> IO String
requireEnv name = do
    v <- lookupEnv name
    case v of
        Just x -> pure x
        Nothing ->
            failWith $
                "missing env var "
                    <> name
                    <> " (smoke needs it; see module Haddock)"

parseSwapAddrOrFail :: IO Addr
parseSwapAddrOrFail =
    case parseAddr sundaeOrderAddressMainnet of
        Right a -> pure a
        Left e ->
            failWith $
                "sundaeOrderAddressMainnet failed to\
                \ parse: "
                    <> e

parseAnchorOrFail :: Text -> IO DeploymentAnchor
parseAnchorOrFail raw =
    case parseOutrefText raw of
        Just o -> pure (DeploymentAnchor o)
        Nothing ->
            failWith $
                "tmScopeOwners is not txid#ix: "
                    <> T.unpack raw

parseOutrefText :: Text -> Maybe Outref
parseOutrefText t =
    case T.splitOn "#" t of
        [txid, ix] -> Outref txid <$> readMaybe (T.unpack ix)
        _ -> Nothing
  where
    readMaybe s = case reads s of
        [(n, "")] -> Just n
        _ -> Nothing

failWith :: String -> IO a
failWith msg = do
    expectationFailure msg
    error msg
