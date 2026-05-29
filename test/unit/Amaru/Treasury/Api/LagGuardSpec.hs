{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Api.LagGuardSpec
Description : Unit tests for API indexer lag guard
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0
-}
module Amaru.Treasury.Api.LagGuardSpec (spec) where

import Cardano.Node.Client.UTxOIndexer.Types (SlotNo (..))
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async qualified as Async
import Control.Concurrent.STM (newTVarIO)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as LBS
import Data.Time.Clock (UTCTime, getCurrentTime)
import Network.HTTP.Types (status404, status503)
import Network.Wai (Application, responseLBS)
import Network.Wai.Test (runSession)
import Network.Wai.Test qualified as WaiTest
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    )

import Amaru.Treasury.Api.LagGuard
    ( withLagGuard
    )
import Amaru.Treasury.Api.Readiness
    ( Readiness (..)
    , ReadinessHandle (..)
    )

spec :: Spec
spec = describe "Amaru.Treasury.Api.LagGuard" $ do
    describe "withLagGuard" $ do
        it "passes through when readiness is not Lagging" $ do
            now <- getCurrentTime
            withReadiness (readyState now) $ \readiness -> do
                resp <-
                    runSession
                        (WaiTest.srequest (waiGet "/v1/version"))
                        (withLagGuard readiness underlying404)
                WaiTest.simpleStatus resp `shouldBe` status404
                WaiTest.simpleBody resp `shouldBe` "underlying"

        it
            "short-circuits every request with HTTP 503 +\
            \ structured JSON body when checkReady is\
            \ Lagging"
            $ do
                now <- getCurrentTime
                withReadiness (laggingState now) $ \readiness -> do
                    resp <-
                        runSession
                            (WaiTest.srequest (waiGet "/v1/version"))
                            (withLagGuard readiness underlyingNotCalled)
                    WaiTest.simpleStatus resp
                        `shouldBe` status503
                    lookup
                        "Content-Type"
                        (WaiTest.simpleHeaders resp)
                        `shouldBe` Just
                            "application/json; charset=utf-8"
                    case Aeson.decode (WaiTest.simpleBody resp) of
                        Just (Aeson.Object o) -> do
                            KM.lookup "error" o
                                `shouldBe` Just
                                    ( Aeson.String
                                        "indexer_lagging"
                                    )
                            KM.lookup "processed_slot" o
                                `shouldBe` Just
                                    (Aeson.Number 100)
                            KM.lookup "tip_slot" o
                                `shouldBe` Just
                                    (Aeson.Number 300)
                            KM.lookup "lag_slots" o
                                `shouldBe` Just
                                    (Aeson.Number 200)
                            KM.lookup "threshold_slots" o
                                `shouldBe` Just
                                    (Aeson.Number 60)
                            KM.member "updated_at" o
                                `shouldBe` True
                        other ->
                            expectationFailure $
                                "expected JSON object, got: "
                                    <> show other

readyState :: UTCTime -> Readiness
readyState now =
    Readiness
        { rProcessedSlot = SlotNo 100
        , rTipSlot = SlotNo 100
        , rLagSlots = 0
        , rUpstreamUp = True
        , rUpdatedAt = now
        }

laggingState :: UTCTime -> Readiness
laggingState now =
    Readiness
        { rProcessedSlot = SlotNo 100
        , rTipSlot = SlotNo 300
        , rLagSlots = 200
        , rUpstreamUp = True
        , rUpdatedAt = now
        }

withReadiness :: Readiness -> (ReadinessHandle -> IO a) -> IO a
withReadiness r action = do
    tv <- newTVarIO r
    Async.withAsync (threadDelay maxBound) $ \bridge ->
        action
            ReadinessHandle
                { rhReadiness = tv
                , rhBridge = bridge
                , rhLagThresholdSlots = 60
                }

underlying404 :: Application
underlying404 _req respond =
    respond $
        responseLBS
            status404
            [("Content-Type", "text/plain")]
            "underlying"

underlyingNotCalled :: Application
underlyingNotCalled _req respond =
    respond $
        responseLBS
            status404
            [("Content-Type", "text/plain")]
            "underlying-not-called"

waiGet :: LBS.ByteString -> WaiTest.SRequest
waiGet path =
    WaiTest.SRequest
        ( WaiTest.setPath
            WaiTest.defaultRequest
            (LBS.toStrict path)
        )
        ""
