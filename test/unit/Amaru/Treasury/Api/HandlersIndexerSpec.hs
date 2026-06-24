{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- |
Module      : Amaru.Treasury.Api.HandlersIndexerSpec
Description : Integration tests for the indexer-served handlers
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Exercises the rewired @\/v1\/treasury-inspect@ + lag-503
guard introduced by #242 (Slice 2).

Three scenarios per the slice brief:

1. The handler computes the 'InspectReport' from the
   embedded 'ApiIndexer' and the supplied @nowTip@ on
   the provider — and DOES NOT call @queryUTxOs@ on the
   provider. The test installs a trap on the provider's
   @queryUTxOs@ that explodes if called; the test passes
   only because the handler routes through the indexer.

2. The same call uses the provider's @nowTip@ for the
   response's @chain_tip@ field (the only remaining N2C
   call on the request hot path per FR-005).

The lag-503 middleware has its own unit coverage in
"Amaru.Treasury.Api.LagGuardSpec".
-}
module Amaru.Treasury.Api.HandlersIndexerSpec (spec) where

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Node.Client.N2C.Probe (defaultProbeConfig)
import Cardano.Node.Client.N2C.Reconnect (defaultReconnectPolicy)
import Cardano.Node.Client.N2C.Trace (nullN2CTracer)
import Cardano.Node.Client.Provider
    ( Provider (..)
    , queryUTxOByTxInH
    , singleShotWithAcquired
    )
