{- |
Module      : Amaru.Treasury.Cli.History
Description : CLI parser, query, and render for @history@
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

The @history@ command is a read-only view over the upstream
tx-history indexer. It opens the RocksDB store the
@amaru-treasury-tx-api@ container writes, queries the entries
filed under the fixed treasury tenant
('Amaru.Treasury.Indexer.Decoder.treasuryTenantId') and the
selected scope, and prints one stable @slot txid role@ row per
entry in the upstream query order.

This slice owns only the local read path: it does not attach the
decoder to the live API follower and does not query a node. The
store is whichever RocksDB directory @--indexer-db@ (or the
@AMARU_TREASURY_API_INDEXER_DB@ environment variable) points at.
-}
module Amaru.Treasury.Cli.History
    ( -- * Options
      HistoryOpts (..)
    , TxDetailOpts (..)
    , historyOptsP
    , txDetailOptsP

      -- * Runner
    , runHistory
    , runTxDetail

      -- * Query and render (pure-ish seams for tests)
    , queryScopeHistory
    , queryFilteredScopeHistory
    , queryTxDetail
    , scopeHistoryScope
    , renderHistoryRow
    , renderHistoryRows
    , renderTxDetail
    ) where

import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.Char (toLower)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Data.Word (Word64)
import Options.Applicative
    ( Parser
    , ReadM
    , argument
    , auto
    , eitherReader
    , help
    , long
    , metavar
    , option
    , optional
    , strOption
    )
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..), exitWith)
import System.IO (hPutStrLn, stderr)

