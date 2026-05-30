{- |
Module      : Amaru.Treasury.Api.History
Description : HTTP response adapter for indexed treasury history
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Transforms the generic tx-history indexer's treasury rows into
the JSON carrier served by @GET /v1/scope/<scope>/txs@. The
query is local to the embedded RocksDB history handle opened by
@amaru-treasury-tx-api@; it performs no node-to-client UTxO
scan.
-}
module Amaru.Treasury.Api.History
    ( queryScopeHistoryResponse
    , historyResponseFromEntries
    , historyEntryFromSummary
    ) where

import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.Text (Text)
import Data.Text.Encoding qualified as TE

import Cardano.Node.Client.TxHistoryIndexer.Indexer
    ( HistoryIndexer
    , queryHistory
    )
import Cardano.Node.Client.TxHistoryIndexer.Types
    ( HistoryScope (..)
    , TxDirection (..)
    , TxId (..)
    , TxRole (..)
    , TxSummaryEntry (..)
    , TxSummaryKey (..)
    )
import Cardano.Slotting.Slot (SlotNo (..))

import Amaru.Treasury.Api.Types
    ( ScopeHistoryEntry (..)
    , ScopeHistoryResponse (..)
    )
import Amaru.Treasury.Indexer.Decoder (treasuryTenantId)
import Amaru.Treasury.Scope
    ( ScopeId
    , scopeText
    )

-- | Query the local history store for one treasury scope.
queryScopeHistoryResponse
    :: HistoryIndexer -> ScopeId -> IO ScopeHistoryResponse
queryScopeHistoryResponse idx scope =
    historyResponseFromEntries scope
        <$> queryHistory idx treasuryTenantId (scopeHistoryScope scope)

-- | Convert raw summary entries to the HTTP response shape.
historyResponseFromEntries
    :: ScopeId -> [TxSummaryEntry] -> ScopeHistoryResponse
historyResponseFromEntries scope entries =
    ScopeHistoryResponse
        { shrScope = scope
        , shrEntries = historyEntryFromSummary <$> entries
        }

-- | Convert one generic tx-history row to the API row.
historyEntryFromSummary :: TxSummaryEntry -> ScopeHistoryEntry
historyEntryFromSummary entry =
    ScopeHistoryEntry
        { sheSlot = unSlotNo (tskSlot key)
        , sheTxId = TE.decodeUtf8 (B16.encode (unTxId (tskTxId key)))
        , sheRole = roleText (tskRole key)
        , sheDirection = directionText (tseDirection entry)
        }
  where
    key = tseKey entry

roleText :: TxRole -> Text
roleText role
    | BS.null (unTxRole role) = "-"
    | otherwise = TE.decodeUtf8 (unTxRole role)

directionText :: TxDirection -> Text
directionText = TE.decodeUtf8 . unTxDirection

scopeHistoryScope :: ScopeId -> HistoryScope
scopeHistoryScope =
    HistoryScope . TE.encodeUtf8 . scopeText
