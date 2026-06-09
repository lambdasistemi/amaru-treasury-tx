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
    , queryScopeHistoryFilteredResponse
    , queryScopeHistoryQueryResponse
    , queryScopeHistoryShaclResponse
    , queryTxDetailResponse
    , historyResponseFromEntries
    , historyEntryFromSummary
    , txDetailResponseFromSummary
    , outputFromSummary
    , outputScopeRoles
    ) where

import Data.Aeson (decodeStrict)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
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
    , TxSummary (..)
    , TxSummaryEntry (..)
    , TxSummaryInput (..)
    , TxSummaryKey (..)
    , TxSummaryOutput (..)
    )
import Cardano.Slotting.Slot (SlotNo (..))

import Amaru.Treasury.Api.Types
    ( ScopeHistoryEntry (..)
    , ScopeHistoryQueryResponse (..)
    , ScopeHistoryResponse (..)
    , ScopeHistoryShaclResponse (..)
    , TxDetailInput (..)
    , TxDetailOutput (..)
    , TxDetailResponse (..)
    , TxIdParam (..)
    )
import Amaru.Treasury.Cli.History
    ( queryTxDetail
    , renderTxDetail
    )
import Amaru.Treasury.History.Sparql
    ( HistoryFilter
    , HistoryQueryName
    , HistoryQueryResult (..)
    , HistoryShaclResult (..)
    , HistoryShapeName
    , emptyHistoryFilter
    , filterHistoryEntries
    , renderHistoryQueryName
    , renderHistoryShapeName
    , renderHistorySparqlError
    , runNamedHistoryQuery
    , runNamedHistoryShacl
    )
import Amaru.Treasury.Indexer.Decoder (treasuryTenantId)
import Amaru.Treasury.Metadata
    ( ScopeMetadata (..)
    , TreasuryMetadata (..)
    )
import Amaru.Treasury.Report.Accounting
    ( ValueSummary
    , emptyValue
    )
import Amaru.Treasury.Scope
    ( ScopeId
    , scopeText
    )

-- | Query the local history store for one treasury scope.
queryScopeHistoryResponse
    :: HistoryIndexer -> ScopeId -> IO ScopeHistoryResponse
queryScopeHistoryResponse idx scope =
    queryScopeHistoryFilteredResponse idx scope emptyHistoryFilter

-- | Query and filter the local history store for one treasury scope.
queryScopeHistoryFilteredResponse
    :: HistoryIndexer -> ScopeId -> HistoryFilter -> IO ScopeHistoryResponse
queryScopeHistoryFilteredResponse idx scope flt = do
    entries <- queryScopeEntries idx scope
    filtered <- filterHistoryEntries flt entries
    case filtered of
        Right rows -> pure (historyResponseFromEntries scope rows)
        Left err -> fail (T.unpack (renderHistorySparqlError err))

-- | Run one named RDF/SPARQL query over one indexed treasury scope.
queryScopeHistoryQueryResponse
    :: HistoryIndexer
    -> Maybe TreasuryMetadata
    -> ScopeId
    -> HistoryQueryName
    -> IO ScopeHistoryQueryResponse
queryScopeHistoryQueryResponse idx metadata scope queryName = do
    entries <- queryScopeEntries idx scope
    result <- runNamedHistoryQuery queryName metadata entries
    case result of
        Right resultTable ->
            pure
                ScopeHistoryQueryResponse
                    { shqrScope = scope
                    , shqrQuery =
                        renderHistoryQueryName (hqrQuery resultTable)
                    , shqrColumns = hqrColumns resultTable
                    , shqrRows = hqrRows resultTable
                    }
        Left err -> fail (T.unpack (renderHistorySparqlError err))

-- | Run one named RDF/SHACL validation over one indexed treasury scope.
queryScopeHistoryShaclResponse
    :: HistoryIndexer
    -> Maybe TreasuryMetadata
    -> ScopeId
    -> HistoryShapeName
    -> IO ScopeHistoryShaclResponse
queryScopeHistoryShaclResponse idx metadata scope shapeName = do
    entries <- queryScopeEntries idx scope
    result <- runNamedHistoryShacl shapeName metadata entries
    case result of
        Right resultReport ->
            pure
                ScopeHistoryShaclResponse
                    { shsrScope = scope
                    , shsrShape =
                        renderHistoryShapeName (hsrShape resultReport)
                    , shsrConforms = hsrConforms resultReport
                    , shsrReport = hsrReport resultReport
                    }
        Left err -> fail (T.unpack (renderHistorySparqlError err))

