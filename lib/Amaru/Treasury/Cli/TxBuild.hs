{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Amaru.Treasury.Cli.TxBuild
    ( TxBuildOpts (..)
    , txBuildOptsP
    , runTxBuild
    ) where

import Control.Tracer (Tracer (..), traceWith)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as BSL
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Options.Applicative
    ( Parser
    , help
    , long
    , metavar
    , optional
    , short
    , strOption
    )
import Ouroboros.Network.Magic
    ( NetworkMagic (..)
    , unNetworkMagic
    )
import System.Exit (ExitCode (..), exitFailure, exitWith)
import System.IO qualified as IO

import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.TxIn (TxIn)

import Amaru.Treasury.Backend.N2C
    ( findSocketMagic
    , probeNetworkMagic
    , withLocalNodeBackend
    )
import Amaru.Treasury.Build
    ( BuildResult (..)
    , ScriptResult (..)
    , buildErrorCode
    , renderBuildError
    , runFromIntentEither
    )
import Amaru.Treasury.Build.ReportWriter (writeReportArtifact)
import Amaru.Treasury.Build.Trace
    ( BuildEvent (..)
    , buildEventTracer
    )
import Amaru.Treasury.ChainContext
    ( networkFromMagic
    , withLiveContext
    )
import Amaru.Treasury.Cli.Common (withLogHandle)
import Amaru.Treasury.IntentJSON
    ( ScopeJSON (..)
    , SomeTreasuryIntent (..)
    , TreasuryIntent (..)
    , WalletJSON (..)
    , decodeTreasuryIntent
    , decodeTreasuryIntentFile
    )
import Amaru.Treasury.IntentJSON.Common (parseTxIn)
import Amaru.Treasury.Report
    ( BuildFailure (..)
    , ReportContext (..)
    , TxBuildOutput (..)
    , TxBuildOutputResult (..)
    , TxBuildSuccess (..)
    , buildTransactionReport
    , encodeBuildOutput
    , txCborHexFromBytes
    )

{- | Flags for the unified @tx-build@ subcommand. The
network is read from the intent's @network@ field, not
from any CLI flag — the intent is the single source of
truth.
-}
data TxBuildOpts = TxBuildOpts
    { tboIntentPath :: !(Maybe FilePath)
    -- ^ 'Nothing' = read intent.json from stdin
    , tboOutPath :: !(Maybe FilePath)
    -- ^ 'Nothing' = stdout
    , tboLog :: !(Maybe FilePath)
    -- ^ 'Nothing' = stderr
    , tboReportPath :: !(Maybe FilePath)
    -- ^ 'Nothing' = do not write a transaction report
    }
    deriving stock (Eq, Show)

txBuildOptsP :: Parser TxBuildOpts
txBuildOptsP =
    TxBuildOpts
        <$> optional
            ( strOption
                ( long "intent"
                    <> short 'i'
                    <> metavar "PATH"
                    <> help
                        "Path to the unified intent.json (defaults to stdin)"
                )
            )
        <*> optional
            ( strOption
                ( long "out"
                    <> short 'o'
                    <> metavar "PATH"
                    <> help "Write hex CBOR here (defaults to stdout)"
                )
            )
        <*> optional
            ( strOption
                ( long "log"
                    <> metavar "PATH"
                    <> help
                        "Where to write step-by-step trace lines (defaults to stderr)"
                )
            )
        <*> optional
            ( strOption
                ( long "report"
                    <> metavar "PATH"
                    <> help
                        "Write a deterministic JSON transaction report after successful validation"
                )
            )

{- | Run the unified @tx-build@ command. The intent's
@network@ field is the source of truth for the N2C
network magic.
-}
runTxBuild :: FilePath -> TxBuildOpts -> IO ()
runTxBuild socket TxBuildOpts{..} = do
    withLogHandle tboLog $ \logH -> do
        let textTracer = Tracer (TIO.hPutStrLn logH) :: Tracer IO Text
            tr = buildEventTracer textTracer
        traceWith tr (BuildEventIntentSource tboIntentPath)
        parsed <- case tboIntentPath of
            Just p -> decodeTreasuryIntentFile p
            Nothing ->
                decodeTreasuryIntent <$> BSL.hGetContents IO.stdin
        some <- case parsed of
            Left e -> abortBuild tr ("intent JSON: " <> T.pack e)
            Right v -> pure v
        (actionName, netName) <-
            pure $ case some of
                SomeTreasuryIntent _sa intent ->
                    ( T.pack
                        (drop 1 (show (tiSAction intent)))
                    , tiNetwork intent
                    )
        traceWith tr (BuildEventIntentParsed actionName netName)
        magic <- magicFromIntent tr netName
        traceWith tr (BuildEventConnect socket)
        required <- case requiredUtxos some of
            Left e ->
                abortBuild tr ("required UTxOs: " <> T.pack e)
            Right s -> pure s
        traceWith
            tr
            (BuildEventRequiredUtxos (Set.size required))
        assertSocketNetwork tr socket netName magic
        withLocalNodeBackend magic socket $ \backend -> do
            withLiveContext
                (networkFromMagic magic)
                backend
                required
                $ \ctx -> do
                    buildResult <- runFromIntentEither ctx some
                    tbr <- case buildResult of
                        Right result -> pure result
                        Left err -> do
                            let message = renderBuildError err
                            TIO.hPutStrLn IO.stderr message
                            writeFailureReport
                                tr
                                tboReportPath
                                some
                                (buildErrorCode err)
                                message
                            exitFailure
                    emitBuildResult
                        tr
                        tboOutPath
                        tboReportPath
                        magic
                        some
                        tbr

emitBuildResult
    :: Tracer IO BuildEvent
    -> Maybe FilePath
    -> Maybe FilePath
    -> NetworkMagic
    -> SomeTreasuryIntent
    -> BuildResult
    -> IO ()
emitBuildResult tr outPath reportPath magic some tbr = do
    let cborStrict = BSL.toStrict (brCborBytes tbr)
        hexed = B16.encode cborStrict
        Coin feeLov = brFeeLovelace tbr
        Coin tcLov = brTotalCollateralLovelace tbr
        failures =
            [ (purpose, e)
            | ScriptResult purpose (Left e) <-
                brScriptResults tbr
            ]
    traceWith
        tr
        ( BuildEventBuilt
            (BS.length cborStrict)
            feeLov
            tcLov
        )
    traceWith
        tr
        ( BuildEventReevaluated
            (length (brScriptResults tbr))
            (length failures)
        )
    mapM_
        ( \(p, e) ->
            traceWith
                tr
                ( BuildEventScriptFail
                    (T.pack (show p))
                    (T.pack e)
                )
        )
        failures
    case (outPath, reportPath == Just "-") of
        (Just p, _) -> BS.writeFile p hexed
        (Nothing, True) -> pure ()
        (Nothing, False) -> do
            BS.putStr hexed
            putStr "\n"
    traceWith tr (BuildEventWroteCbor outPath)
    if null failures
        then do
            traceWith tr BuildEventValidationOk
            case reportPath of
                Nothing -> pure ()
                Just path -> do
                    let report =
                            buildTransactionReport
                                (txBuildReportContext some magic)
                                tbr
                        output =
                            TxBuildOutput
                                { txoIntent = some
                                , txoResult =
                                    TxBuildOutputSuccess
                                        TxBuildSuccess
                                            { tbsTxCbor =
                                                txCborHexFromBytes
                                                    (brCborBytes tbr)
                                            , tbsReport = report
                                            }
                                }
                    writeBuildReportOrExit tr path output
        else do
            traceWith tr BuildEventValidationFailed
            writeFailureReport
                tr
                reportPath
                some
                "validation-failed"
                (renderValidationFailures failures)
            exitFailure

magicFromIntent :: Tracer IO BuildEvent -> Text -> IO NetworkMagic
magicFromIntent tr = \case
    "mainnet" -> pure (NetworkMagic 764_824_073)
    "preprod" -> pure (NetworkMagic 1)
    "preview" -> pure (NetworkMagic 2)
    "devnet" -> pure (NetworkMagic 42)
    other ->
        abortBuild
            tr
            ("unknown network in intent: " <> other)

assertSocketNetwork
    :: Tracer IO BuildEvent
    -> FilePath
    -> Text
    -> NetworkMagic
    -> IO ()
assertSocketNetwork tr socket netName magic = do
    ok <- probeNetworkMagic magic socket
    if ok
        then
            traceWith
                tr
                ( BuildEventNetworkOk
                    netName
                    (unNetworkMagic magic)
                )
        else do
            socketMagic <-
                findSocketMagic
                    (`probeNetworkMagic` socket)
                    netName
            traceWith
                tr
                ( BuildEventNetworkMismatch
                    netName
                    (unNetworkMagic magic)
                    socketMagic
                )
            exitWith (ExitFailure 6)

writeFailureReport
    :: Tracer IO BuildEvent
    -> Maybe FilePath
    -> SomeTreasuryIntent
    -> Text
    -> Text
    -> IO ()
writeFailureReport _ Nothing _ _ _ =
    pure ()
writeFailureReport tr (Just reportPath) some code message =
    writeBuildReportOrExit
        tr
        reportPath
        TxBuildOutput
            { txoIntent = some
            , txoResult =
                TxBuildOutputFailure
                    BuildFailure
                        { bfCode = code
                        , bfMessage = message
                        }
            }

writeBuildReportOrExit
    :: Tracer IO BuildEvent
    -> FilePath
    -> TxBuildOutput
    -> IO ()
writeBuildReportOrExit tr "-" output = do
    BSL.putStr (encodeBuildOutput output)
    traceWith tr (BuildEventWroteReport "-")
writeBuildReportOrExit tr reportPath output = do
    result <-
        writeReportArtifact
            tr
            reportPath
            (encodeBuildOutput output)
    case result of
        Right () -> pure ()
        Left{} -> exitWith (ExitFailure 4)

renderValidationFailures :: [(a, String)] -> Text
renderValidationFailures failures =
    T.intercalate
        "; "
        [ T.pack reason
        | (_, reason) <- failures
        ]

txBuildReportContext
    :: SomeTreasuryIntent -> NetworkMagic -> ReportContext
txBuildReportContext (SomeTreasuryIntent _ intent) magic =
    ReportContext
        { rcNetwork = tiNetwork intent
        , rcSocketNetworkMagic =
            fromIntegral (unNetworkMagic magic)
        , rcSelectedScopeOwner =
            case tiSigners intent of
                owner : _ ->
                    Just (owner, sjId (tiScope intent))
                [] -> Nothing
        , rcExtraSigners =
            drop 1 (tiSigners intent)
        , rcIntentRequiredSigners = []
        }

abortBuild :: Tracer IO BuildEvent -> Text -> IO a
abortBuild tr msg = do
    traceWith tr (BuildEventAborted msg)
    exitWith (ExitFailure 3)

requiredUtxos
    :: SomeTreasuryIntent -> Either String (Set.Set TxIn)
requiredUtxos (SomeTreasuryIntent _sa intent) = do
    let wallet = tiWallet intent
        scope = tiScope intent
    walletTxIn <- parseTxIn (wjTxIn wallet)
    extraWalletTxIns <-
        traverse parseTxIn (wjExtraTxIns wallet)
    treasuryUtxos <-
        traverse parseTxIn (sjTreasuryUtxos scope)
    scopesRef <- parseTxIn (sjScopesDeployedAt scope)
    permissionsRef <-
        parseTxIn (sjPermissionsDeployedAt scope)
    treasuryRef <- parseTxIn (sjTreasuryDeployedAt scope)
    registryRef <- parseTxIn (sjRegistryDeployedAt scope)
    Right $
        Set.fromList $
            walletTxIn
                : extraWalletTxIns
                ++ treasuryUtxos
                ++ [ scopesRef
                   , permissionsRef
                   , treasuryRef
                   , registryRef
                   ]
