{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- |
Module      : Amaru.Treasury.Api.IndexerSpec
Description : Unit tests for the API in-process indexer
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Exercises 'Amaru.Treasury.Api.Indexer' against a tmpfs
RocksDB store. The readiness state machine and lag guard
live in their own modules; this spec stays focused on
indexer bring-up, upstream chain-sync config projection,
and snapshot reads.
-}
module Amaru.Treasury.Api.IndexerSpec (spec) where

import Cardano.Node.Client.N2C.Probe (defaultProbeConfig)
import Cardano.Node.Client.N2C.Reconnect
    ( defaultReconnectPolicy
    )
import Cardano.Node.Client.N2C.Trace (nullN2CTracer)
import Cardano.Node.Client.UTxOIndexer.Follower
    ( ChainSyncConfig (..)
    , InterestSet (..)
    )
import Cardano.Node.Client.UTxOIndexer.Indexer qualified as Indexer
import Cardano.Node.Client.UTxOIndexer.IndexerOp (UtxoOp (..))
import Cardano.Node.Client.UTxOIndexer.Types
    ( Address (..)
    , BlockHash (..)
    , SlotNo (..)
    , TxIn (..)
    , TxOut (..)
    )
import Data.ByteString qualified as B
import Data.List.NonEmpty (NonEmpty (..))
import Data.Set qualified as Set
import Ouroboros.Network.Magic (NetworkMagic (..))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldSatisfy
    )

import Amaru.Treasury.Api.Indexer
    ( ApiIndexer (..)
    , IndexerConfig (..)
    , historyDbPath
    , toChainSyncCfg
    , withApiIndexer
    )
import Amaru.Treasury.Api.Indexer qualified as ApiIdx
import Amaru.Treasury.Cli.History (queryScopeHistory)
import Amaru.Treasury.Scope (ScopeId (CoreDevelopment))

