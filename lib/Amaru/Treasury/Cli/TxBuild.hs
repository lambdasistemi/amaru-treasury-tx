{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Amaru.Treasury.Cli.TxBuild
    ( TxBuildOpts (..)
    , txBuildOptsP
    , runTxBuild

      -- * Internal — exported for focused tests
    , requiredUtxos
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
    ( RegistryInitMintInputs (..)
    , SAction (..)
    , ScopeJSON (..)
    , SomeTreasuryIntent (..)
    , StakeRewardInitScriptAccountInputs (..)
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

{- | Required on-chain UTxOs for the live-context boundary.

The set must contain every TxIn the per-action build runner under
"Amaru.Treasury.Build.*" actually calls @requireUtxo@ on. The CLI
'tx-build' runner queries the chain for exactly this set and fails
fast if any element is missing; including TxIns the builder does
not consume only inflates the query and (for bootstrap intents)
fabricates false misses against deterministic placeholder refs.

Init actions, mirroring the matching @run*Action@ in
"Amaru.Treasury.Build.*":

* @registry-init-seed-split@ requires only @wjTxIn@ (the wallet
  seed; bound to @risstSeedTxIn@ by 'translateRegistryInitSeedSplit').
* @registry-init-mint@ requires the two payload seed TxIns
  ('rimtScopesSeedTxIn', 'rimtRegistrySeedTxIn'). The wallet block's
  @txIn@ is not spent by the mint builder.
* @registry-init-reference-scripts@ requires only @wjTxIn@
  ('rirstSeedTxIn'). The payload's scopes/registry seed TxIns are
  script-derivation parameters, not live inputs.
* @stake-reward-init-script-account@ requires @wjTxIn@
  ('srisatSeedTxIn') and the treasury reference-script TxIn
  ('srisatTreasuryRefTxIn').
* @stake-reward-init-plain-account@ requires only @wjTxIn@
  ('srispatSeedTxIn').

In all five init arms @wjExtraTxIns@ is NOT included: each builder
spends exactly one wallet input. Including extras here would query
for UTxOs the build runner never consumes, with the same false-miss
hazard as the placeholder refs.

Non-init actions (swap, disburse, withdraw, reorganize, both
governance-withdrawal-init sub-actions) retain the legacy generic
set in this slice: wallet + @wjExtraTxIns@ + treasury UTxOs + the
four scope reference TxIns ('sjScopesDeployedAt',
'sjPermissionsDeployedAt', 'sjTreasuryDeployedAt',
'sjRegistryDeployedAt'). The generic set is at least a superset of
what each non-init builder requires; tightening it to the exact
@requireUtxo@ surface for those actions is out of scope here and
tracked separately. 'Amaru.Treasury.Cli.TxBuildRequiredUtxosSpec'
includes a regression on a disburse intent to prove the legacy set
keeps the scope refs and treasury UTxOs.
-}
requiredUtxos
    :: SomeTreasuryIntent -> Either String (Set.Set TxIn)
requiredUtxos (SomeTreasuryIntent sa intent) = case sa of
    SRegistryInitSeedSplit -> walletSeedOnly
    SRegistryInitMint -> do
        let payload = tiPayload intent
        scopesSeed <-
            parseTxIn (rimiScopesSeedTxIn payload)
        registrySeed <-
            parseTxIn (rimiRegistrySeedTxIn payload)
        Right (Set.fromList [scopesSeed, registrySeed])
    SRegistryInitReferenceScripts -> walletSeedOnly
    SStakeRewardInitScriptAccount -> do
        let payload = tiPayload intent
        walletSet <- walletSeedOnly
        treasuryRef <-
            parseTxIn (srisaiTreasuryRefTxIn payload)
        Right (Set.insert treasuryRef walletSet)
    SStakeRewardInitPlainAccount -> walletSeedOnly
    _ -> genericRequiredUtxos intent
  where
    -- Exactly @wjTxIn@. No @wjExtraTxIns@: the five init builders
    -- spend a single seed.
    walletSeedOnly :: Either String (Set.Set TxIn)
    walletSeedOnly = do
        walletTxIn <- parseTxIn (wjTxIn (tiWallet intent))
        Right (Set.singleton walletTxIn)

genericRequiredUtxos
    :: TreasuryIntent a -> Either String (Set.Set TxIn)
genericRequiredUtxos intent = do
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
