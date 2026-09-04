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
import Control.Concurrent (threadDelay)
import Control.Exception (try)
import Data.ByteString qualified as B
import Data.List.NonEmpty (NonEmpty (..))
import Data.Set qualified as Set
import Ouroboros.Network.Magic (NetworkMagic (..))
import System.IO.Temp (withSystemTempDirectory)
import System.Timeout (timeout)
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
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
import Amaru.Treasury.Api.Server (mkBuildProvider)
import Amaru.Treasury.Backend (Provider (..))
import Amaru.Treasury.Cli.Common
    ( AcquireTimeout
    , acquireTimeoutSeconds
    )
import Amaru.Treasury.Cli.History (queryScopeHistory)
import Amaru.Treasury.Scope (ScopeId (CoreDevelopment))
import Amaru.Treasury.Trace (Severity (Error))

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
                        , icScopeAddressMappings = []
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
                            , icScopeAddressMappings = []
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
                , icScopeAddressMappings = []
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
                            , icScopeAddressMappings = []
                            }
            csStartPoint chainSyncCfg
                `shouldBe` Just (SlotNo 123, startHash)

    -- ---------------------------------------------------------------------------
    -- Helpers

    describe "mkBuildProvider"
        $ it
            "bounds withAcquired instead of hanging when the \
            \live provider never yields a handle (#504)"
        $ withTmpIndexer
        $ \idx -> do
            let bounded = mkBuildProvider Error idx hangingProvider
            outcome <-
                timeout
                    ((acquireTimeoutSeconds + 5) * 1_000_000)
                    ( try @AcquireTimeout
                        (withAcquired bounded (\_ -> pure ()))
                    )
            case outcome of
                Nothing ->
                    expectationFailure
                        "withAcquired did not return within \
                        \acquireTimeoutSeconds + 5s margin"
                Just (Right ()) ->
                    expectationFailure
                        "expected AcquireTimeout, but the acquire \
                        \succeeded against a provider that never \
                        \yields a handle"
                Just (Left _) -> pure ()

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
                , icScopeAddressMappings = []
                }
            action

{- | A live provider whose acquire never returns, standing in
for the jammed N2C session behind #481 and #504.
-}
hangingProvider :: Provider IO
hangingProvider =
    Provider
        { withAcquired = \_ -> threadDelay maxBound >> error "unreachable"
        , queryUTxOs = \_ -> fail "unused queryUTxOs"
        , queryUTxOByTxIn = \_ -> fail "unused queryUTxOByTxIn"
        , queryProtocolParams = fail "unused queryProtocolParams"
        , queryLedgerSnapshot = fail "unused queryLedgerSnapshot"
        , queryStakeRewards = \_ -> fail "unused queryStakeRewards"
        , queryRewardAccounts = \_ -> fail "unused queryRewardAccounts"
        , queryVoteDelegatees = \_ -> fail "unused queryVoteDelegatees"
        , queryTreasury = fail "unused queryTreasury"
        , queryGovernanceState = fail "unused queryGovernanceState"
        , evaluateTx = \_ -> fail "unused evaluateTx"
        , posixMsToSlot = \_ -> fail "unused posixMsToSlot"
        , posixMsCeilSlot = \_ -> fail "unused posixMsCeilSlot"
        , queryUpperBoundSlot = \_ -> fail "unused queryUpperBoundSlot"
        }
