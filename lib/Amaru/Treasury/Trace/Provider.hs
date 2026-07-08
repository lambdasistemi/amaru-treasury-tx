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
        , queryUTxOs =
            traceInfo "provider.queryUTxOs" . queryUTxOs provider
        , queryUTxOByTxIn =
            traceInfo "provider.queryUTxOByTxIn"
                . queryUTxOByTxIn provider
        , queryProtocolParams =
            traceInfo "provider.queryProtocolParams" $
                queryProtocolParams provider
        , queryLedgerSnapshot =
            traceInfo "provider.queryLedgerSnapshot" $
                queryLedgerSnapshot provider
        , queryStakeRewards =
            traceInfo "provider.queryStakeRewards"
                . queryStakeRewards provider
        , queryRewardAccounts =
            traceInfo "provider.queryRewardAccounts"
                . queryRewardAccounts provider
        , queryVoteDelegatees =
            traceInfo "provider.queryVoteDelegatees"
                . queryVoteDelegatees provider
        , queryTreasury =
            traceInfo "provider.queryTreasury" $
                queryTreasury provider
        , queryGovernanceState =
            traceInfo "provider.queryGovernanceState" $
                queryGovernanceState provider
        , evaluateTx =
            traceInfo "provider.evaluateTx" . evaluateTx provider
        , posixMsToSlot =
            traceInfo "provider.posixMsToSlot" . posixMsToSlot provider
        , posixMsCeilSlot =
            traceInfo "provider.posixMsCeilSlot"
                . posixMsCeilSlot provider
        , queryUpperBoundSlot =
            traceInfo "provider.queryUpperBoundSlot"
                . queryUpperBoundSlot provider
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
            { backendQueryUTxOs =
                traceInfo "provider.handle.queryUTxOsH"
                    . queryUTxOsH handle
            , backendQueryUTxOsAt =
                traceInfo "provider.handle.queryUTxOsAtH"
                    . queryUTxOsAtH handle
            , backendQueryUTxOByTxIn =
                traceInfo "provider.handle.queryUTxOByTxInH"
                    . queryUTxOByTxInH handle
            , backendQueryProtocolParams =
                traceInfo "provider.handle.queryProtocolParamsH" $
                    queryProtocolParamsH handle
            , backendQueryLedgerSnapshot =
                traceInfo "provider.handle.queryLedgerSnapshotH" $
                    queryLedgerSnapshotH handle
            , backendQueryStakeRewards =
                traceInfo "provider.handle.queryStakeRewardsH"
                    . queryStakeRewardsH handle
            , backendQueryRewardAccounts =
                traceInfo "provider.handle.queryRewardAccountsH"
                    . queryRewardAccountsH handle
            , backendQueryVoteDelegatees =
                traceInfo "provider.handle.queryVoteDelegateesH"
                    . queryVoteDelegateesH handle
            , backendQueryTreasury =
                traceInfo "provider.handle.queryTreasuryH" $
                    queryTreasuryH handle
            , backendQueryGovernanceState =
                traceInfo "provider.handle.queryGovernanceStateH" $
                    queryGovernanceStateH handle
            , backendEvaluateTx =
                traceInfo "provider.handle.evaluateTxH" . evaluateTxH handle
            , backendPosixMsToSlot =
                traceInfo "provider.handle.posixMsToSlotH"
                    . posixMsToSlotH handle
            , backendPosixMsCeilSlot =
                traceInfo "provider.handle.posixMsCeilSlotH"
                    . posixMsCeilSlotH handle
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
        { submitTx =
            traced tr Info "submitter.submitTx" . submitTx submitter
        }