{- | Query the local history store for one transaction detail.

@metadata@, when supplied, lets each output address be resolved to
its owning treasury @{scope, role}@; pass 'Nothing' to skip
resolution.
-}
queryTxDetailResponse
    :: HistoryIndexer
    -> Maybe TreasuryMetadata
    -> TxIdParam
    -> IO (Maybe TxDetailResponse)
queryTxDetailResponse idx metadata (TxIdParam txid) =
    fmap (txDetailResponseFromSummary metadata)
        <$> queryTxDetail idx txid

queryScopeEntries :: HistoryIndexer -> ScopeId -> IO [TxSummaryEntry]
queryScopeEntries idx scope =
    queryHistory idx treasuryTenantId (scopeHistoryScope scope)

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

{- | Convert the CLI tx-detail summary into the HTTP response shape.

When @metadata@ is supplied, each output address is resolved to its
owning treasury @{scope, role}@. Input source addresses and values
are not resolved here: the summary carries inputs only as
@txid#ix@ references, and resolving them needs a per-input UTxO
lookup the local history handle does not perform.
-}
txDetailResponseFromSummary
    :: Maybe TreasuryMetadata -> TxSummary -> TxDetailResponse
txDetailResponseFromSummary metadata summary =
    TxDetailResponse
        { tdrSlot = unSlotNo (tskSlot key)
        , tdrTxId = txIdText (tskTxId key)
        , tdrScope = scopeTextOf (tskScope key)
        , tdrRole = roleText (tskRole key)
        , tdrDirection = directionText (txsDirection summary)
        , tdrBlockHash = hexText <$> txsBlockHash summary
        , tdrFee = txsFee summary
        , tdrRequiredSigners = bytesText <$> txsRequiredSigners summary
        , tdrRedeemer = bytesText <$> txsRedeemer summary
        , tdrInputs = inputFromSummary <$> txsInputs summary
        , tdrOutputs =
            zipWith
                (outputFromSummary (outputScopeRoles metadata))
                [(0 :: Int) ..]
                (txsOutputs summary)
        , tdrLines = renderTxDetail summary
        }
  where
    key = txsKey summary

inputFromSummary :: TxSummaryInput -> TxDetailInput
inputFromSummary input =
    TxDetailInput
        { tdiTxIn = bytesText (tsiTxIn input)
        , tdiScope = scopeTextOf <$> tsiScope input
        , tdiValue = bytesText (tsiValue input)
        }

{- | Build one detail output, labelling its address with the owning
treasury @{scope, role}@ when @roles@ knows it and surfacing the
structured ledger value.
-}
outputFromSummary
    :: Map Text (Text, Text) -> Int -> TxSummaryOutput -> TxDetailOutput
outputFromSummary roles ix output =
    TxDetailOutput
        { tdoIndex = ix
        , tdoAddress = address
        , tdoScope = fst <$> resolved
        , tdoRole = snd <$> resolved
        , tdoValue = decodeValueSummary (tsoValue output)
        , tdoDatum = bytesText <$> tsoDatum output
        }
  where
    address = bytesText (tsoAddress output)
    resolved = Map.lookup address roles

{- | Address → @(scope, role)@ for the known treasury outputs in
verified metadata.

Only the per-scope treasury address (@smAddress@) can appear as a
payment output, so it is the sole entry: it resolves to its scope
and the @treasury@ role, matching the @atx:TreasuryEntity@ role
vocabulary emitted for RDF inspection. Owner key-hashes and script
references are never output addresses, so they are intentionally
absent. Returns an empty map when no metadata is available.
-}
outputScopeRoles :: Maybe TreasuryMetadata -> Map Text (Text, Text)
outputScopeRoles Nothing = Map.empty
outputScopeRoles (Just metadata) =
    Map.fromList
        [ (smAddress sm, (scopeText scope, "treasury"))
        | (scope, sm) <- Map.toList (tmTreasuries metadata)
        ]

{- | Decode the indexer's structured value bytes back into a
'ValueSummary'; the decoder always stores valid JSON, so a decode
miss degrades to the empty value rather than failing the response.
-}
decodeValueSummary :: BS.ByteString -> ValueSummary
decodeValueSummary = fromMaybe emptyValue . decodeStrict

txIdText :: TxId -> Text
txIdText = hexText . unTxId

hexText :: BS.ByteString -> Text
hexText = TE.decodeUtf8 . B16.encode

scopeTextOf :: HistoryScope -> Text
scopeTextOf = bytesText . unHistoryScope

bytesText :: BS.ByteString -> Text
bytesText = TE.decodeUtf8Lenient