import Cardano.Node.Client.TxHistoryIndexer.Indexer
    ( HistoryIndexer
    , getByTxId
    , queryHistory
    , withRocksDBHistoryIndexer
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

import Amaru.Treasury.History.Sparql
    ( HistoryFilter (..)
    , HistoryQueryName
    , HistoryShapeName
    , filterHistoryEntries
    , historyQueryRowsTsv
    , historyShaclResultLines
    , parseHistoryQueryName
    , parseHistoryShapeName
    , renderHistorySparqlError
    , runNamedHistoryQuery
    , runNamedHistoryShacl
    )
import Amaru.Treasury.Indexer.Decoder (treasuryTenantId)
import Amaru.Treasury.Scope
    ( ScopeId
    , scopeFromText
    , scopeText
    )

-- | Flags for the @history@ subcommand.
data HistoryOpts = HistoryOpts
    { hoScope :: !ScopeId
    -- ^ Treasury scope whose history to read.
    , hoIndexerDb :: !(Maybe FilePath)
    -- ^ RocksDB indexer directory. Falls back to
    -- @AMARU_TREASURY_API_INDEXER_DB@ when absent.
    , hoRole :: !(Maybe Text)
    -- ^ Optional exact role filter.
    , hoAsset :: !(Maybe Text)
    -- ^ Optional asset filter over the RDF asset-flow query.
    , hoDirection :: !(Maybe Text)
    -- ^ Optional direction filter, e.g. @inbound@ or @outbound@.
    , hoSince :: !(Maybe Word64)
    -- ^ Optional lower slot bound, inclusive.
    , hoUntil :: !(Maybe Word64)
    -- ^ Optional upper slot bound, inclusive.
    , hoLimit :: !(Maybe Int)
    -- ^ Optional maximum rows after filtering.
    , hoRdfQuery :: !(Maybe HistoryQueryName)
    -- ^ Optional named SPARQL query to run instead of row rendering.
    , hoShacl :: !(Maybe HistoryShapeName)
    -- ^ Optional named SHACL shape to validate instead of row rendering.
    }
    deriving stock (Eq, Show)

-- | Flags for the @tx-detail@ subcommand.
data TxDetailOpts = TxDetailOpts
    { tdoTxId :: !TxId
    -- ^ Raw transaction id to read from the tx-history indexer.
    , tdoIndexerDb :: !(Maybe FilePath)
    -- ^ RocksDB indexer directory. Falls back to
    -- @AMARU_TREASURY_API_INDEXER_DB@ when absent.
    }
    deriving stock (Eq, Show)

-- | Parse the @history@ flags.
historyOptsP :: Parser HistoryOpts
historyOptsP =
    HistoryOpts
        <$> option
            scopeReader
            ( long "scope"
                <> metavar "NAME"
                <> help
                    "core_development|ops_and_use_cases|network_compliance|middleware|contingency"
            )
        <*> optional
            ( strOption
                ( long "indexer-db"
                    <> metavar "PATH"
                    <> help
                        "RocksDB tx-history indexer directory; defaults to $AMARU_TREASURY_API_INDEXER_DB"
                )
            )
        <*> optional
            ( T.pack
                <$> strOption
                    ( long "role"
                        <> metavar "ROLE"
                        <> help "Only include rows whose indexed role matches ROLE"
                    )
            )
        <*> optional
            ( T.pack
                <$> strOption
                    ( long "asset"
                        <> metavar "ASSET"
                        <> help
                            "Only include rows whose ledger RDF asset-flow contains ASSET (ada or asset bytesHex)"
                    )
            )
        <*> optional
            ( T.pack
                <$> strOption
                    ( long "direction"
                        <> metavar "DIRECTION"
                        <> help "Only include inbound or outbound rows"
                    )
            )
        <*> optional
            ( option
                auto
                ( long "since"
                    <> metavar "SLOT"
                    <> help "Only include rows at or after SLOT"
                )
            )
        <*> optional
            ( option
                auto
                ( long "until"
                    <> metavar "SLOT"
                    <> help "Only include rows at or before SLOT"
                )
            )
        <*> optional
            ( option
                auto
                ( long "limit"
                    <> metavar "N"
                    <> help "Limit the number of rendered rows"
                )
            )
        <*> optional
            ( option
                historyQueryReader
                ( long "rdf-query"
                    <> metavar "NAME"
                    <> help
                        "Run a named SPARQL query: history-entries|tx-count|asset-flow|spend-edges|entity-occurrences"
                )
            )
        <*> optional
            ( option
                historyShapeReader
                ( long "shacl"
                    <> metavar "NAME"
                    <> help
                        "Run a named SHACL validation: history-entry|indexed-tx-body"
                )
            )

-- | Parse @tx-detail TXID@.
txDetailOptsP :: Parser TxDetailOpts
txDetailOptsP =
    TxDetailOpts
        <$> argument
            txIdReader
            (metavar "TXID")
        <*> optional
            ( strOption
                ( long "indexer-db"
                    <> metavar "PATH"
                    <> help
                        "RocksDB tx-history indexer directory; defaults to $AMARU_TREASURY_API_INDEXER_DB"
                )
            )

scopeReader :: ReadM ScopeId
scopeReader =
    eitherReader $
        scopeFromText . T.pack . map toLower

txIdReader :: ReadM TxId
txIdReader =
    eitherReader $ \raw ->
        case B16.decode (TE.encodeUtf8 (T.pack raw)) of
            Right bytes
                | BS.length bytes == 32 -> Right (TxId bytes)
                | otherwise ->
                    Left
                        "TXID must be a 32-byte transaction id encoded as hex"
            Left err -> Left ("TXID must be hex: " <> err)

historyQueryReader :: ReadM HistoryQueryName
historyQueryReader =
    eitherReader $
        firstText . parseHistoryQueryName . T.pack
  where
    firstText =
        either (Left . T.unpack) Right

historyShapeReader :: ReadM HistoryShapeName
historyShapeReader =
    eitherReader $
        firstText . parseHistoryShapeName . T.pack
  where
    firstText =
        either (Left . T.unpack) Right

{- | Run @history@: resolve the indexer database path, open the
RocksDB store, query the selected scope, and print the rendered
rows. Exits with code 2 if no database path is available.
-}
runHistory :: HistoryOpts -> IO ()
runHistory opts = do
    envs <- getEnvironment
    case resolveIndexerDb (hoIndexerDb opts) envs of
        Left err -> do
            hPutStrLn stderr ("amaru-treasury-tx: " <> err)
            exitWith (ExitFailure 2)
        Right dbPath ->
            withRocksDBHistoryIndexer dbPath $ \idx -> do
                entries <- queryScopeHistory idx (hoScope opts)
                case (hoRdfQuery opts, hoShacl opts) of
                    (Just _, Just _) ->
                        dieHistory
                            "history: pass only one of --rdf-query or --shacl"
                    (Just queryName, Nothing) -> do
                        result <-
                            runNamedHistoryQuery queryName Nothing entries
                        case result of
                            Right table ->
                                mapM_
                                    TIO.putStrLn
                                    (historyQueryRowsTsv table)
                            Left err ->
                                dieHistory (renderHistorySparqlError err)
                    (Nothing, Just shapeName) -> do
                        result <-
                            runNamedHistoryShacl shapeName Nothing entries
                        case result of
                            Right report ->
                                mapM_
                                    TIO.putStrLn
                                    (historyShaclResultLines report)
                            Left err ->
                                dieHistory (renderHistorySparqlError err)
                    (Nothing, Nothing) -> do
                        filtered <-
                            queryFilteredScopeHistory
                                idx
                                (hoScope opts)
                                (historyFilter opts)
                        case filtered of
                            Right rows ->
                                mapM_
                                    TIO.putStrLn
                                    (renderHistoryRows rows)
                            Left err -> dieHistory err

{- | Run @tx-detail@: resolve the indexer database path, look up the
treasury summary by tx id using the direct indexer API, and print the
decoded view. Exits with code 1 when the tx id is not indexed for the
treasury tenant.
-}
runTxDetail :: TxDetailOpts -> IO ()
runTxDetail opts = do
    envs <- getEnvironment
    case resolveIndexerDb (tdoIndexerDb opts) envs of
        Left err -> do
            hPutStrLn stderr ("amaru-treasury-tx: " <> err)
            exitWith (ExitFailure 2)
        Right dbPath ->
            withRocksDBHistoryIndexer dbPath $ \idx -> do
                mSummary <- queryTxDetail idx (tdoTxId opts)
                case mSummary of
                    Nothing -> do
                        hPutStrLn
                            stderr
                            ( "amaru-treasury-tx: tx-detail: not found "
                                <> T.unpack (txIdHex (tdoTxId opts))
                            )
                        exitWith (ExitFailure 1)
                    Just summary ->
                        mapM_ TIO.putStrLn (renderTxDetail summary)

{- | Resolve the indexer database path: the explicit @--indexer-db@
flag wins, else the @AMARU_TREASURY_API_INDEXER_DB@ environment
variable. 'Left' when neither is present.
-}
resolveIndexerDb
    :: Maybe FilePath -> [(String, String)] -> Either String FilePath
resolveIndexerDb (Just path) _ = Right path
resolveIndexerDb Nothing envs =
    case lookup indexerDbEnvVar envs of
        Just path | not (null path) -> Right path
        _ ->
            Left
                "history: no indexer database path; pass \
                \--indexer-db PATH or set \
                \AMARU_TREASURY_API_INDEXER_DB"

-- | Environment variable carrying the default indexer database path.
indexerDbEnvVar :: String
indexerDbEnvVar = "AMARU_TREASURY_API_INDEXER_DB"

{- | Query the upstream history indexer for the treasury tenant and
the given scope, in the indexer's @(slot, txid, role)@ order.
-}
queryScopeHistory
    :: HistoryIndexer -> ScopeId -> IO [TxSummaryEntry]
queryScopeHistory idx scope =
    queryHistory idx treasuryTenantId (scopeHistoryScope scope)

-- | Query and filter one scope through the shared RDF/SPARQL layer.
queryFilteredScopeHistory
    :: HistoryIndexer
    -> ScopeId
    -> HistoryFilter
    -> IO (Either Text [TxSummaryEntry])
queryFilteredScopeHistory idx scope flt = do
    entries <- queryScopeHistory idx scope
    first renderHistorySparqlError <$> filterHistoryEntries flt entries

-- | Directly look up one detailed treasury transaction by tx id.
queryTxDetail :: HistoryIndexer -> TxId -> IO (Maybe TxSummary)
queryTxDetail idx =
    getByTxId idx treasuryTenantId

{- | Render a 'ScopeId' as the upstream 'HistoryScope' bytes: the
UTF-8 'scopeText', matching the decoder's key derivation.
-}
scopeHistoryScope :: ScopeId -> HistoryScope
scopeHistoryScope = HistoryScope . TE.encodeUtf8 . scopeText

-- | Render the stable @slot txid role direction=...@ rows for a query result.
renderHistoryRows :: [TxSummaryEntry] -> [Text]
renderHistoryRows = map renderHistoryRow

{- | Render one entry as @slot txid role direction=...@: decimal slot,
lower-hex raw tx-id bytes, UTF-8 role bytes (or @-@), and the
direction label.
-}
renderHistoryRow :: TxSummaryEntry -> Text
renderHistoryRow entry =
    T.unwords [slotText, txIdText, roleText, directionText]
  where
    key = tseKey entry
    slotText = T.pack (show (unSlotNo (tskSlot key)))
    txIdText = txIdHex (tskTxId key)
    roleText = roleTextOf (tskRole key)
    directionText = "direction=" <> directionTextOf (tseDirection entry)

-- | Render a detailed transaction view with one stable field per line.
renderTxDetail :: TxSummary -> [Text]
renderTxDetail summary =
    [ "slot " <> T.pack (show (unSlotNo (tskSlot key)))
    , "txid " <> txIdHex (tskTxId key)
    , "scope " <> scopeTextOf (tskScope key)
    , "role " <> roleTextOf (tskRole key)
    , "direction " <> directionTextOf (txsDirection summary)
    , "block-hash " <> maybe "-" hexText (txsBlockHash summary)
    , "fee " <> maybe "-" (T.pack . show) (txsFee summary)
    , "required-signers "
        <> if null (txsRequiredSigners summary)
            then "-"
            else T.intercalate "," (bytesText <$> txsRequiredSigners summary)
    , "redeemer " <> maybe "-" bytesText (txsRedeemer summary)
    ]
        <> (renderInput <$> txsInputs summary)
        <> zipWith renderOutput [(0 :: Int) ..] (txsOutputs summary)
  where
    key = txsKey summary

renderInput :: TxSummaryInput -> Text
renderInput input =
    T.unwords
        [ "input"
        , bytesText (tsiTxIn input)
        , "scope=" <> maybe "-" scopeTextOf (tsiScope input)
        , "value=" <> bytesText (tsiValue input)
        ]

renderOutput :: Int -> TxSummaryOutput -> Text
renderOutput ix output =
    T.unwords
        [ "output"
        , T.pack (show ix)
        , "address=" <> bytesText (tsoAddress output)
        , "value=" <> bytesText (tsoValue output)
        , "datum=" <> maybe "-" bytesText (tsoDatum output)
        ]

txIdHex :: TxId -> Text
txIdHex = hexText . unTxId

hexText :: ByteString -> Text
hexText = TE.decodeUtf8 . B16.encode

scopeTextOf :: HistoryScope -> Text
scopeTextOf = bytesText . unHistoryScope

roleTextOf :: TxRole -> Text
roleTextOf role
    | BS.null (unTxRole role) = "-"
    | otherwise = bytesText (unTxRole role)

directionTextOf :: TxDirection -> Text
directionTextOf = bytesText . unTxDirection

bytesText :: ByteString -> Text
bytesText = TE.decodeUtf8Lenient

historyFilter :: HistoryOpts -> HistoryFilter
historyFilter opts =
    HistoryFilter
        { hfRole = hoRole opts
        , hfAsset = hoAsset opts
        , hfDirection = hoDirection opts
        , hfSince = hoSince opts
        , hfUntil = hoUntil opts
        , hfLimit = hoLimit opts
        }

dieHistory :: Text -> IO a
dieHistory err = do
    hPutStrLn stderr ("amaru-treasury-tx: " <> T.unpack err)
    exitWith (ExitFailure 1)