import Cardano.Node.Client.UTxOIndexer.Follower (InterestSet (..))
import Cardano.Slotting.Slot (SlotNo (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Word (Word64)
import Ouroboros.Network.Magic (NetworkMagic (..))
import Servant qualified
import Servant.Server (runHandler)
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldSatisfy
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
import Amaru.Treasury.Api.BuildSwapRerate
    ( SwapRerateBuildResponse (..)
    )
import Amaru.Treasury.Api.Indexer
    ( ApiIndexer
    , IndexerConfig (..)
    , withApiIndexer
    )
import Amaru.Treasury.Api.Server
    ( BuildHandlers (..)
    , mkBuildHandlersWithSwapRerate
    , mkBuildProvider
    , mkInspectHandler
    )
import Amaru.Treasury.Constants
    ( sundaeOrderAddressMainnet
    )
import Amaru.Treasury.Inspect.Types
    ( ChainTip (..)
    , DeploymentAnchor (..)
    , InspectReport (..)
    , Outref (..)
    )
import Amaru.Treasury.IntentJSON.Common (parseAddr, parseTxIn)
import Amaru.Treasury.Metadata
    ( ScopeMetadata (..)
    , ScriptRef (..)
    , TreasuryMetadata (..)
    )
import Amaru.Treasury.Scope (ScopeId (..))

spec :: Spec
spec = describe "Amaru.Treasury.Api handlers + indexer" $ do
    describe "mkInspectHandler" $ do
        it
            "computes the InspectReport from the indexer and\
            \ never calls Provider.queryUTxOs"
            $ withTestIndexer
            $ \apiIdx -> do
                addr <- mainnetSwapAddr
                report <-
                    runHandlerOrFail $
                        mkInspectHandler
                            apiIdx
                            trappedProvider
                            testMetadata
                            testAnchor
                            addr
                            Middleware
                -- empty indexer -> empty scope section
                length (irScopes report) `shouldBe` 1

        it "uses Provider.nowTip for the chain_tip field" $
            withTestIndexer $ \apiIdx -> do
                addr <- mainnetSwapAddr
                report <-
                    runHandlerOrFail $
                        mkInspectHandler
                            apiIdx
                            trappedProvider
                            testMetadata
                            testAnchor
                            addr
                            Middleware
                ctSlot (irChainTip report)
                    `shouldBe` testNowTipWord

    describe "mkBuildProvider" $ do
        it
            "serves exact TxIn reads from the indexer, not the raw provider"
            $ withTestIndexer
            $ \apiIdx -> do
                found <-
                    queryUTxOByTxIn
                        (mkBuildProvider apiIdx trappedProvider)
                        (Set.singleton sampleTxIn)
                found `shouldBe` Map.empty

        it
            "serves acquired exact TxIn reads from the indexer, not the raw provider"
            $ withTestIndexer
            $ \apiIdx -> do
                found <-
                    withAcquired
                        (mkBuildProvider apiIdx acquirableTrappedProvider)
                        $ \handle ->
                            queryUTxOByTxInH
                                handle
                                (Set.singleton sampleTxIn)
                found `shouldBe` Map.empty

    describe "mkBuildHandlers" $ do
        it
            "wires the swap build handler to the indexer-backed provider"
            $ withTestIndexer
            $ \apiIdx -> do
                addr <- mainnetSwapAddr
                let buildHandlers = trappedBuildHandlers apiIdx addr
                _ <- bhBuildSwap buildHandlers (error "unused swap request")
                pure ()

        it
            "wires the swap-rerate build handler to the indexer-backed provider"
            $ withTestIndexer
            $ \apiIdx -> do
                addr <- mainnetSwapAddr
                let buildHandlers = trappedBuildHandlers apiIdx addr
                _ <-
                    bhBuildSwapRerate
                        buildHandlers
                        (error "unused swap-rerate request")
                pure ()

        it
            "wires the disburse build handler to the indexer-backed provider"
            $ withTestIndexer
            $ \apiIdx -> do
                addr <- mainnetSwapAddr
                let buildHandlers = trappedBuildHandlers apiIdx addr
                _ <-
                    bhBuildDisburse
                        buildHandlers
                        (error "unused disburse request")
                pure ()

        it
            "wires the reorganize build handler to the indexer-backed provider"
            $ withTestIndexer
            $ \apiIdx -> do
                addr <- mainnetSwapAddr
                let buildHandlers = trappedBuildHandlers apiIdx addr
                _ <-
                    bhBuildReorganize
                        buildHandlers
                        (error "unused reorganize request")
                pure ()

    describe "amaru-treasury-tx-api Main build wiring" $ do
        it
            "uses the shared build-provider wiring instead of raw backend calls"
            $ do
                src <- TIO.readFile apiMainSource
                src `shouldNotContainText` "runBuildSwap g backend"
                src `shouldNotContainText` "runBuildDisburse g backend"
                src `shouldNotContainText` "runBuildReorganize g backend"
                src `shouldContainText` "mkBuildHandlers"

-- ---------------------------------------------------------------------------
-- Fixtures

testNowTipSlot :: SlotNo
testNowTipSlot = SlotNo 12_345

testNowTipWord :: Word64
testNowTipWord = unSlotNo testNowTipSlot

sampleTxIn :: TxIn
sampleTxIn =
    case parseTxIn
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa#0" of
        Right txIn -> txIn
        Left e -> error ("sampleTxIn: parseTxIn failed: " <> e)

testMetadata :: TreasuryMetadata
testMetadata =
    TreasuryMetadata
        { tmScopeOwners =
            "11ace24a1111111111111111111111111111111111111111111111111111111111#0"
        , tmTreasuries =
            Map.singleton
                Middleware
                ScopeMetadata
                    { smOwner =
                        Just "deadbeef00000000000000000000000000000000000000000000000000"
                    , smBudget = Nothing
                    , smAddress = sundaeOrderAddressMainnet
                    , smTreasury =
                        ScriptRef
                            "00000000000000000000000000000000000000000000000000000000"
                            "11ace24a1111111111111111111111111111111111111111111111111111111111#0"
                    , smPermissions =
                        ScriptRef
                            "00000000000000000000000000000000000000000000000000000000"
                            "11ace24a1111111111111111111111111111111111111111111111111111111111#0"
                    , smRegistry =
                        ScriptRef
                            "00000000000000000000000000000000000000000000000000000000"
                            "11ace24a1111111111111111111111111111111111111111111111111111111111#0"
                    }
        }

testAnchor :: DeploymentAnchor
testAnchor =
    DeploymentAnchor
        Outref
            { orTxId =
                "11ace24a1111111111111111111111111111111111111111111111111111111111"
            , orIx = 0
            }

mainnetSwapAddr :: IO Addr
mainnetSwapAddr =
    case parseAddr sundaeOrderAddressMainnet of
        Right a -> pure a
        Left e ->
            error $
                "mainnetSwapAddr: built-in failed to parse: "
                    <> e

{- | A 'Provider' that traps every chain-query method we
expect the handler to bypass. Only 'nowTip' is allowed
to be called.

If a handler regression accidentally drops a UTxO query
back to the provider, the relevant trap fires and the
test fails loudly — the FR-002 / FR-004 invariant.
-}
trappedProvider :: Provider IO
trappedProvider =
    Provider
        { withAcquired = \_ -> trap "withAcquired"
        , queryUTxOs = \_ -> trap "queryUTxOs"
        , queryUTxOByTxIn = \_ -> trap "queryUTxOByTxIn"
        , queryProtocolParams = trap "queryProtocolParams"
        , queryLedgerSnapshot = trap "queryLedgerSnapshot"
        , queryStakeRewards = \_ -> trap "queryStakeRewards"
        , queryRewardAccounts = \_ -> trap "queryRewardAccounts"
        , queryVoteDelegatees = \_ -> trap "queryVoteDelegatees"
        , queryTreasury = trap "queryTreasury"
        , queryGovernanceState = trap "queryGovernanceState"
        , evaluateTx = \_ -> trap "evaluateTx"
        , -- 'nowTip' in Amaru.Treasury.Cli.Common is the
          -- only allowed call: it routes via
          -- posixMsToSlot which we stub here (FR-005).
          posixMsToSlot = \_ -> pure testNowTipSlot
        , posixMsCeilSlot = \_ -> trap "posixMsCeilSlot"
        , queryUpperBoundSlot = \_ -> trap "queryUpperBoundSlot"
        }

acquirableTrappedProvider :: Provider IO
acquirableTrappedProvider =
    trappedProvider
        { withAcquired = singleShotWithAcquired trappedProvider
        }

{- | Defer the trap into the IO action's run-time, not its
WHNF: cardano-node-clients's @StrictData@ default-extension
makes 'Provider' fields strict, so a bare @error "..."@ at a
'IO'-shaped field fires at record construction (and the
trapped-on-purpose semantics never reach the run path).
'ioError' wraps in a defined 'IO' action; the underlying
'userError' only throws when the action is sequenced — which
is exactly what the test wants to detect.
-}
trap :: String -> IO a
trap name =
    ioError $
        userError $
            "trappedProvider: "
                <> name
                <> " called unexpectedly (handler hot \
                   \path is indexer-served per #242)"

-- ---------------------------------------------------------------------------
-- Helpers

withTestIndexer :: (forall cf op. ApiIndexer cf op -> IO a) -> IO a
withTestIndexer action =
    withSystemTempDirectory "atx-handlers-test" $ \dir ->
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

runHandlerOrFail :: Servant.Handler a -> IO a
runHandlerOrFail h = do
    r <- runHandler h
    case r of
        Right a -> pure a
        Left e ->
            error $
                "runHandlerOrFail: Servant.Handler returned \
                \ServerError: "
                    <> show e

trappedBuildHandlers :: ApiIndexer cf op -> Addr -> BuildHandlers
trappedBuildHandlers apiIdx addr =
    mkBuildHandlersWithSwapRerate
        apiIdx
        Nothing
        trappedProvider
        (\provider _req -> buildQuery provider >> pure emptySwapResponse)
        ( \provider _req -> buildQuery provider >> pure emptySwapRerateResponse
        )
        (\provider _req -> buildQuery provider >> pure emptyDisburseResponse)
        (\provider _req -> buildQuery provider >> pure emptyDisburseResponse)
        ( \provider _req -> buildQuery provider >> pure emptyReorganizeResponse
        )
  where
    -- The build slots only exist to prove the read goes through the
    -- indexer-backed provider; every handler post-processes its
    -- response (the #345 graph-effect and #357 TTL attaches), so the
    -- slots return a concrete all-'Nothing' response whose @cborHex@
    -- is 'Nothing' — a clean attach pass-through — rather than a
    -- bottom.
    buildQuery :: Provider IO -> IO ()
    buildQuery provider = do
        _ <- queryUTxOs provider addr
        pure ()

{- | An all-'Nothing' swap build response: no CBOR, so the graph-effect
attach is a pass-through.
-}
emptySwapResponse :: SwapBuildResponse
emptySwapResponse =
    SwapBuildResponse
        { sbrIntentJson = Nothing
        , sbrCli = Nothing
        , sbrCborHex = Nothing
        , sbrCborEnvelope = Nothing
        , sbrReport = Nothing
        , sbrFailureTag = Nothing
        , sbrFailureField = Nothing
        , sbrFailureReason = Nothing
        , sbrBuildFailureTag = Nothing
        , sbrGraphEffect = Nothing
        , sbrTtl = Nothing
        , sbrProofs = Nothing
        }

-- | An all-'Nothing' swap-rerate build response.
emptySwapRerateResponse :: SwapRerateBuildResponse
emptySwapRerateResponse =
    SwapRerateBuildResponse
        { srrCborHex = Nothing
        , srrCborEnvelope = Nothing
        , srrReport = Nothing
        , srrDecision = Nothing
        , srrReason = Nothing
        , srrFailureTag = Nothing
        , srrFailureReason = Nothing
        }

{- | An all-'Nothing' disburse build response (used for both the
disburse and contingency-disburse slots).
-}
emptyDisburseResponse :: DisburseBuildResponse
emptyDisburseResponse =
    DisburseBuildResponse
        { dbrIntentJson = Nothing
        , dbrCli = Nothing
        , dbrCborHex = Nothing
        , dbrCborEnvelope = Nothing
        , dbrReport = Nothing
        , dbrFailureTag = Nothing
        , dbrFailureField = Nothing
        , dbrFailureReason = Nothing
        , dbrBuildFailureTag = Nothing
        , dbrGraphEffect = Nothing
        , dbrTtl = Nothing
        , dbrProofs = Nothing
        }

{- | An all-'Nothing' reorganize build response: no CBOR, so the TTL
attach is a pass-through.
-}
emptyReorganizeResponse :: ReorganizeBuildResponse
emptyReorganizeResponse =
    ReorganizeBuildResponse
        { rbrIntentJson = Nothing
        , rbrCli = Nothing
        , rbrCborHex = Nothing
        , rbrCborEnvelope = Nothing
        , rbrReport = Nothing
        , rbrFailureTag = Nothing
        , rbrFailureField = Nothing
        , rbrFailureReason = Nothing
        , rbrBuildFailureTag = Nothing
        , rbrTtl = Nothing
        , rbrProofs = Nothing
        }

apiMainSource :: FilePath
apiMainSource = "app/amaru-treasury-tx-api/Main.hs"

shouldContainText :: T.Text -> T.Text -> IO ()
shouldContainText haystack needle =
    haystack `shouldSatisfy` T.isInfixOf needle

shouldNotContainText :: T.Text -> T.Text -> IO ()
shouldNotContainText haystack needle =
    haystack `shouldSatisfy` (not . T.isInfixOf needle)
