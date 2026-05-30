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

import Data.Aeson qualified as Aeson
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

import Amaru.Treasury.Api.BuildDisburse
    ( DisburseBuildResponse (..)
    )
import Amaru.Treasury.Api.BuildReorganize
    ( ReorganizeBuildResponse (..)
    )
import Amaru.Treasury.Api.BuildSwap
    ( SwapBuildResponse (..)
    )
import Amaru.Treasury.Api.Server
    ( Handlers (..)
    , mkApplication
    )
import Amaru.Treasury.Api.Types
    ( BuildIdentity (..)
    , RecentTxManifest (..)
    , ScopeHistoryEntry (..)
    , ScopeHistoryResponse (..)
    )
import Amaru.Treasury.Inspect.Render (encodeReport)
import Amaru.Treasury.Inspect.Types
    ( ChainTip (..)
    , DeploymentAnchor (..)
    , InspectReport (..)
    , Outref (..)
    )
import Amaru.Treasury.Scope (ScopeId (..))
import Amaru.Treasury.Wizard.Failure (FieldId (..))

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

    describe "GET /v1/scope/{scope}/txs" $ do
        it "returns indexed tx-history rows for the captured scope" $ do
            res <-
                runSession
                    ( WaiTest.srequest
                        (waiGet "/v1/scope/core_development/txs")
                    )
                    (mkApplication stubHandlers)
            WaiTest.simpleStatus res `shouldBe` status200
            Aeson.decode (WaiTest.simpleBody res)
                `shouldBe` Just stubHistory

        it "returns 400 when the captured scope is unknown" $ do
            res <-
                runSession
                    (WaiTest.srequest (waiGet "/v1/scope/foo/txs"))
                    (mkApplication stubHandlers)
            statusCodeOf res `shouldSatisfy` is4xx

    describe "Raw fallback" $
        it "is invoked for unknown paths" $ do
            res <-
                runSession
                    (WaiTest.srequest (waiGet "/fbar"))
                    (mkApplication stubHandlers)
            statusCodeOf res `shouldBe` 404

    describe "DisburseBuildResponse JSON round-trip" $ do
        let roundtrips r =
                Aeson.decode (Aeson.encode r) `shouldBe` Just r
        it "success arm round-trips" $
            roundtrips disburseSuccessResp
        it "intent-failure arm round-trips" $
            roundtrips disburseIntentFailureResp
        it "build-failure arm round-trips" $
            roundtrips disburseBuildFailureResp
        it "internal-error arm round-trips" $
            roundtrips disburseInternalErrorResp

    describe "ReorganizeBuildResponse JSON round-trip" $ do
        let roundtrips r =
                Aeson.decode (Aeson.encode r) `shouldBe` Just r
        it "success arm round-trips" $
            roundtrips reorganizeSuccessResp
        it "intent-failure arm round-trips" $
            roundtrips reorganizeIntentFailureResp
        it "build-failure arm round-trips" $
            roundtrips reorganizeBuildFailureResp
        it "internal-error arm round-trips" $
            roundtrips reorganizeInternalErrorResp

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
        , hScopeHistory = \scope ->
            pure stubHistory{shrScope = scope}
        , hBuildSwap = \_ ->
            pure
                SwapBuildResponse
                    { sbrIntentJson = Nothing
                    , sbrCli = Nothing
                    , sbrCborHex = Nothing
                    , sbrCborEnvelope = Nothing
                    , sbrReport = Nothing
                    , sbrFailureTag = Just "Stub"
                    , sbrFailureField = Nothing
                    , sbrFailureReason = Just "stub handler"
                    , sbrBuildFailureTag = Nothing
                    }
        , hBuildDisburse = \_ -> pure disburseIntentFailureResp
        , hBuildReorganize = \_ -> pure reorganizeIntentFailureResp
        , hRawHandler = stubRawHandler
        }

-- ---------------------------------------------------------------------------
-- DisburseBuildResponse fixtures (one per response arm)

disburseSuccessResp :: DisburseBuildResponse
disburseSuccessResp =
    DisburseBuildResponse
        { dbrIntentJson = Just "{\"action\":\"disburse\"}"
        , dbrCli = Just "amaru-treasury-tx disburse-wizard …"
        , dbrCborHex = Just "84a40081…"
        , dbrCborEnvelope =
            Just
                "{\"type\":\"Tx ConwayEra\",\"cborHex\":\"84a40081…\"}"
        , dbrReport = Just "{\"intent_path\":\"intent.json\"}"
        , dbrFailureTag = Nothing
        , dbrFailureField = Nothing
        , dbrFailureReason = Nothing
        , dbrBuildFailureTag = Nothing
        }

