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
    , inputFromSummary
    , outputFromSummary
    , outputScopeRoles
    , outputSwapProjection
    , renderInputAddress
    ) where

import Data.Aeson (decodeStrict)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.Either (fromRight)
import Data.Foldable (toList)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Lens.Micro ((^.))

import Cardano.Ledger.Address
    ( Addr
    , getNetwork
    , serialiseAddr
    )
import Cardano.Ledger.Alonzo.TxWits (Redeemers (..))
import Cardano.Ledger.Api.Tx (witsTxL)
import Cardano.Ledger.Api.Tx.Body
    ( inputsTxBodyL
    , outputsTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , addrTxOutL
    , datumTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.Api.Tx.Wits (rdmrsTxWitsL)
import Cardano.Ledger.BaseTypes (Network (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (bodyTxL)
import Cardano.Ledger.Plutus.Data qualified as PlutusData
import Cardano.Ledger.TxIn qualified as Ledger
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
import Cardano.Tx.Ledger (ConwayTx)
import Codec.Binary.Bech32 qualified as Bech32

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
import Amaru.Treasury.Indexer.Decoder
    ( decodeConwayTx
    , treasuryTenantId
    )
import Amaru.Treasury.Inspect.SwapOrderProjection
    ( ProjectedSwapOrder
    , projectSwapOrderDatum
    )
import Amaru.Treasury.Inspect.TreasurySpendProjection
    ( ProjectedTreasurySpend
    , projectTreasurySpendRedeemer
    )
import Amaru.Treasury.Metadata
    ( ScopeMetadata (..)
    , TreasuryMetadata (..)
    )
import Amaru.Treasury.Report.Accounting
    ( ValueSummary
    , emptyValue
    , valueSummary
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

{- | Query the local history store for one transaction detail and
resolve its inputs against the indexed UTxO state.

@metadata@, when supplied, lets each output /and resolved input/
address be resolved to its owning treasury @{scope, role}@; pass
'Nothing' to skip resolution.

@resolveUtxos@ looks each input outref up in the indexed UTxO state —
in the API container this is
'Amaru.Treasury.Api.Indexer.snapshotUtxosByTxIn', which returns the
produced 'TxOut' for inputs the indexer still holds and omits those
that are spent and pruned. The produced output's source address and
value then label the input the same way outputs are labelled.
-}
queryTxDetailResponse
    :: (Set Ledger.TxIn -> IO (Map Ledger.TxIn (TxOut ConwayEra)))
    -> HistoryIndexer
    -> Maybe TreasuryMetadata
    -> TxIdParam
    -> IO (Maybe TxDetailResponse)
queryTxDetailResponse resolveUtxos idx metadata (TxIdParam txid) =
    queryTxDetail idx txid
        >>= traverse (resolveTxDetail resolveUtxos metadata)

{- | Resolve a tx summary's input outrefs against the indexed UTxO
state, then build the HTTP detail response. The body inputs are taken
in the deterministic ascending order the indexer decoder uses to file
'txsInputs', so the resolved 'TxOut's align positionally with the
summary's input rows.
-}
resolveTxDetail
    :: (Set Ledger.TxIn -> IO (Map Ledger.TxIn (TxOut ConwayEra)))
    -> Maybe TreasuryMetadata
    -> TxSummary
    -> IO TxDetailResponse
resolveTxDetail resolveUtxos metadata summary = do
    let inputs =
            maybe [] bodyInputsAsc (decodeConwayTx (txsPayload summary))
    utxos <- resolveUtxos (Set.fromList inputs)
    let resolved = [Map.lookup txIn utxos | txIn <- inputs]
    pure (txDetailResponseFromSummary metadata resolved summary)

{- | Transaction body inputs in the deterministic ascending order the
indexer decoder ('Amaru.Treasury.Indexer.Decoder') uses to build
'txsInputs', so a resolved 'TxOut' list zips positionally with the
summary input rows.
-}
bodyInputsAsc :: ConwayTx -> [Ledger.TxIn]
bodyInputsAsc tx = Set.toAscList (tx ^. bodyTxL . inputsTxBodyL)

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
owning treasury @{scope, role}@. @resolvedInputs@ carries, positionally
aligned with the summary's input rows, the produced 'TxOut' each input
outref points at when the indexed UTxO state still holds it ('Just') or
'Nothing' when it is spent and pruned; a resolved input's source
address is labelled the same way an output address is. The list is
padded with 'Nothing' so a short or empty resolution (e.g. a tx whose
CBOR could not be reconstructed) leaves every input unresolved rather
than dropping rows.
-}
txDetailResponseFromSummary
    :: Maybe TreasuryMetadata
    -> [Maybe (TxOut ConwayEra)]
    -> TxSummary
    -> TxDetailResponse
txDetailResponseFromSummary metadata resolvedInputs summary =
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
        , tdrProjectedRedeemers = spendRedeemerProjections decodedTx
        , tdrInputs =
            zipWith
                (inputFromSummary (outputScopeRoles metadata))
                (resolvedInputs <> repeat Nothing)
                (txsInputs summary)
        , tdrOutputs =
            zipWith3
                (outputFromSummary (outputScopeRoles metadata))
                (outputSwapProjections decodedTx)
                [(0 :: Int) ..]
                (txsOutputs summary)
        , tdrLines = renderTxDetail summary
        }
  where
    key = txsKey summary
    decodedTx = decodeConwayTx (txsPayload summary)

{- | Typed projections of every @treasury.treasury.spend@ redeemer in
the reconstructed transaction, decoded against the embedded CIP-57
blueprint via 'projectTreasurySpendRedeemer'. Redeemers that are not a
@TreasurySpendRedeemer@ (e.g. the permissions withdraw-zero entry)
decode to 'Left' and are dropped.
-}
spendRedeemerProjections :: Maybe ConwayTx -> [ProjectedTreasurySpend]
spendRedeemerProjections Nothing = []
spendRedeemerProjections (Just tx) =
    let Redeemers redeemers = tx ^. witsTxL . rdmrsTxWitsL
    in  [ projected
        | (redeemer, _exUnits) <- Map.elems redeemers
        , Right projected <- [projectTreasurySpendRedeemer redeemer]
        ]

{- | Per-output SundaeSwap order datum projections, aligned with
'txsOutputs' order. An output carries 'Just' a projection only when it
has an inline datum that decodes against the @OrderDatum@ blueprint;
all other outputs (and a transaction whose CBOR cannot be
reconstructed) are 'Nothing'.
-}
outputSwapProjections :: Maybe ConwayTx -> [Maybe ProjectedSwapOrder]
outputSwapProjections Nothing = repeat Nothing
outputSwapProjections (Just tx) =
    [ outputSwapProjection txOut
    | txOut <- toList (tx ^. bodyTxL . outputsTxBodyL)
    ]

outputSwapProjection
    :: TxOut ConwayEra -> Maybe ProjectedSwapOrder
outputSwapProjection txOut =
    case txOut ^. datumTxOutL of
        PlutusData.Datum binaryDatum ->
            either
                (const Nothing)
                Just
                (projectSwapOrderDatum (PlutusData.binaryDataToData binaryDatum))
        _ -> Nothing

{- | Build one detail input. When the indexed UTxO state still holds
the produced output the @txid#ix@ outref points at (@Just txOut@),
render its source address and look it up in the same @roles@ map the
outputs use to label the input's owning treasury @{scope, role}@,
surface the structured produced value, and mark it @resolved@. When the
source UTxO is spent and pruned (@Nothing@), the input keeps null
scope\/role\/value and @resolved = False@ as the explicit marker.
-}
inputFromSummary
    :: Map Text (Text, Text)
    -> Maybe (TxOut ConwayEra)
    -> TxSummaryInput
    -> TxDetailInput
inputFromSummary roles mResolved input =
    case mResolved of
        Just txOut ->
            TxDetailInput
                { tdiTxIn = txInText
                , tdiScope = fst <$> resolved
                , tdiRole = snd <$> resolved
                , tdiValue = Just (valueSummary (txOut ^. valueTxOutL))
                , tdiResolved = True
                }
          where
            resolved =
                Map.lookup
                    (renderInputAddress (txOut ^. addrTxOutL))
                    roles
        Nothing ->
            TxDetailInput
                { tdiTxIn = txInText
                , tdiScope = Nothing
                , tdiRole = Nothing
                , tdiValue = Nothing
                , tdiResolved = False
                }
  where
    txInText = bytesText (tsiTxIn input)

{- | Bech32-render a resolved input's source address into the same
string form the indexer decoder writes for output addresses (the
@smAddress@ keys 'outputScopeRoles' is built from), so one @roles@ map
labels both inputs and outputs. Mirrors the decoder's
@serialiseAddr@ + network-tagged HRP encoding.
-}
renderInputAddress :: Addr -> Text
renderInputAddress addr =
    Bech32.encodeLenient
        hrp
        (Bech32.dataPartFromBytes (serialiseAddr addr))
  where
    hrp =
        fromRight
            (error "renderInputAddress: invalid hrp")
            (Bech32.humanReadablePartFromText prefix)
    prefix =
        case getNetwork addr of
            Mainnet -> "addr"
            Testnet -> "addr_test"

{- | Build one detail output, labelling its address with the owning
treasury @{scope, role}@ when @roles@ knows it, surfacing the
structured ledger value, and attaching the decoded swap-order datum
@projection@ when the output carries one.
-}
outputFromSummary
    :: Map Text (Text, Text)
    -> Maybe ProjectedSwapOrder
    -> Int
    -> TxSummaryOutput
    -> TxDetailOutput
outputFromSummary roles projection ix output =
    TxDetailOutput
        { tdoIndex = ix
        , tdoAddress = address
        , tdoScope = fst <$> resolved
        , tdoRole = snd <$> resolved
        , tdoValue = decodeValueSummary (tsoValue output)
        , tdoDatum = bytesText <$> tsoDatum output
        , tdoProjectedDatum = projection
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