spec :: Spec
spec = describe "Amaru.Treasury.Api.Indexer" $ do
    describe "withApiIndexer"
        $ it
            "opens a tmpfs RocksDB and round-trips\
            \ the config"
        $ withTmpIndexer
        $ \apiIdx ->
            icDbPath (aiConfig apiIdx)
                `shouldSatisfy` not . null

    describe "snapshotAt"
        $ it
            "round-trips a UtxoCreate then a\
            \ UtxoSpend at the same address"
        $ withTmpIndexer
        $ \apiIdx -> do
            let h = aiHandle apiIdx
                addr = Address "addr-bytes"
                txIn1 = TxIn (B.replicate 32 0xAA) 0
                txOut1 = TxOut "txout-1"
                blk1 = BlockHash (B.replicate 32 0x01)
                blk2 = BlockHash (B.replicate 32 0x02)
            Indexer.applyAtSlot
                h
                (SlotNo 10)
                blk1
                [UtxoCreate txIn1 addr txOut1]
            snap1 <- ApiIdx.snapshotAt apiIdx addr
            snap1 `shouldBe` [(txIn1, txOut1)]
            Indexer.applyAtSlot
                h
                (SlotNo 11)
                blk2
                [UtxoSpend txIn1]
            snap2 <- ApiIdx.snapshotAt apiIdx addr
            snap2 `shouldBe` []

    describe "toChainSyncCfg"
        $ it
            "threads icInterestSet through to the upstream\
            \ ChainSyncConfig (#158 plumbing)"
        $ do
            let addr = Address "addr-interest-set"
                cfg =
                    IndexerConfig
                        { icDbPath = "/tmp/unused"
                        , icSocketPath = "/tmp/unused.sock"
                        , icNetworkMagic = NetworkMagic 42
                        , icStartPoint = Nothing
                        , icLagThresholdSlots = 60
                        , icByronEpochSlots = 86_400
                        , icSecurityParamK = 2160
                        , icReconnectPolicy =
                            defaultReconnectPolicy
                        , icProbeConfig = defaultProbeConfig
                        , icInterestSet =
                            IndexAddressSet
                                (Set.singleton addr)
                        , icRegistryScopeMappings = []
                        }
            csInterestSet (toChainSyncCfg cfg)
                `shouldBe` IndexAddressSet
                    (Set.singleton addr)

    describe "toChainSyncCfg"
        $ it
            "registers the live UTxO handler through\
            \ ChainSyncConfig.csHandlers (#168 seam)"
        $ do
            let chainSyncCfg =
                    toChainSyncCfg
                        IndexerConfig
                            { icDbPath = "/tmp/unused"
                            , icSocketPath = "/tmp/unused.sock"
                            , icNetworkMagic = NetworkMagic 42
                            , icStartPoint = Nothing
                            , icLagThresholdSlots = 60
                            , icByronEpochSlots = 86_400
                            , icSecurityParamK = 2160
                            , icReconnectPolicy =
                                defaultReconnectPolicy
                            , icProbeConfig = defaultProbeConfig
                            , icInterestSet = IndexAll
                            , icRegistryScopeMappings = []
                            }
            case csHandlers chainSyncCfg of
                _ :| extraHandlers -> length extraHandlers `shouldBe` 0

    describe "historyDbPath"
        $ it
            "is a deterministic sibling of icDbPath"
        $ historyDbPath
            IndexerConfig
                { icDbPath = "/tmp/treasury-rocksdb"
                , icSocketPath = "/tmp/unused.sock"
                , icNetworkMagic = NetworkMagic 42
                , icStartPoint = Nothing
                , icLagThresholdSlots = 60
                , icByronEpochSlots = 86_400
                , icSecurityParamK = 2160
                , icReconnectPolicy = defaultReconnectPolicy
                , icProbeConfig = defaultProbeConfig
                , icInterestSet = IndexAll
                , icRegistryScopeMappings = []
                }
            `shouldBe` "/tmp/treasury-rocksdb-history"

    describe "withApiIndexer"
        $ it
            "exposes a history handle whose fresh store\
            \ has no rows for a scope"
        $ withTmpIndexer
        $ \apiIdx -> do
            rows <-
                queryScopeHistory
                    (aiHistory apiIdx)
                    CoreDevelopment
            length rows `shouldBe` 0

    describe "toChainSyncCfg"
        $ it
            "projects a configured start point into\
            \ ChainSyncConfig.csStartPoint"
        $ do
            let startHash = BlockHash (B.replicate 32 0xAB)
                chainSyncCfg =
                    toChainSyncCfg
                        IndexerConfig
                            { icDbPath = "/tmp/unused"
                            , icSocketPath = "/tmp/unused.sock"
                            , icNetworkMagic = NetworkMagic 42
                            , icStartPoint =
                                Just (SlotNo 123, startHash)
                            , icLagThresholdSlots = 60
                            , icByronEpochSlots = 86_400
                            , icSecurityParamK = 2160
                            , icReconnectPolicy =
                                defaultReconnectPolicy
                            , icProbeConfig = defaultProbeConfig
                            , icInterestSet = IndexAll
                            , icRegistryScopeMappings = []
                            }
            csStartPoint chainSyncCfg
                `shouldBe` Just (SlotNo 123, startHash)

-- ---------------------------------------------------------------------------
-- Helpers

{- | Run the action against a freshly-opened 'ApiIndexer'
backed by a per-test tmpfs RocksDB. The temporary
directory is removed recursively when the action
returns or throws.
-}
withTmpIndexer :: (forall cf op. ApiIndexer cf op -> IO a) -> IO a
withTmpIndexer action =
    withSystemTempDirectory "amaru-api-indexer-test" $ \dir ->
        withApiIndexer
            nullN2CTracer
            IndexerConfig
                { icDbPath = dir
                , icSocketPath = dir <> "/missing.sock"
                , icNetworkMagic = NetworkMagic 42
                , icStartPoint = Nothing
                , icLagThresholdSlots = 60
                , icByronEpochSlots = 86_400
                , icSecurityParamK = 2160
                , icReconnectPolicy = defaultReconnectPolicy
                , icProbeConfig = defaultProbeConfig
                , icInterestSet = IndexAll
                , icRegistryScopeMappings = []
                }
            action
