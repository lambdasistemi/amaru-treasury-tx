{-# LANGUAGE DataKinds #-}
{-# LANGUAGE EmptyCase #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
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

import Cardano.Crypto.DSIGN
    ( Ed25519DSIGN
    , SignKeyDSIGN
    , deriveVerKeyDSIGN
    , rawSerialiseSignKeyDSIGN
    )
import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Ledger.Address
    ( Addr
    , getNetwork
    , serialiseAddr
    )
import Cardano.Ledger.Alonzo.Scripts (AsIx)
import Cardano.Ledger.Api.Tx (txIdTx)
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , addrTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.BaseTypes
    ( Network (..)
    , mkTxIxPartial
    )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose)
import Cardano.Ledger.Core (PParams)
import Cardano.Ledger.Hashes (KeyHash, extractHash)
import Cardano.Ledger.Keys
    ( KeyRole (Payment)
    , VKey (..)
    , hashKey
    )
import Cardano.Ledger.Mary.Value
    ( MaryValue (..)
    , MultiAsset (..)
    )
import Cardano.Ledger.Plutus.ExUnits (ExUnits)
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Cardano.Node.Client.E2E.Devnet (withCardanoNode)
import Cardano.Node.Client.E2E.Setup
    ( addKeyWitness
    , devnetMagic
    , genesisAddr
    , genesisDir
    , genesisSignKey
    )
import Cardano.Node.Client.N2C.Probe (defaultProbeConfig)
import Cardano.Node.Client.N2C.Reconnect
    ( defaultReconnectPolicy
    )
import Cardano.Node.Client.N2C.Trace (nullN2CTracer)
import Cardano.Node.Client.Provider
    ( LedgerSnapshot (..)
    , Provider (..)
    )
import Cardano.Node.Client.Submitter
    ( SubmitResult (..)
    , Submitter (..)
    )
import Cardano.Node.Client.TxHistoryIndexer.Types qualified as History
import Cardano.Node.Client.UTxOIndexer.Follower
    ( InterestSet (..)
    )
import Cardano.Node.Client.UTxOIndexer.Types qualified as Indexer
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Tx.Build
    ( InterpretIO (..)
    , TxBuild
    , build
    , collateral
    , mkPParamsBound
    , payTo
    , spend
    , validTo
    )
import Cardano.Tx.Ledger (ConwayTx)
import Codec.Binary.Bech32 qualified as Bech32
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (withAsync)
import Control.Exception (bracket)
import Control.Monad (unless)
import Data.Aeson
    ( FromJSON (..)
    , eitherDecodeFileStrict
    , encode
    , object
    , withObject
    , (.:)
    , (.=)
    )
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as BSL
import Data.ByteString.Lazy qualified as LBS
import Data.Char (isDigit)
import Data.Foldable (toList)
import Data.List qualified as List
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Tagged (Tagged (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time
    ( UTCTime (..)
    , fromGregorian
    , getCurrentTime
    , secondsToDiffTime
    )
import Data.Void (Void)
import Data.Word (Word64)
import Lens.Micro ((^.))
import Network.HTTP.Client
    ( Manager
    , Request (..)
    , RequestBody (..)
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
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files
    ( ownerReadMode
    , setFileMode
    )
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , runIO
    , shouldBe
    )

import Amaru.Treasury.Api.BuildDisburse
    ( DisburseBuildRequest (..)
    , DisburseBuildResponse (..)
    , runBuildDisburse
    )
import Amaru.Treasury.Api.BuildReorganize
    ( ReorganizeBuildRequest (..)
    , ReorganizeBuildResponse (..)
    , runBuildReorganize
    )
import Amaru.Treasury.Api.BuildSwap
    ( runBuildSwap
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
    , snapshotUtxosAt
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
    ( BuildIdentity (..)
    , RecentTxManifest (..)
    )
import Amaru.Treasury.Backend.N2C (withLocalNodeClient)
import Amaru.Treasury.Cli.Common (GlobalOpts (..))
import Amaru.Treasury.Cli.History
    ( queryScopeHistory
    , queryTxDetail
    , renderHistoryRows
    , renderTxDetail
    )
import Amaru.Treasury.Devnet.RegistryInit
    ( DevnetRegistryAnchors (..)
    , DevnetRegistryPublication (..)
    , TreasuryTarget (..)
    )
import Amaru.Treasury.Devnet.RegistryInit qualified as RegistryInit
import Amaru.Treasury.Devnet.Runner
    ( DevnetStakeRewardInitOpts (..)
    , runDevnetStakeRewardInit
    )
import Amaru.Treasury.Indexer.Decoder
    ( registryScopeMappingsFromMetadata
    , scopeAddressMappingsFromMetadata
    )
import Amaru.Treasury.Inspect.Types
    ( DeploymentAnchor (..)
    , Outref (..)
    )
import Amaru.Treasury.Metadata
    ( ScopeMetadata (..)
    , ScriptRef (..)
    , TreasuryMetadata (..)
    )
import Amaru.Treasury.Registry.Derive
    ( scriptHashToHex
    )
import Amaru.Treasury.Report.Accounting
    ( ValueSummary (..)
    , valueSummary
    )
import Amaru.Treasury.Scope
    ( ScopeId (CoreDevelopment)
    )
import Amaru.Treasury.Tx.AttachWitness
    ( decodeUnsignedTxHex
    )
import Amaru.Treasury.Tx.SwapWizard
    ( txInToText
    )
import Amaru.Treasury.Tx.Witness
    ( addCardanoCliPaymentKeyWitness
    )

data PreIndexerStabilityProof = PreIndexerStabilityProof
    { pispDerivedThresholdSlots :: !Word
    , pispObservedForgedBlocks :: !Word
    , pispObservedTipSlot :: !Word
    , pispWaitCompletedBeforeIndexerStart :: !Bool
    }
    deriving stock (Eq, Show)

data SmokeProofs = SmokeProofs
    { spPreIndexerStability :: !(Maybe PreIndexerStabilityProof)
    , spIndexedPhaseProofs :: ![Text]
    }
    deriving stock (Eq, Show)

data ShelleyGenesisConfig = ShelleyGenesisConfig
    { sgcNetworkMagic :: !Int
    , sgcSecurityParam :: !Word
    }
    deriving stock (Eq, Show)

instance FromJSON ShelleyGenesisConfig where
    parseJSON =
        withObject "ShelleyGenesisConfig" $ \o ->
            ShelleyGenesisConfig
                <$> o .: "networkMagic"
                <*> o .: "securityParam"

data NoCtx a

spec :: Spec
spec = describe "api indexer smoke (opt-in)" $ do
    optIn <- runIO (lookupEnv "DEVNET_API_SMOKE_OPT_IN")
    case optIn of
        Nothing ->
            it
                "skipped — set DEVNET_API_SMOKE_OPT_IN=1\
                \ + E2E_GENESIS_DIR to run"
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
    genesis <- readShelleyGenesisConfig gDir
    sgcNetworkMagic genesis `shouldBe` 42
    withCardanoNode gDir $ \nodeSock _startMs ->
        withLocalNodeClient devnetMagic nodeSock $ \backend submitter ->
            withSystemTempDirectory "atx-api-smoke" $ \dir -> do
                let globalOpts =
                        GlobalOpts
                            { goSocketPath = Just nodeSock
                            , goNetworkMagic = devnetMagic
                            , goNetworkName = Just "devnet"
                            }
                pp <- queryProtocolParams backend
                seedUtxos <- queryUTxOs backend genesisAddr
                publication <-
                    RegistryInit.publishDevnetRegistryInit
                        (apiRegistryConfig genesisAddr)
                        backend
                        submitter
                        pp
                        seedUtxos
                RegistryInit.writeRegistryInitArtifacts
                    42
                    dir
                    publication
                signingKeyFile <- writeGenesisPaymentSigningKey dir
                runDevnetStakeRewardInit
                    globalOpts
                    DevnetStakeRewardInitOpts
                        { dsrioRegistryFile =
                            RegistryInit.registryInitRegistryPath dir
                        , dsrioFundingAddress =
                            T.unpack (renderAddr genesisAddr)
                        , dsrioSigningKeyFile = signingKeyFile
                        , dsrioRunDir = dir
                        }
                fundingUtxos <- queryUTxOs backend genesisAddr
                (_preIndexerFundingTxId, treasuryInputs) <-
                    fundApiTreasuryUtxos
                        backend
                        submitter
                        pp
                        (draTreasuryTarget (drpAnchors publication))
                        fundingUtxos
                let metadata =
                        devnetMetadataFromRegistry publication
                    anchor =
                        devnetDeploymentAnchor publication
                    swapAddr =
                        genesisAddr
                    metadataPath =
                        dir </> "api-devnet-metadata.json"
                    indexerCfg =
                        smokeIndexerConfig
                            dir
                            nodeSock
                            IndexAll
                            (fromIntegral (sgcSecurityParam genesis))
                            ( registryScopeMappingsFromMetadata
                                metadata
                            )
                            ( scopeAddressMappingsFromMetadata
                                metadata
                            )
                writeSmokeMetadata metadataPath metadata
                stabilityProof <-
                    waitForPreIndexerStability
                        backend
                        (sgcSecurityParam genesis)
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
                                                    globalOpts
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
                                            $ \_ -> do
                                                phaseProofs <-
                                                    runIndexedPhaseScenarios
                                                        manager
                                                        port
                                                        apiIdx
                                                        backend
                                                        submitter
                                                        pp
                                                        metadataPath
                                                        (drpAnchors publication)
                                                        treasuryInputs
                                                runScenarios
                                                    manager
                                                    port
                                                    readiness
                                                    SmokeProofs
                                                        { spPreIndexerStability =
                                                            Just stabilityProof
                                                        , spIndexedPhaseProofs =
                                                            phaseProofs
                                                        }

runScenarios
    :: Manager -> Int -> ReadinessHandle -> SmokeProofs -> IO ()
runScenarios manager port readiness proofs = do
    assertPreIndexerStabilityProof (spPreIndexerStability proofs)
    assertIndexedPhaseProofs (spIndexedPhaseProofs proofs)

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

runIndexedPhaseScenarios
    :: Manager
    -> Int
    -> ApiIndexer cf op
    -> Provider IO
    -> Submitter IO
    -> PParams ConwayEra
    -> FilePath
    -> DevnetRegistryAnchors
    -> ((TxIn, TxOut ConwayEra), (TxIn, TxOut ConwayEra))
    -> IO [Text]
runIndexedPhaseScenarios
    manager
    port
    apiIdx
    provider
    submitter
    pp
    metadataPath
    anchors
    _treasuryInputs = do
        assertInspectTreasuryState
            manager
            port
            "initial treasury funding"
            2
            60_000_000
        disburseTxId <-
            postBuildDisburseAndSubmit
                manager
                port
                submitter
                metadataPath
                anchors
        let disburseTreasuryRef = txOutRef disburseTxId 0
            disburseBeneficiaryRef = txOutRef disburseTxId 1
        _ <-
            awaitIndexedTxOut
                apiIdx
                "disburse treasury continuation"
                (ttAddress (draTreasuryTarget anchors))
                disburseTreasuryRef
                (assertPureAdaTxOut 35_000_000)
        _ <-
            awaitIndexedTxOut
                apiIdx
                "disburse beneficiary output"
                genesisAddr
                disburseBeneficiaryRef
                (assertPureAdaTxOut 5_000_000)
        assertInspectTreasuryState
            manager
            port
            "after disburse"
            2
            55_000_000

        reorganizeTxId <-
            postBuildReorganizeAndSubmit
                manager
                port
                submitter
                metadataPath
        let reorganizeTreasuryRef = txOutRef reorganizeTxId 0
        _ <-
            awaitIndexedTxOut
                apiIdx
                "reorganize merged treasury continuation"
                (ttAddress (draTreasuryTarget anchors))
                reorganizeTreasuryRef
                (assertPureAdaTxOut 55_000_000)
        assertInspectTreasuryState
            manager
            port
            "after reorganize"
            1
            55_000_000

        fundingUtxos <- queryUTxOs provider genesisAddr
        (inboundTxId, _) <-
            fundApiTreasuryUtxos
                provider
                submitter
                pp
                (draTreasuryTarget anchors)
                fundingUtxos

        historyRows <-
            awaitHistoryRows
                apiIdx
                [ (disburseTxId, "disburse", "outbound")
                , (reorganizeTxId, "reorganize", "outbound")
                , (inboundTxId, "-", "inbound")
                ]
        disburseDetailRows <-
            awaitDisburseTxDetail
                apiIdx
                disburseTxId
                (ttAddress (draTreasuryTarget anchors))
                genesisAddr
        mapM_
            ( \row ->
                putStrLn
                    ("treasury history row: " <> T.unpack row)
            )
            historyRows
        mapM_
            ( \row ->
                putStrLn
                    ("treasury tx-detail row: " <> T.unpack row)
            )
            disburseDetailRows
        pure
            [ "POST /v1/build/disburse success"
            , "disburse treasury continuation"
            , "disburse beneficiary output"
            , "POST /v1/build/reorganize success"
            , "reorganize merged treasury continuation"
            , "indexed inbound funding submitted"
            , "indexed history disburse row present"
            , "indexed history reorganize row present"
            , "indexed history inbound row present"
            , "tx-detail disburse decoded view present"
            ]

-- ---------------------------------------------------------------------------
-- Helpers

assertPreIndexerStabilityProof
    :: Maybe PreIndexerStabilityProof -> IO ()
assertPreIndexerStabilityProof proof =
    case proof of
        Nothing ->
            failWith
                "missing pre-indexer stability observation/order proof: \
                \expected derived security-param threshold, distinct \
                \post-wait-start forged block observations greater than \
                \threshold, observed tip, and confirmation that \
                \withApiIndexer started only after the stability wait"
        Just observed -> do
            let threshold = pispDerivedThresholdSlots observed
                observedBlocks = pispObservedForgedBlocks observed
            unless (observedBlocks > threshold) $
                failWith $
                    "pre-indexer stability wait observed "
                        <> show observedBlocks
                        <> " distinct post-wait-start forged blocks \
                           \but derived threshold is "
                        <> show threshold
                        <> " (tip slot "
                        <> show (pispObservedTipSlot observed)
                        <> ")"
            unless (pispWaitCompletedBeforeIndexerStart observed) $
                failWith
                    "withApiIndexer started before the pre-indexer \
                    \stability wait completed"

assertIndexedPhaseProofs :: [Text] -> IO ()
assertIndexedPhaseProofs observed =
    case missing of
        [] -> pure ()
        _ ->
            failWith $
                "missing indexed devnet phase observations: "
                    <> T.unpack (T.intercalate ", " missing)
                    <> "; observed: "
                    <> T.unpack (T.intercalate ", " observed)
  where
    required =
        [ "POST /v1/build/disburse success"
        , "disburse treasury continuation"
        , "disburse beneficiary output"
        , "POST /v1/build/reorganize success"
        , "reorganize merged treasury continuation"
        , "indexed inbound funding submitted"
        , "indexed history disburse row present"
        , "indexed history reorganize row present"
        , "indexed history inbound row present"
        , "tx-detail disburse decoded view present"
        ]
    missing =
        List.filter (`notElem` observed) required

apiRegistryConfig :: Addr -> RegistryInit.DevnetRegistryInitConfig
apiRegistryConfig fundingAddress =
    RegistryInit.DevnetRegistryInitConfig
        { RegistryInit.dricNetwork = Testnet
        , RegistryInit.dricFundingAddress = fundingAddress
        , RegistryInit.dricOwnerKeyHash =
            paymentKeyHashFromSignKey genesisSignKey
        , RegistryInit.dricSignTx = addKeyWitness genesisSignKey
        }

readShelleyGenesisConfig :: FilePath -> IO ShelleyGenesisConfig
readShelleyGenesisConfig gDir = do
    decoded <-
        eitherDecodeFileStrict
            (gDir </> "shelley-genesis.json")
    case decoded of
        Left err ->
            failWith $
                "decode shelley-genesis.json for API smoke stability \
                \threshold: "
                    <> err
        Right cfg -> pure cfg

waitForPreIndexerStability
    :: Provider IO -> Word -> IO PreIndexerStabilityProof
waitForPreIndexerStability provider threshold =
    go (480 :: Int) Set.empty
  where
    go attempts observedPoints = do
        snapshot <- queryLedgerSnapshot provider
        let SlotNo tipWord64 = ledgerTipSlot snapshot
            tip = fromIntegral tipWord64
            pointKey = show (ledgerChainPoint snapshot)
            observedPoints'
                | tipWord64 == 0 = observedPoints
                | otherwise = Set.insert pointKey observedPoints
            observedBlocks = fromIntegral (Set.size observedPoints')
        if observedBlocks > threshold
            then do
                putStrLn $
                    "pre-indexer stability wait: \
                    \derivedThresholdSlots="
                        <> show threshold
                        <> " observedDistinctForgedBlocks="
                        <> show observedBlocks
                        <> " observedTipSlot="
                        <> show tip
                        <> " withApiIndexerStartsAfterWait=true"
                pure
                    PreIndexerStabilityProof
                        { pispDerivedThresholdSlots = threshold
                        , pispObservedForgedBlocks = observedBlocks
                        , pispObservedTipSlot = tip
                        , pispWaitCompletedBeforeIndexerStart = True
                        }
            else
                if attempts <= 0
                    then
                        failWith $
                            "timed out before starting withApiIndexer: \
                            \observed "
                                <> show observedBlocks
                                <> " distinct post-wait-start forged \
                                   \blocks at tip slot "
                                <> show tip
                                <> ", not more than derived security \
                                   \parameter block threshold "
                                <> show threshold
                    else do
                        threadDelay 500_000
                        go (attempts - 1) observedPoints'

devnetMetadataFromRegistry
    :: DevnetRegistryPublication -> TreasuryMetadata
devnetMetadataFromRegistry publication =
    TreasuryMetadata
        { tmScopeOwners = txInToText (draScopesRef registry)
        , tmTreasuries =
            Map.singleton
                CoreDevelopment
                ScopeMetadata
                    { smOwner = Just (draOwnerKeyHash registry)
                    , smBudget = Nothing
                    , smAddress = renderAddr (ttAddress target)
                    , smTreasury =
                        ScriptRef
                            { srHash = ttScriptHashText target
                            , srDeployedAt =
                                txInToText (draTreasuryRef registry)
                            }
                    , smPermissions =
                        ScriptRef
                            { srHash =
                                scriptHashToHex
                                    (draPermissionsHash registry)
                            , srDeployedAt =
                                txInToText (draPermissionsRef registry)
                            }
                    , smRegistry =
                        ScriptRef
                            { srHash = draRegistryPolicyId registry
                            , srDeployedAt =
                                txInToText (draRegistryRef registry)
                            }
                    }
        }
  where
    registry =
        drpAnchors publication
    target =
        draTreasuryTarget registry

writeSmokeMetadata :: FilePath -> TreasuryMetadata -> IO ()
writeSmokeMetadata path metadata =
    case Map.lookup CoreDevelopment (tmTreasuries metadata) of
        Nothing ->
            failWith "devnet smoke metadata missing core_development"
        Just scope ->
            LBS.writeFile
                path
                ( encode
                    ( object
                        [ "scope_owners" .= tmScopeOwners metadata
                        , "treasuries"
                            .= object
                                [ "core_development"
                                    .= object
                                        [ "owner" .= smOwner scope
                                        , "budget" .= smBudget scope
                                        , "address" .= smAddress scope
                                        , "treasury_script"
                                            .= scriptRefJson
                                                (smTreasury scope)
                                        , "permissions_script"
                                            .= scriptRefJson
                                                (smPermissions scope)
                                        , "registry_script"
                                            .= scriptRefJson
                                                (smRegistry scope)
                                        ]
                                ]
                        ]
                    )
                )
  where
    scriptRefJson ref =
        object
            [ "hash" .= srHash ref
            , "deployed_at" .= srDeployedAt ref
            ]

devnetDeploymentAnchor
    :: DevnetRegistryPublication -> DeploymentAnchor
devnetDeploymentAnchor publication =
    DeploymentAnchor $
        txInToOutref (draScopesRef (drpAnchors publication))

fundApiTreasuryUtxos
    :: Provider IO
    -> Submitter IO
    -> PParams ConwayEra
    -> TreasuryTarget
    -> [(TxIn, TxOut ConwayEra)]
    -> IO (TxId, ((TxIn, TxOut ConwayEra), (TxIn, TxOut ConwayEra)))
fundApiTreasuryUtxos provider submitter pp target utxos = do
    seed@(seedIn, _) <-
        selectLargestAdaUtxo "api treasury funding" utxos
    snapshot <- queryLedgerSnapshot provider
    let upperSlot =
            addSlots 20 (ledgerTipSlot snapshot)
        interpret :: InterpretIO NoCtx
        interpret =
            InterpretIO $ \case {}
        eval tx =
            fmap
                (Map.map (either (Left . show) Right))
                (evaluateTx provider tx)
        prog :: TxBuild NoCtx Void ()
        prog = do
            _ <- spend seedIn
            collateral seedIn
            _ <- payTo (ttAddress target) (lovelaceValue 40_000_000)
            _ <- payTo (ttAddress target) (lovelaceValue 20_000_000)
            validTo upperSlot
    txId <-
        buildSubmitAndWait
            "fund API treasury UTxOs"
            provider
            submitter
            pp
            interpret
            eval
            [seed]
            []
            genesisAddr
            prog
    found <- waitForTxIns provider [txOutRef txId 0, txOutRef txId 1] 60
    case found of
        [first, second] -> do
            assertTreasuryTxOut
                "api treasury funding #0"
                (ttAddress target)
                40_000_000
                first
            assertTreasuryTxOut
                "api treasury funding #1"
                (ttAddress target)
                20_000_000
                second
            pure (txId, (first, second))
        _ ->
            failWith "api treasury funding outputs were not found"

postBuildDisburseAndSubmit
    :: Manager
    -> Int
    -> Submitter IO
    -> FilePath
    -> DevnetRegistryAnchors
    -> IO TxId
postBuildDisburseAndSubmit manager port submitter metadataPath _anchors = do
    res <-
        postJson
            manager
            port
            "/v1/build/disburse"
            DisburseBuildRequest
                { dbrScope = CoreDevelopment
                , dbrWalletAddr = renderAddr genesisAddr
                , dbrBeneficiaryAddr = renderAddr genesisAddr
                , dbrMetadataPath = metadataPath
                , dbrUnit = "ada"
                , dbrAmount = 5
                , dbrValidityHours = Nothing
                , dbrDescription = "Devnet API smoke disburse"
                , dbrJustification = "HTTP POST build smoke"
                , dbrDestinationLabel = "devnet-beneficiary"
                , dbrEvent = Nothing
                , dbrLabel = Just "api-smoke-disburse"
                , dbrSigners = []
                , dbrReferences = []
                }
    statusCode (responseStatus res) `shouldBe` 200
    response <-
        decodePostResponse
            "POST /v1/build/disburse"
            (responseBody res)
    cborHex <-
        case ( dbrFailureTag response
             , dbrBuildFailureTag response
             , dbrCborHex response
             ) of
            (Nothing, Nothing, Just cborHex) -> pure cborHex
            _ ->
                failWith $
                    "POST /v1/build/disburse did not return a successful \
                    \unsigned tx: "
                        <> show response
    submitUnsignedTxHex "POST /v1/build/disburse" submitter cborHex

postBuildReorganizeAndSubmit
    :: Manager
    -> Int
    -> Submitter IO
    -> FilePath
    -> IO TxId
postBuildReorganizeAndSubmit manager port submitter metadataPath = do
    res <-
        postJson
            manager
            port
            "/v1/build/reorganize"
            ReorganizeBuildRequest
                { rbrScope = CoreDevelopment
                , rbrWalletAddr = renderAddr genesisAddr
                , rbrMetadataPath = metadataPath
                , rbrValidityHours = Nothing
                , rbrDescription = Just "Devnet API smoke reorganize"
                , rbrJustification = Just "HTTP POST build smoke"
                , rbrDestinationLabel = Just "devnet-treasury"
                , rbrEvent = Nothing
                , rbrLabel = Just "api-smoke-reorganize"
                , rbrSplitNativeAssets = Just False
                }
    statusCode (responseStatus res) `shouldBe` 200
    response <-
        decodePostResponse
            "POST /v1/build/reorganize"
            (responseBody res)
    cborHex <-
        case ( rbrFailureTag response
             , rbrBuildFailureTag response
             , rbrCborHex response
             ) of
            (Nothing, Nothing, Just cborHex) -> pure cborHex
            _ ->
                failWith $
                    "POST /v1/build/reorganize did not return a \
                    \successful unsigned tx: "
                        <> show response
    submitUnsignedTxHex "POST /v1/build/reorganize" submitter cborHex

postJson
    :: (Aeson.ToJSON a)
    => Manager
    -> Int
    -> String
    -> a
    -> IO (Response LBS.ByteString)
postJson manager port path body = do
    req0 <-
        parseRequest $
            "http://127.0.0.1:" <> show port <> path
    let req =
            req0
                { method = "POST"
                , requestBody = RequestBodyLBS (encode body)
                , requestHeaders =
                    [("Content-Type", "application/json")]
                }
    httpLbs req manager

decodePostResponse
    :: (Aeson.FromJSON a)
    => String
    -> LBS.ByteString
    -> IO a
decodePostResponse label body =
    case Aeson.eitherDecode body of
        Right value -> pure value
        Left err ->
            failWith $
                label <> " response JSON decode failed: " <> err

submitUnsignedTxHex :: String -> Submitter IO -> Text -> IO TxId
submitUnsignedTxHex label submitter cborHex =
    case decodeUnsignedTxHex (TE.encodeUtf8 cborHex) of
        Left err ->
            failWith $
                label <> " decode unsigned tx failed: " <> show err
        Right tx -> do
            let signed =
                    addCardanoCliPaymentKeyWitness genesisSignKey tx
            submitTx submitter signed >>= \case
                Submitted _ -> pure (txIdTx signed)
                Rejected reason ->
                    failWith $
                        label <> " rejected: " <> show reason

awaitIndexedTxOut
    :: ApiIndexer cf op
    -> String
    -> Addr
    -> TxIn
    -> (TxOut ConwayEra -> Either String ())
    -> IO (TxOut ConwayEra)
awaitIndexedTxOut apiIdx label addr ref check =
    go (120 :: Int)
  where
    go attempts = do
        utxos <- snapshotUtxosAt apiIdx addr
        case Map.lookup ref (Map.fromList utxos) of
            Just txOut ->
                case check txOut of
                    Right () -> pure txOut
                    Left err ->
                        failWith $
                            label
                                <> " indexed unexpected TxOut at "
                                <> T.unpack (txInToText ref)
                                <> ": "
                                <> err
            Nothing ->
                if attempts <= 0
                    then
                        failWith $
                            label
                                <> " not observed by embedded indexer at "
                                <> T.unpack (txInToText ref)
                    else do
                        threadDelay 500_000
                        go (attempts - 1)

{- | Poll the embedded tx-history store (the same RocksDB the live
follower writes through 'aiHistory') for @core_development@ until a
rendered @slot txid role direction=...@ row is present for every
required @(submitted txid, role, direction)@ tuple, then return all
rendered rows.

The match is on the S4 'renderHistoryRows' output: each required row
must render as exactly four whitespace-separated fields — a decimal
slot, the lower-hex submitted tx id, the expected role, and the expected
direction. Older rows (e.g. @mint-registry@ from registry publication)
are tolerated.
-}
awaitHistoryRows
    :: ApiIndexer cf op
    -> [(TxId, Text, Text)]
    -> IO [Text]
awaitHistoryRows apiIdx required =
    go (120 :: Int)
  where
    go attempts = do
        entries <-
            queryScopeHistory (aiHistory apiIdx) CoreDevelopment
        let rows = renderHistoryRows entries
        case missingRows rows of
            [] -> pure rows
            missing
                | attempts <= 0 ->
                    failWith $
                        "embedded indexer did not observe treasury \
                        \history rows for the submitted txs under \
                        \core_development; missing (txid, role, direction): "
                            <> show missing
                            <> "; observed rows: "
                            <> show rows
                | otherwise -> do
                    threadDelay 500_000
                    go (attempts - 1)
    missingRows rows =
        [ (expectedTxId, role, direction)
        | (txid, role, direction) <- required
        , let expectedTxId = txIdHex txid
        , not (any (rowMatches expectedTxId role direction) rows)
        ]
    rowMatches expectedTxId expectedRole expectedDirection row =
        case T.words row of
            [slotW, txIdW, roleW, directionW] ->
                not (T.null slotW)
                    && T.all isDigit slotW
                    && txIdW == expectedTxId
                    && roleW == expectedRole
                    && directionW == "direction=" <> expectedDirection
            _ -> False

{- | Poll direct tx-id detail lookup for the submitted devnet disburse
and assert the rendered view carries the transaction id, role, scope,
fee/signers/redeemer, block hash, pure decoder input shape, and the two
outputs built by the API request.
-}
awaitDisburseTxDetail
    :: ApiIndexer cf op
    -> TxId
    -> Addr
    -> Addr
    -> IO [Text]
awaitDisburseTxDetail apiIdx txid treasuryAddr beneficiaryAddr =
    go (120 :: Int)
  where
    expectedTxId = txIdHex txid
    treasuryAddress = renderAddr treasuryAddr
    beneficiaryAddress = renderAddr beneficiaryAddr
    checks :: [(String, Text -> Bool)]
    checks =
        [
            ( "txid"
            , (== "txid " <> expectedTxId)
            )
        , ("scope", (== "scope core_development"))
        , ("role", (== "role disburse"))
        , ("direction", (== "direction outbound"))
        ,
            ( "slot"
            , \row ->
                case T.words row of
                    ["slot", n] -> not (T.null n) && T.all isDigit n
                    _ -> False
            )
        ,
            ( "block hash"
            , \row ->
                T.isPrefixOf "block-hash " row
                    && row /= "block-hash -"
            )
        ,
            ( "fee"
            , \row ->
                T.isPrefixOf "fee " row
                    && row /= "fee -"
            )
        ,
            ( "required signers"
            , \row ->
                T.isPrefixOf "required-signers " row
                    && row /= "required-signers -"
            )
        ,
            ( "redeemer scope/role"
            , \row ->
                T.isPrefixOf "redeemer " row
                    && "scope=core_development" `T.isInfixOf` row
                    && "role=disburse" `T.isInfixOf` row
            )
        ,
            ( "unknown input value"
            , \row ->
                T.isPrefixOf "input " row
                    && "value=unknown" `T.isInfixOf` row
            )
        ,
            ( "treasury continuation output"
            , \row ->
                T.isPrefixOf "output " row
                    && ("address=" <> treasuryAddress) `T.isInfixOf` row
                    && "35000000" `T.isInfixOf` row
            )
        ,
            ( "beneficiary output"
            , \row ->
                T.isPrefixOf "output " row
                    && ("address=" <> beneficiaryAddress) `T.isInfixOf` row
                    && "5000000" `T.isInfixOf` row
            )
        ]

    go attempts = do
        mSummary <-
            queryTxDetail
                (aiHistory apiIdx)
                (History.TxId (txIdBytes txid))
        case mSummary of
            Just summary -> do
                let rows = renderTxDetail summary
                    missing =
                        [ label
                        | (label, predicate) <- checks
                        , not (any predicate rows)
                        ]
                case missing of
                    [] -> pure rows
                    _
                        | attempts <= 0 ->
                            failWith $
                                "embedded indexer tx-detail for disburse "
                                    <> T.unpack expectedTxId
                                    <> " missed fields: "
                                    <> show missing
                                    <> "; rendered rows: "
                                    <> show rows
                        | otherwise -> retry (attempts - 1)
            Nothing
                | attempts <= 0 ->
                    failWith $
                        "embedded indexer did not expose tx-detail for \
                        \disburse tx "
                            <> T.unpack expectedTxId
                | otherwise -> retry (attempts - 1)

    retry attempts = do
        threadDelay 500_000
        go attempts

{- | Lower-hex of a ledger 'TxId' — the raw 32 tx-id bytes the
history decoder echoes into @tskTxId@ and 'renderHistoryRows'
base16-encodes.
-}
txIdHex :: TxId -> Text
txIdHex =
    TE.decodeUtf8 . B16.encode . txIdBytes

txIdBytes :: TxId -> ByteString
txIdBytes (TxId safeHash) =
    hashToBytes (extractHash safeHash)

assertInspectTreasuryState
    :: Manager -> Int -> String -> Int -> Integer -> IO ()
assertInspectTreasuryState manager port label expectedCount expectedLovelace = do
    res <- getInspect manager port
    statusCode (responseStatus res) `shouldBe` 200
    case Aeson.decode (responseBody res) of
        Just (Aeson.Object root) -> do
            scopes <- case KM.lookup "scopes" root of
                Just (Aeson.Array xs) -> pure xs
                other ->
                    failWith $
                        label
                            <> ": inspect response lacks scopes array: "
                            <> show other
            case toList scopes of
                [Aeson.Object scope] -> do
                    treasuryUtxos <- case KM.lookup "treasuryUtxos" scope of
                        Just (Aeson.Array xs) -> pure xs
                        other ->
                            failWith $
                                label
                                    <> ": inspect scope lacks treasuryUtxos: "
                                    <> show other
                    length treasuryUtxos `shouldBe` expectedCount
                    case KM.lookup "totals" scope of
                        Just (Aeson.Object totals) ->
                            KM.lookup "lovelace" totals
                                `shouldBe` Just
                                    ( Aeson.Number
                                        (fromInteger expectedLovelace)
                                    )
                        other ->
                            failWith $
                                label
                                    <> ": inspect scope lacks totals: "
                                    <> show other
                other ->
                    failWith $
                        label
                            <> ": expected one core_development scope, got "
                            <> show other
        other ->
            failWith $
                label
                    <> ": inspect response is not a JSON object: "
                    <> show other

assertPureAdaTxOut :: Integer -> TxOut ConwayEra -> Either String ()
assertPureAdaTxOut expectedLovelace txOut
    | txOutLovelace txOut /= expectedLovelace =
        Left $
            "lovelace="
                <> show (txOutLovelace txOut)
                <> " expected="
                <> show expectedLovelace
    | txOutHasAssets txOut =
        Left "expected pure ADA output, found native assets"
    | otherwise =
        Right ()

assertTreasuryTxOut
    :: String -> Addr -> Integer -> (TxIn, TxOut ConwayEra) -> IO ()
assertTreasuryTxOut label expectedAddr expectedLovelace (_, txOut) = do
    txOut ^. addrTxOutL `shouldBe` expectedAddr
    case assertPureAdaTxOut expectedLovelace txOut of
        Right () -> pure ()
        Left err -> failWith (label <> ": " <> err)

buildSubmitAndWait
    :: String
    -> Provider IO
    -> Submitter IO
    -> PParams ConwayEra
    -> InterpretIO NoCtx
    -> ( ConwayTx
         -> IO
                ( Map.Map
                    (ConwayPlutusPurpose AsIx ConwayEra)
                    (Either String ExUnits)
                )
       )
    -> [(TxIn, TxOut ConwayEra)]
    -> [(TxIn, TxOut ConwayEra)]
    -> Addr
    -> TxBuild NoCtx Void ()
    -> IO TxId
buildSubmitAndWait
    label
    provider
    submitter
    pp
    interpret
    eval
    inputs
    refs
    changeAddr
    prog =
        build
            (mkPParamsBound pp)
            interpret
            eval
            inputs
            refs
            changeAddr
            prog
            >>= \case
                Left err ->
                    failWith (label <> ": " <> show err)
                Right tx -> do
                    let signed = addKeyWitness genesisSignKey tx
                        txId = txIdTx signed
                    submitTx submitter signed >>= \case
                        Submitted _ -> pure ()
                        Rejected reason ->
                            failWith $
                                label <> " rejected: " <> show reason
                    waitForTxChange provider txId genesisAddr 60
                    pure txId

waitForTxChange :: Provider IO -> TxId -> Addr -> Int -> IO ()
waitForTxChange _ txId _ attempts
    | attempts <= 0 =
        failWith $
            "timed out waiting for tx change output: "
                <> show txId
waitForTxChange provider txId addr attempts = do
    utxos <- queryUTxOs provider addr
    if any (hasTxId txId . fst) utxos
        then pure ()
        else do
            threadDelay 500_000
            waitForTxChange provider txId addr (attempts - 1)

waitForTxIns
    :: Provider IO
    -> [TxIn]
    -> Int
    -> IO [(TxIn, TxOut ConwayEra)]
waitForTxIns _ refs attempts
    | attempts <= 0 =
        failWith $
            "timed out waiting for UTxOs: "
                <> show (txInToText <$> refs)
waitForTxIns provider refs attempts = do
    found <- queryUTxOByTxIn provider (Set.fromList refs)
    if all (`Map.member` found) refs
        then
            pure
                [ (ref, found Map.! ref)
                | ref <- refs
                ]
        else do
            threadDelay 500_000
            waitForTxIns provider refs (attempts - 1)

selectLargestAdaUtxo
    :: String
    -> [(TxIn, TxOut ConwayEra)]
    -> IO (TxIn, TxOut ConwayEra)
selectLargestAdaUtxo label utxos =
    case foldr choose Nothing utxos of
        Just (_, selected) -> pure selected
        Nothing -> failWith ("no pure-ADA UTxO for " <> label)
  where
    choose utxo@(_, txOut) best =
        let MaryValue (Coin lovelace) (MultiAsset assets) =
                txOut ^. valueTxOutL
        in  if Map.null assets
                then case best of
                    Nothing -> Just (lovelace, utxo)
                    Just (bestLovelace, _)
                        | lovelace > bestLovelace ->
                            Just (lovelace, utxo)
                    _ -> best
                else best

txOutRef :: TxId -> Integer -> TxIn
txOutRef txId ix =
    TxIn txId (mkTxIxPartial ix)

txInToOutref :: TxIn -> Outref
txInToOutref txIn =
    case parseOutrefText (txInToText txIn) of
        Just outref -> outref
        Nothing ->
            error
                "IndexerSmokeSpec.txInToOutref: txInToText did not \
                \render txid#ix"

hasTxId :: TxId -> TxIn -> Bool
hasTxId txId (TxIn utxoTxId _) =
    txId == utxoTxId

addSlots :: Word64 -> SlotNo -> SlotNo
addSlots delta (SlotNo slot) =
    SlotNo (slot + delta)

lovelaceValue :: Integer -> MaryValue
lovelaceValue lovelace =
    MaryValue (Coin lovelace) (MultiAsset Map.empty)

txOutLovelace :: TxOut ConwayEra -> Integer
txOutLovelace txOut =
    vsLovelace (valueSummary (txOut ^. valueTxOutL))

txOutHasAssets :: TxOut ConwayEra -> Bool
txOutHasAssets txOut =
    let ValueSummary{vsAssets} =
            valueSummary (txOut ^. valueTxOutL)
    in  not (Map.null vsAssets)

paymentKeyHashFromSignKey
    :: SignKeyDSIGN Ed25519DSIGN
    -> KeyHash Payment
paymentKeyHashFromSignKey =
    hashKey
        . VKey
        . deriveVerKeyDSIGN

renderAddr :: Addr -> T.Text
renderAddr addr =
    Bech32.encodeLenient
        hrp
        (Bech32.dataPartFromBytes (serialiseAddr addr))
  where
    hrp =
        either
            (error . ("renderAddr: " <>) . show)
            id
            (Bech32.humanReadablePartFromText (addressHrp addr))
    addressHrp target =
        case getNetwork target of
            Mainnet -> "addr"
            Testnet -> "addr_test"

writeGenesisPaymentSigningKey :: FilePath -> IO FilePath
writeGenesisPaymentSigningKey runDir = do
    let path = runDir </> "registry-init-funding.skey"
    BSL.writeFile
        path
        ( encode
            ( object
                [ "type"
                    .= ( "PaymentSigningKeyShelley_ed25519"
                            :: T.Text
                       )
                , "description" .= ("Payment Signing Key" :: T.Text)
                , "cborHex"
                    .= TE.decodeUtf8
                        ( "5820"
                            <> B16.encode
                                ( rawSerialiseSignKeyDSIGN
                                    genesisSignKey
                                )
                        )
                ]
            )
        )
    setFileMode path ownerReadMode
    pure path

getInspect
    :: Manager -> Int -> IO (Response LBS.ByteString)
getInspect manager port = do
    req <-
        parseRequest $
            "http://127.0.0.1:"
                <> show port
                <> "/v1/treasury-inspect?scope=core_development"
    httpLbs req manager

smokeIndexerConfig
    :: FilePath
    -> FilePath
    -> InterestSet
    -> Int
    -> [(ByteString, ScopeId)]
    -> [(ByteString, ScopeId)]
    -> IndexerConfig
smokeIndexerConfig
    dir
    nodeSock
    interestSet
    securityParamK
    registryScopeMappings
    scopeAddressMappings =
        IndexerConfig
            { icDbPath = dir <> "/rocksdb"
            , icSocketPath = nodeSock
            , icNetworkMagic = devnetMagic
            , icStartPoint = Nothing
            , icLagThresholdSlots = 60
            , icByronEpochSlots = 86_400
            , icSecurityParamK = securityParamK
            , icReconnectPolicy = defaultReconnectPolicy
            , icProbeConfig = defaultProbeConfig
            , icInterestSet = interestSet
            , icRegistryScopeMappings = registryScopeMappings
            , icScopeAddressMappings = scopeAddressMappings
            }

smokeHandlers
    :: ApiIndexer cf op
    -> Provider IO
    -> GlobalOpts
    -> TreasuryMetadata
    -> DeploymentAnchor
    -> Addr
    -> Handlers
smokeHandlers apiIdx backend globalOpts metadata anchor swapAddr =
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
        , hTxDetail = queryTxDetailResponse (aiHistory apiIdx)
        , hRegistry = pure (registryResponseFromMetadata metadata)
        , hScripts = pure (scriptsResponseFromMetadata metadata)
        , hPending =
            queryPending
                readProvider
                metadata
                swapAddr
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
        , hScopeHistory = queryScopeHistoryFilteredResponse (aiHistory apiIdx)
        , hScopeHistoryQuery =
            queryScopeHistoryQueryResponse (aiHistory apiIdx)
        , hScopeHistoryShacl =
            queryScopeHistoryShaclResponse (aiHistory apiIdx)
        , hBuildSwap = bhBuildSwap buildHandlers
        , hBuildDisburse = bhBuildDisburse buildHandlers
        , hBuildReorganize = bhBuildReorganize buildHandlers
        , hRawHandler =
            Tagged $ \_req respond ->
                respond $
                    responseLBS
                        status404
                        [("Content-Type", "text/plain")]
                        "smoke: raw not served"
        }
  where
    buildHandlers =
        mkBuildHandlers
            apiIdx
            backend
            (runBuildSwap globalOpts)
            (runBuildDisburse globalOpts)
            (runBuildReorganize globalOpts)
    readProvider = mkBuildProvider apiIdx backend

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
