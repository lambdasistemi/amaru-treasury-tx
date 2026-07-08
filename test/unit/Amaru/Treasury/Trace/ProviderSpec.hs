{- |
Module      : Amaru.Treasury.Trace.ProviderSpec
Description : Tests for provider boundary tracing wrappers
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0
-}
module Amaru.Treasury.Trace.ProviderSpec (spec) where

import Control.Exception
    ( SomeException
    , try
    )
import Control.Tracer
    ( Tracer (..)
    )
import Data.IORef
    ( atomicModifyIORef'
    , newIORef
    , readIORef
    )
import Data.Set qualified as Set
import Data.Text
    ( Text
    )
import Data.Text qualified as T
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    , shouldSatisfy
    )

import Cardano.Node.Client.Provider
    ( Provider (..)
    , QueryHandle
    , QueryHandleBackend (..)
    , evaluateTxH
    , mkQueryHandle
    , posixMsCeilSlotH
    , posixMsToSlotH
    , queryGovernanceStateH
    , queryLedgerSnapshotH
    , queryProtocolParamsH
    , queryRewardAccountsH
    , queryStakeRewardsH
    , queryTreasuryH
    , queryUTxOByTxInH
    , queryUTxOsAtH
    , queryUTxOsH
    , queryVoteDelegateesH
    )
import Cardano.Node.Client.Submitter
    ( Submitter (..)
    )
import Cardano.Node.Client.Validity
    ( ValidityChoice (..)
    )

import Amaru.Treasury.Trace
    ( Severity (..)
    )
import Amaru.Treasury.Trace.Provider
    ( renderTraceLine
    , tracedProvider
    , tracedQueryHandle
    , tracedSubmitter
    )

collectTracer
    :: IO (Tracer IO (Severity, Text), IO [(Severity, Text)])
collectTracer = do
    ref <- newIORef []
    let tr =
            Tracer $ \event ->
                atomicModifyIORef' ref $ \events ->
                    (event : events, ())
    pure (tr, reverse <$> readIORef ref)

messages :: [(Severity, Text)] -> [Text]
messages =
    fmap snd

expectTracedFailure
    :: Text -> IO () -> IO [(Severity, Text)]
expectTracedFailure _label action = do
    result <- try @SomeException action
    case result of
        Left err ->
            T.pack (show err) `shouldSatisfy` T.isInfixOf "boom:"
        Right () ->
            expectationFailure "expected traced fake method to fail"
    pure []

assertLabelFailed :: Text -> [(Severity, Text)] -> IO ()
assertLabelFailed label events = do
    fmap fst matching `shouldBe` [Info, Info]
    messages matching
        `shouldSatisfy` \case
            [start, failed] ->
                label `T.isInfixOf` start
                    && "start" `T.isInfixOf` start
                    && label `T.isInfixOf` failed
                    && "failed" `T.isInfixOf` failed
                    && "boom:" `T.isInfixOf` failed
            _ -> False
  where
    matching =
        filter ((label `T.isInfixOf`) . snd) events

boom :: String -> IO a
boom name =
    ioError (userError ("boom: " <> name))

fakeProvider :: Provider IO
fakeProvider =
    Provider
        { withAcquired = \callback -> callback fakeQueryHandle
        , queryUTxOs = \_ -> boom "queryUTxOs"
        , queryUTxOByTxIn = \_ -> boom "queryUTxOByTxIn"
        , queryProtocolParams = boom "queryProtocolParams"
        , queryLedgerSnapshot = boom "queryLedgerSnapshot"
        , queryStakeRewards = \_ -> boom "queryStakeRewards"
        , queryRewardAccounts = \_ -> boom "queryRewardAccounts"
        , queryVoteDelegatees = \_ -> boom "queryVoteDelegatees"
        , queryTreasury = boom "queryTreasury"
        , queryGovernanceState = boom "queryGovernanceState"
        , evaluateTx = \_ -> boom "evaluateTx"
        , posixMsToSlot = \_ -> boom "posixMsToSlot"
        , posixMsCeilSlot = \_ -> boom "posixMsCeilSlot"
        , queryUpperBoundSlot = \_ -> boom "queryUpperBoundSlot"
        }

fakeQueryHandle :: QueryHandle IO
fakeQueryHandle =
    mkQueryHandle
        QueryHandleBackend
            { backendQueryUTxOs = \_ -> boom "queryUTxOsH"
            , backendQueryUTxOsAt = \_ -> boom "queryUTxOsAtH"
            , backendQueryUTxOByTxIn = \_ -> boom "queryUTxOByTxInH"
            , backendQueryProtocolParams = boom "queryProtocolParamsH"
            , backendQueryLedgerSnapshot = boom "queryLedgerSnapshotH"
            , backendQueryStakeRewards = \_ -> boom "queryStakeRewardsH"
            , backendQueryRewardAccounts = \_ ->
                boom "queryRewardAccountsH"
            , backendQueryVoteDelegatees = \_ ->
                boom "queryVoteDelegateesH"
            , backendQueryTreasury = boom "queryTreasuryH"
            , backendQueryGovernanceState = boom "queryGovernanceStateH"
            , backendEvaluateTx = \_ -> boom "evaluateTxH"
            , backendPosixMsToSlot = \_ -> boom "posixMsToSlotH"
            , backendPosixMsCeilSlot = \_ -> boom "posixMsCeilSlotH"
            }

