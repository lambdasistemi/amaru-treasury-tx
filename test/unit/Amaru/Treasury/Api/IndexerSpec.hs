{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Api.IndexerSpec
Description : Unit tests for the API in-process indexer
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Exercises 'Amaru.Treasury.Api.Indexer' against a tmpfs
RocksDB store. There is no chain-sync follower wired in
Slice 1, so the follower-equivalent path is driven
directly: tests call 'Indexer.applyAtSlot' on the
exposed 'aiHandle' to inject UTxOs, and
'setReadinessForTest' to flip the readiness 'TVar' so
'checkReady' and 'waitReady' see the state Slice 3 will
eventually publish from the real chain-sync follower.

Covers the six readiness + snapshot scenarios from the
slice brief:

1. open + close round-trip of 'withApiIndexer',
2. cold-start 'checkReady' returns 'Pending',
3. 'Ready' verdict once @processed_slot == tip_slot@,
4. 'Lagging' verdict once lag exceeds the configured
   threshold,
5. 'snapshotAt' round-trip across one
   'UtxoCreate' + 'UtxoSpend',
6. 'waitReady' blocks while 'Pending' and unblocks once
   the 'TVar' transitions to 'Ready'.
-}
module Amaru.Treasury.Api.IndexerSpec (spec) where

import Cardano.Node.Client.N2C.Trace (nullN2CTracer)
import Cardano.Node.Client.UTxOIndexer.Indexer qualified as Indexer
import Cardano.Node.Client.UTxOIndexer.IndexerOp (UtxoOp (..))
import Cardano.Node.Client.UTxOIndexer.Types
    ( Address (..)
    , BlockHash (..)
    , SlotNo (..)
    , TxIn (..)
    , TxOut (..)
    )
import Control.Concurrent.Async qualified as Async
import Data.ByteString qualified as B
import Data.Time.Clock (getCurrentTime)
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
    , Readiness (..)
    , ReadyState (..)
    , checkReady
    , waitReady
    , withApiIndexer
    )
import Amaru.Treasury.Api.Indexer qualified as ApiIdx
import Amaru.Treasury.Api.Indexer.Internal
    ( setReadinessForTest
    )

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

    describe "checkReady" $ do
        it "is Pending on a freshly-opened indexer" $
            withTmpIndexer $ \apiIdx -> do
                rs <- checkReady apiIdx
                rs `shouldBe` Pending

        it "is Ready when processed_slot has reached tip" $
            withTmpIndexer $ \apiIdx -> do
                now <- getCurrentTime
                setReadinessForTest apiIdx $
                    Readiness
                        { rProcessedSlot = SlotNo 100
                        , rTipSlot = SlotNo 100
                        , rLagSlots = 0
                        , rUpstreamUp = True
                        , rUpdatedAt = now
                        }
                rs <- checkReady apiIdx
                rs `shouldBe` Ready

        it
            "is Lagging when lag_slots exceeds the\
            \ configured threshold"
            $ withTmpIndexer
            $ \apiIdx -> do
                now <- getCurrentTime
                setReadinessForTest apiIdx $
                    Readiness
                        { rProcessedSlot = SlotNo 100
                        , rTipSlot = SlotNo 300
                        , rLagSlots = 200
                        , rUpstreamUp = True
                        , rUpdatedAt = now
                        }
                rs <- checkReady apiIdx
                rs `shouldBe` Lagging 200 60

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

    describe "waitReady"
        $ it
            "blocks while Pending and unblocks once\
            \ Ready"
        $ withTmpIndexer
        $ \apiIdx ->
            Async.withAsync (waitReady apiIdx) $ \a -> do
                early <-
                    timeout
                        200_000
                        (Async.waitCatch a)
                case early of
                    Nothing -> pure ()
                    Just (Right ()) ->
                        expectationFailure
                            "waitReady returned while still\
                            \ Pending"
                    Just (Left e) ->
                        expectationFailure $
                            "waitReady threw while Pending: "
                                <> show e
                now <- getCurrentTime
                setReadinessForTest apiIdx $
                    Readiness
                        { rProcessedSlot = SlotNo 50
                        , rTipSlot = SlotNo 50
                        , rLagSlots = 0
                        , rUpstreamUp = True
                        , rUpdatedAt = now
                        }
                late <-
                    timeout
                        1_000_000
                        (Async.waitCatch a)
                case late of
                    Just (Right ()) -> pure ()
                    Just (Left e) ->
                        expectationFailure $
                            "waitReady threw after readiness\
                            \ flip: "
                                <> show e
                    Nothing ->
                        expectationFailure
                            "waitReady did not finish within\
                            \ 1 s of the readiness flip"

-- ---------------------------------------------------------------------------
-- Helpers

{- | Run the action against a freshly-opened 'ApiIndexer'
backed by a per-test tmpfs RocksDB. The temporary
directory is removed recursively when the action
returns or throws.
-}
withTmpIndexer :: (ApiIndexer -> IO a) -> IO a
withTmpIndexer action =
    withSystemTempDirectory "amaru-api-indexer-test" $ \dir ->
        withApiIndexer
            nullN2CTracer
            IndexerConfig
                { icDbPath = dir
                , icSocketPath = "/dev/null"
                , icNetworkMagic = NetworkMagic 42
                , icStartSlot = SlotNo 0
                , icLagThresholdSlots = 60
                }
            action
