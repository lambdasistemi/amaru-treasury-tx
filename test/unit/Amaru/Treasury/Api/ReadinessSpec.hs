{-# LANGUAGE NumericUnderscores #-}

{- |
Module      : Amaru.Treasury.Api.ReadinessSpec
Description : Unit tests for API indexer readiness
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0
-}
module Amaru.Treasury.Api.ReadinessSpec (spec) where

import Cardano.Node.Client.N2C.Reconnect
    ( UpstreamStatus (..)
    )
import Cardano.Node.Client.UTxOIndexer.Follower qualified as Follower
import Cardano.Node.Client.UTxOIndexer.Types (SlotNo (..))
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async qualified as Async
import Control.Concurrent.STM
    ( TVar
    , atomically
    , newTVarIO
    , readTVar
    , readTVarIO
    , writeTVar
    )
import Data.Time.Clock
    ( UTCTime
    , addUTCTime
    , getCurrentTime
    )
import System.Timeout (timeout)
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    )

import Amaru.Treasury.Api.Readiness
    ( Readiness (..)
    , ReadinessHandle (..)
    , ReadyState (..)
    , checkReady
    , waitReady
    , withReadinessBridge
    )
import Amaru.Treasury.Api.Readiness.Internal
    ( setReadinessForTest
    )

spec :: Spec
spec = describe "Amaru.Treasury.Api.Readiness" $ do
    describe "checkReady" $ do
        it "is Pending before the follower has processed a slot" $
            withFakeFollower $ \_source _now readiness -> do
                rs <- checkReady readiness
                rs `shouldBe` Pending

        it "is Ready when processed_slot has reached tip" $
            withFakeFollower $ \source now readiness -> do
                writeFollower
                    source
                    (addUTCTime 1 now)
                    (Just (SlotNo 100))
                    (Just (SlotNo 100))
                    UpstreamConnected
                eventuallyReadyState readiness Ready

        it
            "is Lagging when lag_slots exceeds the\
            \ configured threshold"
            $ withFakeFollower
            $ \source now readiness -> do
                writeFollower
                    source
                    (addUTCTime 1 now)
                    (Just (SlotNo 100))
                    (Just (SlotNo 300))
                    UpstreamConnected
                eventuallyReadyState readiness (Lagging 200 60)

        it
            "clamps processed-ahead lag to zero and remains Ready"
            $ withFakeFollower
            $ \source now readiness -> do
                writeFollower
                    source
                    (addUTCTime 1 now)
                    (Just (SlotNo 300))
                    (Just (SlotNo 100))
                    UpstreamConnected
                eventuallyReadyState readiness Ready
                r <- readTVarIO (rhReadiness readiness)
                rLagSlots r `shouldBe` 0

    describe "waitReady"
        $ it
            "blocks while Pending and unblocks once\
            \ Ready"
        $ withFakeFollower
        $ \_source _now readiness ->
            Async.withAsync (waitReady readiness) $ \a -> do
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
                setReadinessForTest readiness $
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

withFakeFollower
    :: (TVar Follower.Readiness -> UTCTime -> ReadinessHandle -> IO a)
    -> IO a
withFakeFollower action = do
    now <- getCurrentTime
    source <-
        newTVarIO $
            followerReadiness
                now
                Nothing
                Nothing
                UpstreamConnected
    withReadinessBridge 60 (readTVar source) (action source now)

writeFollower
    :: TVar Follower.Readiness
    -> UTCTime
    -> Maybe SlotNo
    -> Maybe SlotNo
    -> UpstreamStatus
    -> IO ()
writeFollower source updatedAt processed tip upstream =
    atomically $
        writeTVar source $
            followerReadiness updatedAt processed tip upstream

followerReadiness
    :: UTCTime
    -> Maybe SlotNo
    -> Maybe SlotNo
    -> UpstreamStatus
    -> Follower.Readiness
followerReadiness updatedAt processed tip upstream =
    Follower.Readiness
        { Follower.rProcessedSlot = processed
        , Follower.rTipSlot = tip
        , Follower.rUpstream = upstream
        , Follower.rUpdatedAt = updatedAt
        }

eventuallyReadyState :: ReadinessHandle -> ReadyState -> IO ()
eventuallyReadyState readiness expected = go (20 :: Int)
  where
    go 0 = checkReady readiness >>= (`shouldBe` expected)
    go n = do
        actual <- checkReady readiness
        if actual == expected
            then pure ()
            else do
                threadDelay 50_000
                go (n - 1)
