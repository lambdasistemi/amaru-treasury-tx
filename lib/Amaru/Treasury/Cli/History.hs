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
    , historyOptsP

      -- * Runner
    , runHistory

      -- * Query and render (pure-ish seams for tests)
    , queryScopeHistory
    , scopeHistoryScope
    , renderHistoryRow
    , renderHistoryRows
    ) where

import Data.ByteString.Base16 qualified as B16
import Data.Char (toLower)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Options.Applicative
    ( Parser
    , ReadM
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
    , queryHistory
    , withRocksDBHistoryIndexer
    )
import Cardano.Node.Client.TxHistoryIndexer.Types
    ( HistoryScope (..)
    , TxId (..)
    , TxRole (..)
    , TxSummaryEntry (..)
    , TxSummaryKey (..)
    )
import Cardano.Slotting.Slot (SlotNo (..))

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

scopeReader :: ReadM ScopeId
scopeReader =
    eitherReader $
        scopeFromText . T.pack . map toLower

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
                mapM_ TIO.putStrLn (renderHistoryRows entries)

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

{- | Render a 'ScopeId' as the upstream 'HistoryScope' bytes: the
UTF-8 'scopeText', matching the decoder's key derivation.
-}
scopeHistoryScope :: ScopeId -> HistoryScope
scopeHistoryScope = HistoryScope . TE.encodeUtf8 . scopeText

-- | Render the stable @slot txid role@ rows for a query result.
renderHistoryRows :: [TxSummaryEntry] -> [Text]
renderHistoryRows = map renderHistoryRow

{- | Render one entry as @slot txid role@: decimal slot, lower-hex
raw tx-id bytes, and the UTF-8 role bytes.
-}
renderHistoryRow :: TxSummaryEntry -> Text
renderHistoryRow entry =
    T.unwords [slotText, txIdText, roleText]
  where
    key = tseKey entry
    slotText = T.pack (show (unSlotNo (tskSlot key)))
    txIdText = TE.decodeUtf8 (B16.encode (unTxId (tskTxId key)))
    roleText = TE.decodeUtf8 (unTxRole (tskRole key))
