{- |
Module      : Amaru.Treasury.Trace.Provider
Description : Tracing wrappers for provider boundary records
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0
-}
module Amaru.Treasury.Trace.Provider
    ( -- * Stderr rendering
      stderrTracer
    , renderTraceLine

      -- * Boundary wrappers
    , tracedProvider
    , tracedQueryHandle
    , tracedSubmitter
    ) where

import Control.Tracer
    ( Tracer (..)
    )
import Data.Text
    ( Text
    )
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.IO
    ( stderr
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

import Amaru.Treasury.Trace
    ( Severity (..)
    , traced
    )

-- | Emit rendered trace events to standard error.
stderrTracer :: Tracer IO (Severity, Text)
stderrTracer =
    Tracer $ \(severity, message) ->
        TIO.hPutStrLn stderr (renderTraceLine severity message)

-- | Render one severity-tagged trace line.
renderTraceLine :: Severity -> Text -> Text
renderTraceLine severity message =
    "["
        <> T.pack (show severity)
        <> "] "
        <> message

-- | Wrap every method in a 'Provider IO' with construction-time traces.
tracedProvider
    :: Tracer IO (Severity, Text) -> Provider IO -> Provider IO
tracedProvider tr provider =
    Provider
        { withAcquired = \callback ->
            traceInfo "provider.withAcquired" $
                withAcquired provider $
                    \handle -> callback (tracedQueryHandle tr handle)
        , queryUTxOs = \addr ->
            traceInfo "provider.queryUTxOs" $
                queryUTxOs provider addr
        , queryUTxOByTxIn = \txIns ->
            traceInfo "provider.queryUTxOByTxIn" $
                queryUTxOByTxIn provider txIns
        , queryProtocolParams =
            traceInfo "provider.queryProtocolParams" $
                queryProtocolParams provider
        , queryLedgerSnapshot =
            traceInfo "provider.queryLedgerSnapshot" $
                queryLedgerSnapshot provider
        , queryStakeRewards = \credentials ->
            traceInfo "provider.queryStakeRewards" $
                queryStakeRewards provider credentials
        , queryRewardAccounts = \accounts ->
            traceInfo "provider.queryRewardAccounts" $
                queryRewardAccounts provider accounts
        , queryVoteDelegatees = \credentials ->
            traceInfo "provider.queryVoteDelegatees" $
                queryVoteDelegatees provider credentials
        , queryTreasury =
            traceInfo "provider.queryTreasury" $
                queryTreasury provider
        , queryGovernanceState =
            traceInfo "provider.queryGovernanceState" $
                queryGovernanceState provider
        , evaluateTx = \tx ->
            traceInfo "provider.evaluateTx" $
                evaluateTx provider tx
        , posixMsToSlot = \posixMs ->
            traceInfo "provider.posixMsToSlot" $
                posixMsToSlot provider posixMs
        , posixMsCeilSlot = \posixMs ->
            traceInfo "provider.posixMsCeilSlot" $
                posixMsCeilSlot provider posixMs
        , queryUpperBoundSlot = \choice ->
            traceInfo "provider.queryUpperBoundSlot" $
                queryUpperBoundSlot provider choice
        }
  where
    traceInfo :: Text -> IO a -> IO a
    traceInfo =
        traced tr Info

-- | Wrap every method in an acquired 'QueryHandle IO' with traces.
tracedQueryHandle
    :: Tracer IO (Severity, Text) -> QueryHandle IO -> QueryHandle IO
tracedQueryHandle tr handle =
    mkQueryHandle
        QueryHandleBackend
            { backendQueryUTxOs = \addr ->
                traceInfo "provider.handle.queryUTxOsH" $
                    queryUTxOsH handle addr
            , backendQueryUTxOsAt = \addrs ->
                traceInfo "provider.handle.queryUTxOsAtH" $
                    queryUTxOsAtH handle addrs
            , backendQueryUTxOByTxIn = \txIns ->
                traceInfo "provider.handle.queryUTxOByTxInH" $
                    queryUTxOByTxInH handle txIns
            , backendQueryProtocolParams =
                traceInfo "provider.handle.queryProtocolParamsH" $
                    queryProtocolParamsH handle
            , backendQueryLedgerSnapshot =
                traceInfo "provider.handle.queryLedgerSnapshotH" $
                    queryLedgerSnapshotH handle
            , backendQueryStakeRewards = \credentials ->
                traceInfo "provider.handle.queryStakeRewardsH" $
                    queryStakeRewardsH handle credentials
            , backendQueryRewardAccounts = \accounts ->
                traceInfo "provider.handle.queryRewardAccountsH" $
                    queryRewardAccountsH handle accounts
            , backendQueryVoteDelegatees = \credentials ->
                traceInfo "provider.handle.queryVoteDelegateesH" $
                    queryVoteDelegateesH handle credentials
            , backendQueryTreasury =
                traceInfo "provider.handle.queryTreasuryH" $
                    queryTreasuryH handle
            , backendQueryGovernanceState =
                traceInfo "provider.handle.queryGovernanceStateH" $
                    queryGovernanceStateH handle
            , backendEvaluateTx = \tx ->
                traceInfo "provider.handle.evaluateTxH" $
                    evaluateTxH handle tx
            , backendPosixMsToSlot = \posixMs ->
                traceInfo "provider.handle.posixMsToSlotH" $
                    posixMsToSlotH handle posixMs
            , backendPosixMsCeilSlot = \posixMs ->
                traceInfo "provider.handle.posixMsCeilSlotH" $
                    posixMsCeilSlotH handle posixMs
            }
  where
    traceInfo :: Text -> IO a -> IO a
    traceInfo =
        traced tr Info

-- | Wrap transaction submission with traces.
tracedSubmitter
    :: Tracer IO (Severity, Text) -> Submitter IO -> Submitter IO
tracedSubmitter tr submitter =
    Submitter
        { submitTx = \tx ->
            traced tr Info "submitter.submitTx" $
                submitTx submitter tx
        }
