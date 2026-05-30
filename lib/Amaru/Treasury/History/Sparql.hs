{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}

{- |
Module      : Amaru.Treasury.History.Sparql
Description : Named SPARQL queries over indexed treasury history
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

The tx-history indexer stores the raw transaction CBOR beside each
history row. This module turns those rows into a local RDF lattice:

* ATX metadata triples for slot, scope, role, and direction.
* Cardano ledger RDF body triples emitted from the raw transaction CBOR
  by the upstream @cq-rdf@ executable.

Callers can then run a small catalog of hard-coded SPARQL queries through
Apache Jena's @arq@ executable, or validate the graph through Apache
Jena's @shacl@ executable. The public surface accepts query and shape
names, not arbitrary text, so both CLI and HTTP can expose semantic RDF
analysis without becoming remote SPARQL or SHACL consoles.
-}
module Amaru.Treasury.History.Sparql
    ( -- * Filters
      HistoryFilter (..)
    , emptyHistoryFilter
    , filterHistoryEntries

      -- * Named queries
    , HistoryQueryName (..)
    , knownHistoryQueryNames
    , parseHistoryQueryName
    , renderHistoryQueryName
    , runNamedHistoryQuery

      -- * Query results
    , HistoryQueryResult (..)
    , historyQueryRowsTsv

      -- * SHACL validation
    , HistoryShapeName (..)
    , HistoryShaclResult (..)
    , historyShaclResultLines
    , knownHistoryShapeNames
    , parseHistoryShapeName
    , renderHistoryShapeName
    , runNamedHistoryShacl

      -- * Errors
    , HistorySparqlError (..)
    , renderHistorySparqlError
    ) where

