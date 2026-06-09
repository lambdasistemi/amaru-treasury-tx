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
import Data.Either (isLeft)
import Data.List.NonEmpty qualified as NE
import Data.Tagged (Tagged (..))
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Network.HTTP.Types (status200, status404)
import Network.HTTP.Types.Method (methodPost)
import Network.HTTP.Types.Status (statusCode)
import Network.Wai
    ( Application
    , requestHeaders
    , requestMethod
    , responseLBS
    )
import Network.Wai.Test (SResponse, runSession)
import Network.Wai.Test qualified as WaiTest
import Servant qualified
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

import Amaru.Treasury.Api.BuildContingencyDisburse
    ( ContingencyDestinationRequest (..)
    , ContingencyDisburseBuildRequest (..)
    , mapToContingencyDisburseOpts
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
import Amaru.Treasury.Api.Server
    ( Handlers (..)
    , mkApplication
    )
import Amaru.Treasury.Api.Types
    ( BuildIdentity (..)
    , HealthResponse (..)
    , ParamsResponse (..)
    , PendingResponse (..)
    , PendingScope (..)
    , RecentTxManifest (..)
    , RegistryResponse (..)
    , RegistryScope (..)
    , ScopeHistoryEntry (..)
    , ScopeHistoryQueryResponse (..)
    , ScopeHistoryResponse (..)
    , ScopeHistoryShaclResponse (..)
    , ScopeScripts (..)
    , ScopeUtxosResponse (..)
    , ScriptRefResponse (..)
    , ScriptsResponse (..)
    , SubmitRequest (..)
    , SubmitResponse (..)
    , TipResponse (..)
    , TxDetailInput (..)
    , TxDetailOutput (..)
    , TxDetailResponse (..)
    )
import Amaru.Treasury.Cli.DisburseWizard
    ( ContingencyDisburseOpts (..)
    )
import Amaru.Treasury.Inspect.Render (encodeReport)
import Amaru.Treasury.Inspect.Types
    ( ChainTip (..)
    , DeploymentAnchor (..)
    , InspectReport (..)
    , Outref (..)
    , ScopeSection (..)
    , ScopeTotals (..)
    , TreasuryUtxo (..)
    )
import Amaru.Treasury.IntentJSON
    ( RationaleReferenceJSON (..)
    )
import Amaru.Treasury.Report.Accounting (ValueSummary (..))
import Amaru.Treasury.Scope (ScopeId (..))
import Amaru.Treasury.Wizard.Failure (FieldId (..))
import Amaru.Treasury.Wizard.InputControl
    ( ExclusionSet (..)
    , ForcedInclusionSet (..)
    )

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

    describe "GET /v1/tx/{txid}" $ do
        it "returns indexed transaction detail rows" $ do
            res <-
                runSession
                    ( WaiTest.srequest
                        (waiGet ("/v1/tx/" <> validTxIdPath))
                    )
                    (mkApplication stubHandlers)
            WaiTest.simpleStatus res `shouldBe` status200
            Aeson.decode (WaiTest.simpleBody res)
                `shouldBe` Just stubTxDetail

        it "returns 400 when the txid path segment is malformed" $ do
            res <-
                runSession
                    (WaiTest.srequest (waiGet "/v1/tx/not-a-txid"))
                    (mkApplication stubHandlers)
            statusCodeOf res `shouldSatisfy` is4xx

        it "returns 404 when the txid is not indexed" $ do
            res <-
                runSession
                    ( WaiTest.srequest
                        (waiGet ("/v1/tx/" <> validTxIdPath))
                    )
                    (mkApplication stubHandlers{hTxDetail = \_ -> pure Nothing})
            statusCodeOf res `shouldBe` 404

    describe "state read endpoints" $ do
        it "returns registry metadata" $ do
            res <-
                runSession
                    (WaiTest.srequest (waiGet "/v1/registry"))
                    (mkApplication stubHandlers)
            WaiTest.simpleStatus res `shouldBe` status200
            Aeson.decode (WaiTest.simpleBody res)
                `shouldBe` Just stubRegistry

        it "returns script metadata" $ do
            res <-
                runSession
                    (WaiTest.srequest (waiGet "/v1/scripts"))
                    (mkApplication stubHandlers)
            WaiTest.simpleStatus res `shouldBe` status200
            Aeson.decode (WaiTest.simpleBody res)
                `shouldBe` Just stubScripts

        it "returns pending orders grouped by scope" $ do
            res <-
                runSession
                    ( WaiTest.srequest
                        (waiGet "/v1/pending?scope=core_development")
                    )
                    (mkApplication stubHandlers)
            WaiTest.simpleStatus res `shouldBe` status200

        it "returns one scope state section" $ do
            res <-
                runSession
                    ( WaiTest.srequest
                        (waiGet "/v1/scope/core_development/state")
                    )
                    (mkApplication stubHandlers)
            WaiTest.simpleStatus res `shouldBe` status200

        it "accepts UTxO filters for one scope" $ do
            res <-
                runSession
                    ( WaiTest.srequest
                        ( waiGet
                            "/v1/scope/core_development/utxos?asset=ada&min_lovelace=1&limit=1"
                        )
                    )
                    (mkApplication stubHandlers)
            WaiTest.simpleStatus res `shouldBe` status200

    describe "node utility and health endpoints" $ do
        it "returns the current tip slot" $ do
            res <-
                runSession
                    (WaiTest.srequest (waiGet "/v1/tip"))
                    (mkApplication stubHandlers)
            WaiTest.simpleStatus res `shouldBe` status200
            Aeson.decode (WaiTest.simpleBody res) `shouldBe` Just stubTip

        it "returns protocol parameter summary" $ do
            res <-
                runSession
                    (WaiTest.srequest (waiGet "/v1/params"))
                    (mkApplication stubHandlers)
            WaiTest.simpleStatus res `shouldBe` status200
            Aeson.decode (WaiTest.simpleBody res) `shouldBe` Just stubParams

        it "submits a signed transaction request" $ do
            res <-
                runSession
                    ( WaiTest.srequest
                        ( waiPostJson
                            "/v1/submit"
                            (Aeson.encode (SubmitRequest "00"))
                        )
                    )
                    (mkApplication stubHandlers)
            WaiTest.simpleStatus res `shouldBe` status200
            Aeson.decode (WaiTest.simpleBody res) `shouldBe` Just stubSubmit

        it "returns readiness health" $ do
            res <-
                runSession
                    (WaiTest.srequest (waiGet "/v1/health"))
                    (mkApplication stubHandlers)
            WaiTest.simpleStatus res `shouldBe` status200
            Aeson.decode (WaiTest.simpleBody res) `shouldBe` Just stubHealth

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

        it "accepts shared history filter query params" $ do
            res <-
                runSession
                    ( WaiTest.srequest
                        ( waiGet
                            "/v1/scope/core_development/txs?role=disburse&asset=ada&direction=outbound&since=10&until=20&limit=1"
                        )
                    )
                    (mkApplication stubHandlers)
            WaiTest.simpleStatus res `shouldBe` status200

    describe "GET /v1/scope/{scope}/txs/query" $ do
        it "accepts a named RDF query" $ do
            res <-
                runSession
                    ( WaiTest.srequest
                        ( waiGet
                            "/v1/scope/core_development/txs/query?name=history-entries"
                        )
                    )
                    (mkApplication stubHandlers)
            WaiTest.simpleStatus res `shouldBe` status200

        it "rejects an unknown named RDF query" $ do
            res <-
                runSession
                    ( WaiTest.srequest
                        ( waiGet
                            "/v1/scope/core_development/txs/query?name=bogus"
                        )
                    )
                    (mkApplication stubHandlers)
            statusCodeOf res `shouldSatisfy` is4xx

    describe "GET /v1/scope/{scope}/txs/shacl" $ do
        it "accepts a named SHACL shape" $ do
            res <-
                runSession
                    ( WaiTest.srequest
                        ( waiGet
                            "/v1/scope/core_development/txs/shacl?name=history-entry"
                        )
                    )
                    (mkApplication stubHandlers)
            WaiTest.simpleStatus res `shouldBe` status200

        it "rejects an unknown named SHACL shape" $ do
            res <-
                runSession
                    ( WaiTest.srequest
                        ( waiGet
                            "/v1/scope/core_development/txs/shacl?name=bogus"
                        )
                    )
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

    describe "mapToContingencyDisburseOpts" $ do
        let mkDest s a =
                ContingencyDestinationRequest
                    { scope = s
                    , amountAda = a
                    }
            baseReq dests =
                ContingencyDisburseBuildRequest
                    { walletAddr = "addr_test1wallet"
                    , metadataPath = "journal/2026/metadata.json"
                    , destinations = dests
                    , validityHours = Nothing
                    , description = "rainy day"
                    , justification = "council motion 7"
                    , references = []
                    }
            sampleRef =
                RationaleReferenceJSON
                    { rjrUri = "ipfs://bafkreicontingencyrationale"
                    , rjrType = "Other"
                    , rjrLabel = "council motion 7 minutes"
                    }
            reqWithRefs =
                (baseReq [mkDest CoreDevelopment 1.0])
                    { references = [sampleRef]
                    }
        it "rejects an empty destinations list" $
            mapToContingencyDisburseOpts (baseReq [])
                `shouldSatisfy` isLeft
        it "rejects contingency as a destination scope" $
            mapToContingencyDisburseOpts
                (baseReq [mkDest Contingency 1.0])
                `shouldSatisfy` isLeft
        it
            "maps a valid 2-destination request to the expected \
            \ContingencyDisburseOpts (ADA -> lovelace, order \
            \preserved)"
            $ mapToContingencyDisburseOpts
                ( baseReq
                    [ mkDest CoreDevelopment 1.0
                    , mkDest Middleware 2.5
                    ]
                )
                `shouldBe` Right
                    ContingencyDisburseOpts
                        { cdOptsWalletAddr = "addr_test1wallet"
                        , cdOptsMetadataPath =
                            "journal/2026/metadata.json"
                        , cdOptsOut = Nothing
                        , cdOptsLog = Nothing
                        , cdOptsDestinations =
                            NE.fromList
                                [ (CoreDevelopment, 1000000)
                                , (Middleware, 2500000)
                                ]
                        , cdOptsValidityHours = Nothing
                        , cdOptsDescription = "rainy day"
                        , cdOptsJustification = "council motion 7"
                        , cdOptsReferences = []
                        , cdOptsExcludeSet = ExclusionSet []
                        , cdOptsForcedSet = ForcedInclusionSet []
                        }
        it
            "passes CIP-1694 references through to \
            \cdOptsReferences (mirrors the non-contingency \
            \disburse)"
            $ fmap
                cdOptsReferences
                (mapToContingencyDisburseOpts reqWithRefs)
                `shouldBe` Right [sampleRef]
        it "round-trips a request carrying references" $
            Aeson.decode (Aeson.encode reqWithRefs)
                `shouldBe` Just reqWithRefs

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

waiPostJson :: ByteString -> ByteString -> WaiTest.SRequest
waiPostJson path =
    WaiTest.SRequest
        ( WaiTest.setPath
            WaiTest.defaultRequest
                { requestMethod = methodPost
                , requestHeaders = [("Content-Type", "application/json")]
                }
            (LBS.toStrict path)
        )

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
        , hTxDetail = \_ -> pure (Just stubTxDetail)
        , hRegistry = pure stubRegistry
        , hScripts = pure stubScripts
        , hPending = \scope ->
            pure stubPending{prScope = scope}
        , hTip = pure stubTip
        , hParams = pure stubParams
        , hSubmit = \_ -> pure stubSubmit
        , hHealth = pure stubHealth
        , hScopeState = \scope ->
            pure stubScopeState{ssScope = scope}
        , hScopeUtxos = \scope _filter ->
            pure stubScopeUtxos{surScope = scope}
        , hScopeHistory = \scope _filter ->
            pure stubHistory{shrScope = scope}
        , hScopeHistoryQuery = \scope _queryName ->
            pure
                ScopeHistoryQueryResponse
                    { shqrScope = scope
                    , shqrQuery = "stub"
                    , shqrColumns = ["query"]
                    , shqrRows = [["stub"]]
                    }
        , hScopeHistoryShacl = \scope _shapeName ->
            pure
                ScopeHistoryShaclResponse
                    { shsrScope = scope
                    , shsrShape = "stub"
                    , shsrConforms = True
                    , shsrReport = ""
                    }
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
        , hBuildContingencyDisburse = \_ ->
            pure disburseIntentFailureResp
        , hBuildReorganize = \_ -> pure reorganizeIntentFailureResp
        , hRawHandler = stubRawHandler
        }