fakeSubmitter :: Submitter IO
fakeSubmitter =
    Submitter
        { submitTx = \_ -> boom "submitTx"
        }

providerActions
    :: Provider IO -> [(Text, IO ())]
providerActions provider =
    [ ("provider.queryUTxOs", voidIO $ queryUTxOs provider undefined)
    ,
        ( "provider.queryUTxOByTxIn"
        , voidIO $ queryUTxOByTxIn provider Set.empty
        )
    ,
        ( "provider.queryProtocolParams"
        , voidIO $ queryProtocolParams provider
        )
    ,
        ( "provider.queryLedgerSnapshot"
        , voidIO $ queryLedgerSnapshot provider
        )
    ,
        ( "provider.queryStakeRewards"
        , voidIO $ queryStakeRewards provider Set.empty
        )
    ,
        ( "provider.queryRewardAccounts"
        , voidIO $ queryRewardAccounts provider Set.empty
        )
    ,
        ( "provider.queryVoteDelegatees"
        , voidIO $ queryVoteDelegatees provider Set.empty
        )
    , ("provider.queryTreasury", voidIO $ queryTreasury provider)
    ,
        ( "provider.queryGovernanceState"
        , voidIO $ queryGovernanceState provider
        )
    , ("provider.evaluateTx", voidIO $ evaluateTx provider undefined)
    , ("provider.posixMsToSlot", voidIO $ posixMsToSlot provider 0)
    , ("provider.posixMsCeilSlot", voidIO $ posixMsCeilSlot provider 0)
    ,
        ( "provider.queryUpperBoundSlot"
        , voidIO $ queryUpperBoundSlot provider AutoLongest
        )
    ]

queryHandleActions
    :: QueryHandle IO -> [(Text, IO ())]
queryHandleActions handle =
    [
        ( "provider.handle.queryUTxOsH"
        , voidIO $ queryUTxOsH handle undefined
        )
    ,
        ( "provider.handle.queryUTxOsAtH"
        , voidIO $ queryUTxOsAtH handle Set.empty
        )
    ,
        ( "provider.handle.queryUTxOByTxInH"
        , voidIO $ queryUTxOByTxInH handle Set.empty
        )
    ,
        ( "provider.handle.queryProtocolParamsH"
        , voidIO $ queryProtocolParamsH handle
        )
    ,
        ( "provider.handle.queryLedgerSnapshotH"
        , voidIO $ queryLedgerSnapshotH handle
        )
    ,
        ( "provider.handle.queryStakeRewardsH"
        , voidIO $ queryStakeRewardsH handle Set.empty
        )
    ,
        ( "provider.handle.queryRewardAccountsH"
        , voidIO $ queryRewardAccountsH handle Set.empty
        )
    ,
        ( "provider.handle.queryVoteDelegateesH"
        , voidIO $ queryVoteDelegateesH handle Set.empty
        )
    ,
        ( "provider.handle.queryTreasuryH"
        , voidIO $ queryTreasuryH handle
        )
    ,
        ( "provider.handle.queryGovernanceStateH"
        , voidIO $ queryGovernanceStateH handle
        )
    ,
        ( "provider.handle.evaluateTxH"
        , voidIO $ evaluateTxH handle undefined
        )
    ,
        ( "provider.handle.posixMsToSlotH"
        , voidIO $ posixMsToSlotH handle 0
        )
    ,
        ( "provider.handle.posixMsCeilSlotH"
        , voidIO $ posixMsCeilSlotH handle 0
        )
    ]

voidIO :: IO a -> IO ()
voidIO action =
    action >> pure ()

spec :: Spec
spec = describe "/Trace.Provider/" $ do
    it "renders stderr trace lines with severity and message" $
        renderTraceLine Warning "socket unavailable"
            `shouldBe` "[Warning] socket unavailable"

    it "wraps every direct provider method" $ do
        (tr, readEvents) <- collectTracer
        let provider = tracedProvider tr fakeProvider
        mapM_ (uncurry expectTracedFailure) (providerActions provider)
        events <- readEvents
        mapM_ (`assertLabelFailed` events) (fst <$> providerActions provider)

    it "wraps acquired handles supplied through withAcquired" $ do
        (tr, readEvents) <- collectTracer
        let provider = tracedProvider tr fakeProvider
        _ <-
            expectTracedFailure "provider.withAcquired" $
                withAcquired provider $ \handle ->
                    voidIO $ queryProtocolParamsH handle
        events <- readEvents
        assertLabelFailed "provider.withAcquired" events
        assertLabelFailed "provider.handle.queryProtocolParamsH" events

    it "wraps every acquired query handle method" $ do
        (tr, readEvents) <- collectTracer
        let handle = tracedQueryHandle tr fakeQueryHandle
        mapM_ (uncurry expectTracedFailure) (queryHandleActions handle)
        events <- readEvents
        mapM_ (`assertLabelFailed` events) (fst <$> queryHandleActions handle)

    it "wraps transaction submission" $ do
        (tr, readEvents) <- collectTracer
        let submitter = tracedSubmitter tr fakeSubmitter
        _ <-
            expectTracedFailure "submitter.submitTx" $
                voidIO $
                    submitTx submitter undefined
        events <- readEvents
        assertLabelFailed "submitter.submitTx" events
