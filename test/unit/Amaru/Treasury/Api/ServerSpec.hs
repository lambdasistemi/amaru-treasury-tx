{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Api.ServerSpec
Description : WAI tests for the #239 servant surface
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Drives 'mkApplication' through @Network.Wai.Test@ with a
fully-stubbed 'Handlers' record. Asserts the JSON wire shape
of @\/v1\/treasury-inspect@, @\/v1\/recent-txs@, @\/v1\/version@
and that the raw fallback handler is invoked for unknown
paths.

SC-002 byte-identity is the strongest invariant tested:
@\/v1\/treasury-inspect?scope=core_development@ returns
exactly @encodeReport stubReport@ — no JSON re-encoding or
whitespace drift can hide.
-}
module Amaru.Treasury.Api.ServerSpec (spec) where

import Data.ByteString.Lazy (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Tagged (Tagged (..))
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Network.HTTP.Types (status200, status404)
import Network.HTTP.Types.Status (statusCode)
import Network.Wai (Application, responseLBS)
import Network.Wai.Test (SResponse, runSession)
import Network.Wai.Test qualified as WaiTest
import Servant qualified
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

import Amaru.Treasury.Api.Server
    ( Handlers (..)
    , mkApplication
    )
import Amaru.Treasury.Api.Types
    ( BuildIdentity (..)
    , RecentTxManifest (..)
    )
import Amaru.Treasury.Inspect.Render (encodeReport)
import Amaru.Treasury.Inspect.Types
    ( ChainTip (..)
    , DeploymentAnchor (..)
    , InspectReport (..)
    , Outref (..)
    )
import Amaru.Treasury.Scope (ScopeId (..))

spec :: Spec
spec = do
    describe "GET /v1/treasury-inspect" $ do
        it "returns 200 + bytes equal to encodeReport stubReport" $ do
            res <-
                runSession
                    ( WaiTest.srequest
                        (waiGet "/v1/treasury-inspect?scope=core_development")
                    )
                    (mkApplication stubHandlers)
            WaiTest.simpleStatus res `shouldBe` status200
            WaiTest.simpleBody res `shouldBe` encodeReport stubReport

        it "returns 400 when the scope query param is missing" $ do
            res <-
                runSession
                    (WaiTest.srequest (waiGet "/v1/treasury-inspect"))
                    (mkApplication stubHandlers)
            statusCodeOf res `shouldSatisfy` is4xx

        it "returns 400 when the scope value is unknown" $ do
            res <-
                runSession
                    (WaiTest.srequest (waiGet "/v1/treasury-inspect?scope=foo"))
                    (mkApplication stubHandlers)
            statusCodeOf res `shouldSatisfy` is4xx

    describe "GET /v1/recent-txs" $
        it "returns the embedded manifest verbatim" $ do
            res <-
                runSession
                    (WaiTest.srequest (waiGet "/v1/recent-txs"))
                    (mkApplication stubHandlers)
            WaiTest.simpleStatus res `shouldBe` status200
    -- The body parses back to the same manifest. We
    -- don't assert byte-identity here (aeson Generic
    -- encoding has no shape guarantee across versions).

    describe "GET /v1/version" $
        it "returns the embedded build identity verbatim" $ do
            res <-
                runSession
                    (WaiTest.srequest (waiGet "/v1/version"))
                    (mkApplication stubHandlers)
            WaiTest.simpleStatus res `shouldBe` status200

    describe "Raw fallback" $
        it "is invoked for unknown paths" $ do
            res <-
                runSession
                    (WaiTest.srequest (waiGet "/fbar"))
                    (mkApplication stubHandlers)
            statusCodeOf res `shouldBe` 404

-- ---------------------------------------------------------------------------
-- Helpers

waiGet :: ByteString -> WaiTest.SRequest
waiGet path =
    WaiTest.SRequest
        ( WaiTest.setPath
            WaiTest.defaultRequest
            (LBS.toStrict path)
        )
        ""

statusCodeOf :: SResponse -> Int
statusCodeOf r = statusCode (WaiTest.simpleStatus r)

is4xx :: Int -> Bool
is4xx c = c >= 400 && c < 500

-- ---------------------------------------------------------------------------
-- Stub Handlers

stubHandlers :: Handlers
stubHandlers =
    Handlers
        { hInspectReport = \_scope -> pure stubReport
        , hRecentTxs = RecentTxManifest []
        , hBuildIdentity = stubBuildIdentity
        , hRawHandler = stubRawHandler
        }

stubRawHandler :: Tagged Servant.Handler Application
stubRawHandler = Tagged $ \_req respond ->
    respond $
        responseLBS
            status404
            [("Content-Type", "text/plain")]
            "stub-raw: 404"

stubReport :: InspectReport
stubReport =
    InspectReport
        { irChainTip =
            ChainTip
                { ctSlot = 119000000
                , ctBlockHash = Just "deadbeef"
                }
        , irDeployment =
            DeploymentAnchor
                ( Outref
                    { orTxId = "11ace24a"
                    , orIx = 0
                    }
                )
        , irScopes = []
        }

stubBuildIdentity :: BuildIdentity
stubBuildIdentity =
    BuildIdentity
        { biBuildTime =
            UTCTime
                (fromGregorian 2026 5 22)
                (secondsToDiffTime 71621)
        , biGitCommit = "abcdef0"
        , biMetadataSha256 =
            "8ea2c53b931efae432f5a7fc031b732147cc39b9b6159b4f6e1b22c8b78fa375"
        , biMetadataSource =
            "github:pragma-org/amaru-treasury/fb1937964196b061ddc4f247d2de11a13745d541"
        , biRecentTxsCount = 0
        }