stubRegistry :: RegistryResponse
stubRegistry =
    RegistryResponse
        { rrScopeOwners =
            "11ace24a1111111111111111111111111111111111111111111111111111111111#0"
        , rrScopes =
            [ RegistryScope
                { rsScope = CoreDevelopment
                , rsOwner = Just "owner"
                , rsBudget = Just 1
                , rsAddress = "addr1..."
                }
            ]
        }

stubScripts :: ScriptsResponse
stubScripts =
    ScriptsResponse
        { srScopes =
            [ ScopeScripts
                { ssrScope = CoreDevelopment
                , ssrTreasury = stubScriptRef
                , ssrPermissions = stubScriptRef
                , ssrRegistry = stubScriptRef
                }
            ]
        }

stubScriptRef :: ScriptRefResponse
stubScriptRef =
    ScriptRefResponse
        { srrHash = "00"
        , srrDeployedAt =
            "11ace24a1111111111111111111111111111111111111111111111111111111111#0"
        }

stubPending :: PendingResponse
stubPending =
    PendingResponse
        { prScope = Nothing
        , prEntries =
            [ PendingScope
                { psScope = CoreDevelopment
                , psOrders = []
                }
            ]
        }

stubTip :: TipResponse
stubTip = TipResponse 123

stubParams :: ParamsResponse
stubParams =
    ParamsResponse
        { parEra = "conway"
        , parSummary = "params"
        }