import Control.Exception (IOException, try)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.FileEmbed (embedFile)
import Data.List qualified as List
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Read qualified as TR
import Data.Word (Word64)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (readProcessWithExitCode)
import Web.HttpApiData
    ( FromHttpApiData (..)
    , ToHttpApiData (..)
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

-- | User-facing filters shared by CLI and HTTP history surfaces.
data HistoryFilter = HistoryFilter
    { hfRole :: !(Maybe Text)
    -- ^ Exact treasury role label to keep, e.g. @disburse@ or
    --   @reorganize@. @Nothing@ keeps all roles.
    , hfAsset :: !(Maybe Text)
    -- ^ Asset label to keep from the RDF asset-flow query. @ada@
    --   matches lovelace rows; native assets match their
    --   @cardano:bytesHex@ asset-class identifier unless an overlay
    --   query maps them to a label.
    , hfDirection :: !(Maybe Text)
    -- ^ Direction label to keep, currently @inbound@ or @outbound@.
    , hfSince :: !(Maybe Word64)
    -- ^ Inclusive lower slot bound.
    , hfUntil :: !(Maybe Word64)
    -- ^ Inclusive upper slot bound.
    , hfLimit :: !(Maybe Int)
    -- ^ Maximum rows to return after all filters have matched.
    }
    deriving stock (Eq, Show)

-- | No-op history filter.
emptyHistoryFilter :: HistoryFilter
emptyHistoryFilter =
    HistoryFilter
        { hfRole = Nothing
        , hfAsset = Nothing
        , hfDirection = Nothing
        , hfSince = Nothing
        , hfUntil = Nothing
        , hfLimit = Nothing
        }

-- | The fixed query catalog exposed by ATX.
data HistoryQueryName
    = -- | ATX metadata rows: slot, txid, scope, role, direction.
      HistoryEntriesQuery
    | -- | Count distinct Cardano transaction subjects in the lattice.
      TxCountQuery
    | -- | Output asset movement facts from the Cardano RDF body graph.
      AssetFlowQuery
    | -- | Cross-transaction input-to-output spend edges.
      SpendEdgesQuery
    | -- | Operator overlay entity identifier counts.
      EntityOccurrencesQuery
    deriving stock (Eq, Ord, Show, Enum, Bounded)

instance ToHttpApiData HistoryQueryName where
    toUrlPiece = renderHistoryQueryName

instance FromHttpApiData HistoryQueryName where
    parseUrlPiece = parseHistoryQueryName

-- | Stable list of supported query names.
knownHistoryQueryNames :: [HistoryQueryName]
knownHistoryQueryNames = [minBound .. maxBound]

-- | Parse a query name accepted by the CLI and HTTP query param.
parseHistoryQueryName :: Text -> Either Text HistoryQueryName
parseHistoryQueryName raw =
    case T.toLower raw of
        "history-entries" -> Right HistoryEntriesQuery
        "tx-count" -> Right TxCountQuery
        "asset-flow" -> Right AssetFlowQuery
        "spend-edges" -> Right SpendEdgesQuery
        "entity-occurrences" -> Right EntityOccurrencesQuery
        other ->
            Left $
                "unknown history RDF query '"
                    <> other
                    <> "'; known queries: "
                    <> T.intercalate
                        ", "
                        (renderHistoryQueryName <$> knownHistoryQueryNames)

-- | Render the stable external query name.
renderHistoryQueryName :: HistoryQueryName -> Text
renderHistoryQueryName = \case
    HistoryEntriesQuery -> "history-entries"
    TxCountQuery -> "tx-count"
    AssetFlowQuery -> "asset-flow"
    SpendEdgesQuery -> "spend-edges"
    EntityOccurrencesQuery -> "entity-occurrences"

-- | SPARQL result table.
data HistoryQueryResult = HistoryQueryResult
    { hqrQuery :: !HistoryQueryName
    -- ^ Server-side query that produced this table.
    , hqrColumns :: ![Text]
    -- ^ SPARQL variable names without the leading @?@.
    , hqrRows :: ![[Text]]
    -- ^ Result cells in 'hqrColumns' order, one inner list per row.
    }
    deriving stock (Eq, Show)

-- | Render a result table as tab-separated text.
historyQueryRowsTsv :: HistoryQueryResult -> [Text]
historyQueryRowsTsv HistoryQueryResult{..} =
    T.intercalate "\t" hqrColumns
        : (T.intercalate "\t" <$> hqrRows)

-- | The fixed SHACL validation catalog exposed by ATX.
data HistoryShapeName
    = -- | Validate ATX metadata fields on every history entry.
      HistoryEntryShape
    | -- | Validate that every history entry points at an emitted
      --   Cardano transaction body subject.
      IndexedTxBodyShape
    deriving stock (Eq, Ord, Show, Enum, Bounded)

instance ToHttpApiData HistoryShapeName where
    toUrlPiece = renderHistoryShapeName

instance FromHttpApiData HistoryShapeName where
    parseUrlPiece = parseHistoryShapeName

-- | Stable list of supported SHACL shape names.
knownHistoryShapeNames :: [HistoryShapeName]
knownHistoryShapeNames = [minBound .. maxBound]

-- | Parse a SHACL shape name accepted by CLI and HTTP.
parseHistoryShapeName :: Text -> Either Text HistoryShapeName
parseHistoryShapeName raw =
    case T.toLower raw of
        "history-entry" -> Right HistoryEntryShape
        "indexed-tx-body" -> Right IndexedTxBodyShape
        other ->
            Left $
                "unknown history SHACL shape '"
                    <> other
                    <> "'; known shapes: "
                    <> T.intercalate
                        ", "
                        (renderHistoryShapeName <$> knownHistoryShapeNames)

-- | Render the stable external SHACL shape name.
renderHistoryShapeName :: HistoryShapeName -> Text
renderHistoryShapeName = \case
    HistoryEntryShape -> "history-entry"
    IndexedTxBodyShape -> "indexed-tx-body"

-- | SHACL validation report for an indexed history RDF lattice.
data HistoryShaclResult = HistoryShaclResult
    { hsrShape :: !HistoryShapeName
    -- ^ Server-side shape set that produced this report.
    , hsrConforms :: !Bool
    -- ^ True when the SHACL engine found no violation at the selected
    --   severity.
    , hsrReport :: !Text
    -- ^ Raw SHACL validation report text. This may be empty when the
    --   selected shape conforms cleanly.
    }
    deriving stock (Eq, Show)

-- | Render a SHACL report as text lines for the CLI.
historyShaclResultLines :: HistoryShaclResult -> [Text]
historyShaclResultLines HistoryShaclResult{..} =
    [ "shape " <> renderHistoryShapeName hsrShape
    , "conforms " <> if hsrConforms then "true" else "false"
    ]
        <> if T.null hsrReport
            then []
            else "report" : T.lines hsrReport

-- | Failure while building or querying the local RDF lattice.
data HistorySparqlError
    = -- | The upstream @cq-rdf@ executable was not available on @PATH@.
      HistoryCqRdfUnavailable !Text
    | -- | @cq-rdf@ exited non-zero, carrying exit code and output text.
      HistoryCqRdfFailed !Int !Text
    | -- | The Apache Jena @arq@ executable was not available on @PATH@.
      HistoryArqUnavailable !Text
    | -- | @arq@ exited non-zero, carrying exit code and stderr text.
      HistoryArqFailed !Int !Text
    | -- | The Apache Jena @shacl@ executable was not available on @PATH@.
      HistoryShaclUnavailable !Text
    | -- | @shacl@ failed before producing a validation report.
      HistoryShaclFailed !Int !Text
    | -- | The SPARQL TSV output did not match the expected table shape.
      HistoryResultMalformed !Text
    deriving stock (Eq, Show)

-- | Human-readable single-line error.
renderHistorySparqlError :: HistorySparqlError -> Text
renderHistorySparqlError = \case
    HistoryCqRdfUnavailable msg ->
        "history RDF: cq-rdf unavailable: " <> msg
    HistoryCqRdfFailed code msg ->
        "history RDF: cq-rdf exited "
            <> T.pack (show code)
            <> ": "
            <> oneLine msg
    HistoryArqUnavailable msg ->
        "history RDF: Apache Jena arq unavailable: " <> msg
    HistoryArqFailed code msg ->
        "history RDF: arq exited "
            <> T.pack (show code)
            <> ": "
            <> oneLine msg
    HistoryShaclUnavailable msg ->
        "history RDF: Apache Jena shacl unavailable: " <> msg
    HistoryShaclFailed code msg ->
        "history RDF: shacl exited "
            <> T.pack (show code)
            <> ": "
            <> oneLine msg
    HistoryResultMalformed msg ->
        "history RDF: malformed TSV result: " <> msg

{- | Run one named query against the supplied indexed history rows.

Queries that only need ATX metadata can run over entries with empty
payloads. Ledger-level queries require raw transaction CBOR payloads and
will fail if @cq-rdf@ cannot emit RDF for a non-empty payload.
-}
runNamedHistoryQuery
    :: HistoryQueryName
    -> [TxSummaryEntry]
    -> IO (Either HistorySparqlError HistoryQueryResult)
runNamedHistoryQuery name entries = do
    lattice <- buildHistoryLattice (queryNeedsBodies name) entries
    case lattice of
        Left err -> pure (Left err)
        Right ttl -> runArq name (queryBytes name) ttl

{- | Validate the supplied indexed history rows with one named SHACL
shape set.
-}
runNamedHistoryShacl
    :: HistoryShapeName
    -> [TxSummaryEntry]
    -> IO (Either HistorySparqlError HistoryShaclResult)
runNamedHistoryShacl name entries = do
    lattice <- buildHistoryLattice (shapeNeedsBodies name) entries
    case lattice of
        Left err -> pure (Left err)
        Right ttl -> runShacl name (shapeBytes name) ttl

{- | Apply the shared history filters through the RDF query layer, then
return the original indexer entries in index order.
-}
filterHistoryEntries
    :: HistoryFilter
    -> [TxSummaryEntry]
    -> IO (Either HistorySparqlError [TxSummaryEntry])
filterHistoryEntries flt@HistoryFilter{..} entries = do
    mHistory <- runNamedHistoryQuery HistoryEntriesQuery entries
    case mHistory of
        Left err -> pure (Left err)
        Right historyRows -> do
            mAssetTxIds <- assetTxIds flt entries
            pure $ do
                assetIds <- mAssetTxIds
                txIds <- matchingHistoryTxIds flt historyRows
                let wanted = Set.intersection txIds assetIds
                Right $
                    applyLimit hfLimit $
                        List.filter
                            ((`Set.member` wanted) . entryTxIdText)
                            entries

assetTxIds
    :: HistoryFilter
    -> [TxSummaryEntry]
    -> IO (Either HistorySparqlError (Set.Set Text))
assetTxIds HistoryFilter{hfAsset = Nothing} entries =
    pure (Right (Set.fromList (entryTxIdText <$> entries)))
assetTxIds HistoryFilter{hfAsset = Just needle} entries = do
    mAssets <- runNamedHistoryQuery AssetFlowQuery entries
    pure $ do
        result <- mAssets
        let rows = resultRows result
            wanted =
                T.toLower needle
        Right $
            Set.fromList
                [ txid
                | row <- rows
                , Just asset <- [Map.lookup "asset" row]
                , T.toLower asset == wanted
                , Just txid <- [Map.lookup "txid" row]
                ]

matchingHistoryTxIds
    :: HistoryFilter
    -> HistoryQueryResult
    -> Either HistorySparqlError (Set.Set Text)
matchingHistoryTxIds HistoryFilter{..} result =
    Set.fromList
        <$> traverse rowTxId (filter rowMatches (resultRows result))
  where
    rowMatches row =
        matchesText hfRole (Map.lookup "role" row)
            && matchesText hfDirection (Map.lookup "direction" row)
            && matchesLowerBound hfSince (Map.lookup "slot" row)
            && matchesUpperBound hfUntil (Map.lookup "slot" row)

    rowTxId row =
        case Map.lookup "txid" row of
            Just txid -> Right txid
            Nothing -> Left (HistoryResultMalformed "missing txid column")

matchesText :: Maybe Text -> Maybe Text -> Bool
matchesText Nothing _ = True
matchesText (Just expected) (Just actual) =
    T.toLower expected == T.toLower actual
matchesText (Just _) Nothing = False

matchesLowerBound :: Maybe Word64 -> Maybe Text -> Bool
matchesLowerBound Nothing _ = True
matchesLowerBound (Just lo) value =
    maybe False (>= lo) (value >>= parseWord64)

matchesUpperBound :: Maybe Word64 -> Maybe Text -> Bool
matchesUpperBound Nothing _ = True
matchesUpperBound (Just hi) value =
    maybe False (<= hi) (value >>= parseWord64)

applyLimit :: Maybe Int -> [a] -> [a]
applyLimit Nothing = id
applyLimit (Just n) = take n

-- ---------------------------------------------------------------------------
-- Query catalog

queryNeedsBodies :: HistoryQueryName -> Bool
queryNeedsBodies = \case
    HistoryEntriesQuery -> False
    TxCountQuery -> True
    AssetFlowQuery -> True
    SpendEdgesQuery -> True
    EntityOccurrencesQuery -> False

queryBytes :: HistoryQueryName -> ByteString
queryBytes = \case
    HistoryEntriesQuery ->
        $(embedFile "lib/Amaru/Treasury/History/queries/history-entries.rq")
    TxCountQuery ->
        $(embedFile "lib/Amaru/Treasury/History/queries/tx-count.rq")
    AssetFlowQuery ->
        $(embedFile "lib/Amaru/Treasury/History/queries/asset-flow.rq")
    SpendEdgesQuery ->
        $(embedFile "lib/Amaru/Treasury/History/queries/spend-edges.rq")
    EntityOccurrencesQuery ->
        $(embedFile "lib/Amaru/Treasury/History/queries/entity-occurrences.rq")

shapeNeedsBodies :: HistoryShapeName -> Bool
shapeNeedsBodies = \case
    HistoryEntryShape -> False
    IndexedTxBodyShape -> True

shapeBytes :: HistoryShapeName -> ByteString
shapeBytes = \case
    HistoryEntryShape ->
        $( embedFile "lib/Amaru/Treasury/History/shapes/history-entry.shacl.ttl"
         )
    IndexedTxBodyShape ->
        $( embedFile
            "lib/Amaru/Treasury/History/shapes/indexed-tx-body.shacl.ttl"
         )

-- ---------------------------------------------------------------------------
-- Lattice construction

buildHistoryLattice
    :: Bool
    -> [TxSummaryEntry]
    -> IO (Either HistorySparqlError ByteString)
buildHistoryLattice includeBodies entries =
    withSystemTempDirectory "amaru-history-cq-rdf" $ \dir -> do
        bodyChunks <-
            if includeBodies
                then traverse (entryBodyTurtle dir) (zip [0 :: Int ..] entries)
                else pure []
        pure $ do
            bodies <- sequence bodyChunks
            Right $
                BS.intercalate
                    "\n"
                    (historyMetadataTurtle entries : bodies)

historyMetadataTurtle :: [TxSummaryEntry] -> ByteString
historyMetadataTurtle entries =
    TE.encodeUtf8 $
        T.unlines $
            [ "@prefix atx: <https://lambdasistemi.github.io/amaru-treasury-tx/vocab/history#> ."
            , "@prefix cardano: <https://lambdasistemi.github.io/cardano-ledger-rdf/vocab/cardano#> ."
            , "@prefix xsd: <http://www.w3.org/2001/XMLSchema#> ."
            , ""
            ]
                <> concat
                    [ entryMetadata ix entry
                    | (ix, entry) <- zip [(0 :: Int) ..] entries
                    ]

entryMetadata :: Int -> TxSummaryEntry -> [Text]
entryMetadata ix entry =
    [ "<urn:amaru-treasury-tx:history:"
        <> T.pack (show ix)
        <> "> a atx:HistoryEntry ;"
    , "  atx:tx <urn:cardano:tx:" <> txid <> "> ;"
    , "  atx:txid " <> turtleString txid <> " ;"
    , "  atx:slot " <> slotText <> " ;"
    , "  atx:scope " <> turtleString scope <> " ;"
    , "  atx:role " <> turtleString role <> " ;"
    , "  atx:direction " <> turtleString direction <> " ."
    , ""
    ]
  where
    key = tseKey entry
    txid = txIdText (tskTxId key)
    slotText = T.pack (show (unSlotNo (tskSlot key)))
    scope = bytesText (unHistoryScope (tskScope key))
    role = roleText (tskRole key)
    direction = directionText (tseDirection entry)

entryBodyTurtle
    :: FilePath
    -> (Int, TxSummaryEntry)
    -> IO (Either HistorySparqlError ByteString)
entryBodyTurtle dir (ix, entry)
    | BS.null (tsePayload entry) = pure (Right BS.empty)
    | otherwise = do
        let txPath = dir </> ("tx-" <> show ix <> ".cbor")
        result <-
            try $ do
                BS.writeFile txPath (tsePayload entry)
                readProcessWithExitCode "cq-rdf" ["body", txPath] ""
        case result of
            Left (ioe :: IOException) ->
                pure (Left (HistoryCqRdfUnavailable (T.pack (show ioe))))
            Right (ExitSuccess, out, _) ->
                pure (Right (TE.encodeUtf8 (T.pack out)))
            Right (ExitFailure code, out, err) ->
                pure
                    ( Left
                        ( HistoryCqRdfFailed
                            code
                            (processOutputText out err)
                        )
                    )

-- ---------------------------------------------------------------------------
-- arq runner

runArq
    :: HistoryQueryName
    -> ByteString
    -> ByteString
    -> IO (Either HistorySparqlError HistoryQueryResult)
runArq name query ttl =
    withSystemTempDirectory "amaru-history-rdf" $ \dir -> do
        let dataPath = dir </> "history.ttl"
            queryPath = dir </> "query.rq"
        BS.writeFile dataPath ttl
        BS.writeFile queryPath query
        result <-
            try
                ( readProcessWithExitCode
                    "arq"
                    [ "--data"
                    , dataPath
                    , "--query"
                    , queryPath
                    , "--results"
                    , "TSV"
                    ]
                    ""
                )
        case result of
            Left (ioe :: IOException) ->
                pure (Left (HistoryArqUnavailable (T.pack (show ioe))))
            Right (ExitSuccess, out, _) ->
                pure (parseTsv name (T.pack out))
            Right (ExitFailure code, _, err) ->
                pure (Left (HistoryArqFailed code (T.pack err)))

runShacl
    :: HistoryShapeName
    -> ByteString
    -> ByteString
    -> IO (Either HistorySparqlError HistoryShaclResult)
runShacl name shapes ttl =
    withSystemTempDirectory "amaru-history-shacl" $ \dir -> do
        let dataPath = dir </> "history.ttl"
            shapesPath = dir </> "shapes.ttl"
        BS.writeFile dataPath ttl
        BS.writeFile shapesPath shapes
        result <-
            try
                ( readProcessWithExitCode
                    "shacl"
                    [ "validate"
                    , "--shapes"
                    , shapesPath
                    , "--data"
                    , dataPath
                    ]
                    ""
                )
        case result of
            Left (ioe :: IOException) ->
                pure (Left (HistoryShaclUnavailable (T.pack (show ioe))))
            Right (ExitFailure code, "", err) ->
                pure (Left (HistoryShaclFailed code (T.pack err)))
            Right (code, out, err) ->
                let report =
                        T.pack $
                            out
                                <> if null err then "" else "\n" <> err
                    conforms =
                        code == ExitSuccess
                            && not (shaclReportFails out)
                in  pure $
                        Right
                            HistoryShaclResult
                                { hsrShape = name
                                , hsrConforms = conforms
                                , hsrReport =
                                    if conforms
                                        then ""
                                        else report
                                }

shaclReportFails :: String -> Bool
shaclReportFails report =
    "sh:conforms  false" `List.isInfixOf` report
        || "sh:conforms false" `List.isInfixOf` report
        || "sh:Violation" `List.isInfixOf` report
        || "http://www.w3.org/ns/shacl#Violation" `List.isInfixOf` report

parseTsv
    :: HistoryQueryName
    -> Text
    -> Either HistorySparqlError HistoryQueryResult
parseTsv name raw =
    case T.lines raw of
        [] ->
            Right
                HistoryQueryResult
                    { hqrQuery = name
                    , hqrColumns = []
                    , hqrRows = []
                    }
        header : rows ->
            let columns = cleanHeader <$> T.splitOn "\t" header
                parsedRows =
                    [ cleanCell <$> T.splitOn "\t" row
                    | row <- rows
                    , not (T.null row)
                    ]
            in  if all ((== length columns) . length) parsedRows
                    then
                        Right
                            HistoryQueryResult
                                { hqrQuery = name
                                , hqrColumns = columns
                                , hqrRows = parsedRows
                                }
                    else
                        Left
                            ( HistoryResultMalformed
                                "row width does not match header"
                            )

cleanHeader :: Text -> Text
cleanHeader =
    T.dropWhile (== '?')

cleanCell :: Text -> Text
cleanCell cell
    | "\"" `T.isPrefixOf` cell =
        let (lit, _) = T.breakOn "\"" (T.drop 1 cell)
        in  lit
    | "<" `T.isPrefixOf` cell && ">" `T.isSuffixOf` cell =
        T.dropEnd 1 (T.drop 1 cell)
    | otherwise = cell

resultRows :: HistoryQueryResult -> [Map.Map Text Text]
resultRows HistoryQueryResult{..} =
    Map.fromList . zip hqrColumns <$> hqrRows

-- ---------------------------------------------------------------------------
-- Text helpers

entryTxIdText :: TxSummaryEntry -> Text
entryTxIdText = txIdText . tskTxId . tseKey

txIdText :: TxId -> Text
txIdText = TE.decodeUtf8 . B16.encode . unTxId

roleText :: TxRole -> Text
roleText role
    | BS.null (unTxRole role) = "-"
    | otherwise = bytesText (unTxRole role)

directionText :: TxDirection -> Text
directionText = bytesText . unTxDirection

bytesText :: ByteString -> Text
bytesText = TE.decodeUtf8Lenient

turtleString :: Text -> Text
turtleString txt =
    "\""
        <> T.concatMap escape txt
        <> "\""
  where
    escape = \case
        '"' -> "\\\""
        '\\' -> "\\\\"
        '\n' -> "\\n"
        '\r' -> "\\r"
        '\t' -> "\\t"
        c -> T.singleton c

parseWord64 :: Text -> Maybe Word64
parseWord64 txt =
    case TR.decimal txt of
        Right (n, rest)
            | T.null rest -> Just n
        _ -> Nothing

processOutputText :: String -> String -> Text
processOutputText out err =
    T.pack $
        out
            <> if null err
                then ""
                else "\n" <> err

oneLine :: Text -> Text
oneLine =
    T.unwords . T.words . fromMaybe "" . listToMaybeText . T.lines

listToMaybeText :: [Text] -> Maybe Text
listToMaybeText [] = Nothing
listToMaybeText (x : _) = Just x