disburseIntentFailureResp :: DisburseBuildResponse
disburseIntentFailureResp =
    DisburseBuildResponse
        { dbrIntentJson = Nothing
        , dbrCli = Nothing
        , dbrCborHex = Nothing
        , dbrCborEnvelope = Nothing
        , dbrReport = Nothing
        , dbrFailureTag = Just "InputInvalid"
        , dbrFailureField = Just FieldWalletAddr
        , dbrFailureReason = Just "input wallet_addr: bech32 parse"
        , dbrBuildFailureTag = Nothing
        }

disburseBuildFailureResp :: DisburseBuildResponse
disburseBuildFailureResp =
    DisburseBuildResponse
        { dbrIntentJson = Just "{\"action\":\"disburse\"}"
        , dbrCli = Just "amaru-treasury-tx disburse-wizard …"
        , dbrCborHex = Nothing
        , dbrCborEnvelope = Nothing
        , dbrReport = Nothing
        , dbrFailureTag = Nothing
        , dbrFailureField = Nothing
        , dbrFailureReason = Just "build: insufficient fee"
        , dbrBuildFailureTag = Just "BuildBuildError"
        }

disburseInternalErrorResp :: DisburseBuildResponse
disburseInternalErrorResp =
    DisburseBuildResponse
        { dbrIntentJson = Nothing
        , dbrCli = Nothing
        , dbrCborHex = Nothing
        , dbrCborEnvelope = Nothing
        , dbrReport = Nothing
        , dbrFailureTag = Just "ResolveResolver"
        , dbrFailureField = Nothing
        , dbrFailureReason = Just "uncaught exception: timeout"
        , dbrBuildFailureTag = Nothing
        }

-- ---------------------------------------------------------------------------
-- ReorganizeBuildResponse fixtures (one per response arm)

reorganizeSuccessResp :: ReorganizeBuildResponse
reorganizeSuccessResp =
    ReorganizeBuildResponse
        { rbrIntentJson = Just "{\"action\":\"reorganize\"}"
        , rbrCli = Just "amaru-treasury-tx reorganize-wizard …"
        , rbrCborHex = Just "84a40081…"
        , rbrCborEnvelope =
            Just
                "{\"type\":\"Tx ConwayEra\",\"cborHex\":\"84a40081…\"}"
        , rbrReport = Just "{\"intent_path\":\"intent.json\"}"
        , rbrFailureTag = Nothing
        , rbrFailureField = Nothing
        , rbrFailureReason = Nothing
        , rbrBuildFailureTag = Nothing
        }

reorganizeIntentFailureResp :: ReorganizeBuildResponse
reorganizeIntentFailureResp =
    ReorganizeBuildResponse
        { rbrIntentJson = Nothing
        , rbrCli = Nothing
        , rbrCborHex = Nothing
        , rbrCborEnvelope = Nothing
        , rbrReport = Nothing
        , rbrFailureTag = Just "InputInvalid"
        , rbrFailureField = Just FieldWalletAddr
        , rbrFailureReason = Just "input wallet_addr: bech32 parse"
        , rbrBuildFailureTag = Nothing
        }

reorganizeBuildFailureResp :: ReorganizeBuildResponse
reorganizeBuildFailureResp =
    ReorganizeBuildResponse
        { rbrIntentJson = Just "{\"action\":\"reorganize\"}"
        , rbrCli = Just "amaru-treasury-tx reorganize-wizard …"
        , rbrCborHex = Nothing
        , rbrCborEnvelope = Nothing
        , rbrReport = Nothing
        , rbrFailureTag = Nothing
        , rbrFailureField = Nothing
        , rbrFailureReason = Just "build: checks failed"
        , rbrBuildFailureTag = Just "BuildBuildError"
        }

reorganizeInternalErrorResp :: ReorganizeBuildResponse
reorganizeInternalErrorResp =
    ReorganizeBuildResponse
        { rbrIntentJson = Nothing
        , rbrCli = Nothing
        , rbrCborHex = Nothing
        , rbrCborEnvelope = Nothing
        , rbrReport = Nothing
        , rbrFailureTag = Just "ResolveResolver"
        , rbrFailureField = Nothing
        , rbrFailureReason = Just "uncaught exception: timeout"
        , rbrBuildFailureTag = Nothing
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

stubHistory :: ScopeHistoryResponse
stubHistory =
    ScopeHistoryResponse
        { shrScope = CoreDevelopment
        , shrEntries =
            [ ScopeHistoryEntry
                { sheSlot = 187084729
                , sheTxId =
                    "a54df28670cd4409bcf7b59f033c6b1fec428662ce13c8e4d0c383a6571816f4"
                , sheRole = "disburse"
                , sheDirection = "outbound"
                }
            ]
        }