stubSubmit :: SubmitResponse
stubSubmit =
    SubmitResponse
        { subStatus = "accepted"
        , subTxId =
            Just
                "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        , subReason = Nothing
        }

stubHealth :: HealthResponse
stubHealth =
    HealthResponse
        { hrStatus = "ready"
        , hrProcessedSlot = 120
        , hrTipSlot = 123
        , hrLagSlots = 3
        , hrThresholdSlots = 60
        , hrUpdatedAt = biBuildTime stubBuildIdentity
        }

stubScopeUtxos :: ScopeUtxosResponse
stubScopeUtxos =
    ScopeUtxosResponse
        { surScope = CoreDevelopment
        , surEntries = [stubTreasuryUtxo]
        }

stubScopeState :: ScopeSection
stubScopeState =
    ScopeSection
        { ssScope = CoreDevelopment
        , ssTreasuryAddress = "addr1..."
        , ssTreasuryScriptHash = "00"
        , ssTreasuryUtxos = [stubTreasuryUtxo]
        , ssTreasuryTotals =
            ScopeTotals
                { stLovelace = 1
                , stUsdm = 0
                , stOtherAssetsCount = 0
                }
        , ssPendingOrders = []
        }

stubTreasuryUtxo :: TreasuryUtxo
stubTreasuryUtxo =
    TreasuryUtxo
        { tuOutref =
            Outref
                { orTxId =
                    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                , orIx = 0
                }
        , tuLovelace = 1
        , tuUsdm = 0
        , tuOtherAssets = []
        , tuDatumHash = Nothing
        }

validTxIdPath :: ByteString
validTxIdPath =
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

stubTxDetail :: TxDetailResponse
stubTxDetail =
    TxDetailResponse
        { tdrSlot = 42
        , tdrTxId =
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        , tdrScope = "core_development"
        , tdrRole = "disburse"
        , tdrDirection = "outbound"
        , tdrBlockHash = Just "abcd"
        , tdrFee = Just 2
        , tdrRequiredSigners = ["signer-a"]
        , tdrRedeemer = Just "redeemer-summary"
        , tdrInputs =
            [ TxDetailInput
                { tdiTxIn = "input#0"
                , tdiScope = Just "core_development"
                , tdiValue = "42 lovelace"
                }
            ]
        , tdrOutputs =
            [ TxDetailOutput
                { tdoIndex = 0
                , tdoAddress = "addr1..."
                , tdoScope = Just "core_development"
                , tdoRole = Just "treasury"
                , tdoValue =
                    ValueSummary{vsLovelace = 40, vsAssets = mempty}
                , tdoDatum = Just "inlineDatum"
                }
            ]
        , tdrLines =
            [ "slot 42"
            , "txid aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            ]
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
