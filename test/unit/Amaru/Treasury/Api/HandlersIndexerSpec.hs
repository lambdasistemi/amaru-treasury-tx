{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

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
import Cardano.Node.Client.N2C.Probe (defaultProbeConfig)
import Cardano.Node.Client.N2C.Reconnect (defaultReconnectPolicy)
import Cardano.Node.Client.N2C.Trace (nullN2CTracer)
import Cardano.Node.Client.Provider (Provider (..))
import Cardano.Node.Client.UTxOIndexer.Follower (InterestSet (..))
import Cardano.Node.Client.UTxOIndexer.Types qualified as Indexer
import Cardano.Slotting.Slot (SlotNo (..))
import Data.Map.Strict qualified as Map
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
    )

import Amaru.Treasury.Api.Indexer
    ( ApiIndexer
    , IndexerConfig (..)
    , withApiIndexer
    )
import Amaru.Treasury.Api.Server
    ( mkInspectHandler
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
import Amaru.Treasury.IntentJSON.Common (parseAddr)
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

-- ---------------------------------------------------------------------------
-- Fixtures

testNowTipSlot :: SlotNo
testNowTipSlot = SlotNo 12_345

testNowTipWord :: Word64
testNowTipWord = unSlotNo testNowTipSlot

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

withTestIndexer :: (ApiIndexer -> IO a) -> IO a
withTestIndexer action =
    withSystemTempDirectory "atx-handlers-test" $ \dir ->
        withApiIndexer
            nullN2CTracer
            IndexerConfig
                { icDbPath = dir
                , icSocketPath = dir <> "/missing.sock"
                , icNetworkMagic = NetworkMagic 42
                , icStartSlot = Indexer.SlotNo 0
                , icLagThresholdSlots = 60
                , icByronEpochSlots = 86_400
                , icSecurityParamK = 2160
                , icReconnectPolicy = defaultReconnectPolicy
                , icProbeConfig = defaultProbeConfig
                , icInterestSet = IndexAll
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
