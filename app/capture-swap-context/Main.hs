{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE RecordWildCards #-}

{- |
Module      : Main
Description : Capture a live ChainContext into a fixture
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Reads a unified treasury intent JSON, queries the live
mainnet node for the 6 UTxOs the swap will reach for,
runs the full 'runSwap' pipeline once to capture the
per-redeemer 'ExUnits', and writes the snapshot into a
fixture directory:

@
\<out-dir\>/
├── pparams.json    (caller copies their own dump here)
├── utxos.json      (written by this exe)
├── exunits.json    (written by this exe)
└── expected.cbor   (the build output, hex)
@

The offline golden harness then loads this directory via
'Amaru.Treasury.ChainContext.Fixture.readSwapFixture',
runs 'runFromIntent' against the resulting frozen
'ChainContext', and byte-diffs the new CBOR against
@expected.cbor@.
-}
module Main (main) where

import Control.Exception (throwIO)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as BSL
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Options.Applicative
    ( Parser
    , execParser
    , fullDesc
    , help
    , helper
    , info
    , long
    , metavar
    , option
    , optional
    , progDesc
    , short
    , strOption
    , value
    , (<**>)
    )
import System.Environment (lookupEnv)
import System.IO (stderr)
import System.IO qualified as IO

import Cardano.Ledger.Coin (Coin (..))
import Ouroboros.Network.Magic (NetworkMagic (..))

import Amaru.Treasury.Backend.N2C (withLocalNodeBackend)
import Amaru.Treasury.ChainContext (ChainContext (..), liveContext)
import Amaru.Treasury.ChainContext.Fixture (writeSwapFixture)
import Amaru.Treasury.IntentJSON
    ( SAction (..)
    , SomeTreasuryIntent (..)
    , TranslatedShared (..)
    , decodeTreasuryIntentFile
    , translateIntent
    )
import Amaru.Treasury.TreasuryBuild
    ( ScriptResult (..)
    , TreasuryBuildResult (..)
    , runSwap
    )
import Amaru.Treasury.Tx.Swap (SwapIntent (..))

import Options.Applicative qualified as O

data CaptureOpts = CaptureOpts
    { coIntentPath :: !FilePath
    , coOutDir :: !FilePath
    , coSocketPath :: !(Maybe FilePath)
    , coNetworkMagic :: !NetworkMagic
    }

optsP :: Parser CaptureOpts
optsP =
    CaptureOpts
        <$> strOption
            ( long "intent"
                <> short 'i'
                <> metavar "PATH"
                <> help "Path to the swap-intent JSON"
            )
        <*> strOption
            ( long "out-dir"
                <> short 'o'
                <> metavar "DIR"
                <> help "Fixture directory to write into"
            )
        <*> optional
            ( strOption
                ( long "node-socket"
                    <> metavar "PATH"
                    <> help
                        "cardano-node N2C socket (defaults to CARDANO_NODE_SOCKET_PATH)"
                )
            )
        <*> ( NetworkMagic
                <$> option
                    O.auto
                    ( long "network-magic"
                        <> metavar "WORD32"
                        <> value 764_824_073
                    )
            )

main :: IO ()
main = do
    CaptureOpts{..} <-
        execParser
            ( info
                (optsP <**> helper)
                ( fullDesc
                    <> progDesc
                        "Snapshot a live ChainContext for the offline parity golden"
                )
            )
    socket <- resolveSocket coSocketPath
    IO.hPutStrLn stderr $
        "capture: reading " <> coIntentPath
    parsed <- decodeTreasuryIntentFile coIntentPath
    some <- case parsed of
        Left e ->
            throwIO . userError $ "intent JSON: " <> e
        Right v -> pure v
    (shared, intent) <- case some of
        SomeTreasuryIntent SSwap ti ->
            case translateIntent SSwap ti of
                Left e ->
                    throwIO . userError $
                        "intent translation: " <> e
                Right v -> pure v
        SomeTreasuryIntent _ _ ->
            throwIO . userError $
                "capture: only swap intents are supported"
    IO.hPutStrLn stderr $
        "capture: connecting to " <> socket
    withLocalNodeBackend coNetworkMagic socket $ \backend -> do
        let allRequired =
                Set.fromList $
                    tsWalletTxIn shared
                        : siTreasuryUtxos intent
                        ++ [ siScopesDeployedAt intent
                           , siPermissionsDeployedAt intent
                           , siTreasuryDeployedAt intent
                           , siRegistryDeployedAt intent
                           ]
        IO.hPutStrLn stderr "capture: querying chain context"
        ctx <- liveContext backend allRequired
        IO.hPutStrLn stderr "capture: building tx"
        TreasuryBuildResult{..} <-
            runSwap
                ctx
                intent
                (tsRationale shared)
                (tsWalletTxIn shared)
                (tsWalletAddr shared)
        let exUnitsMap =
                Map.fromList
                    [ (srPurpose r, ex)
                    | r@ScriptResult{srOutcome = Right ex} <-
                        tbrScriptResults
                    ]
            failures =
                [ (srPurpose r, e)
                | r@ScriptResult{srOutcome = Left e} <-
                    tbrScriptResults
                ]
        case failures of
            [] -> pure ()
            _ -> do
                mapM_
                    ( \(p, e) ->
                        IO.hPutStrLn stderr $
                            "  FAIL: "
                                <> show p
                                <> " — "
                                <> e
                    )
                    failures
                throwIO
                    ( userError
                        "capture: live evaluator reported failures; refusing to write fixture"
                    )
        IO.hPutStrLn stderr $
            "capture: writing utxos.json + exunits.json into "
                <> coOutDir
        writeSwapFixture coOutDir (ccUtxos ctx) exUnitsMap
        let cborStrict = BSL.toStrict tbrCborBytes
            hexed = B16.encode cborStrict
            Coin feeLov = tbrFeeLovelace
        BSL.writeFile
            (coOutDir <> "/expected.cbor")
            (BSL.fromStrict hexed)
        IO.hPutStrLn stderr $
            "capture: expected.cbor "
                <> show (BSL.length (BSL.fromStrict cborStrict))
                <> " bytes  fee="
                <> show feeLov
                <> "  exUnits captured: "
                <> show (Map.size exUnitsMap)

resolveSocket :: Maybe FilePath -> IO FilePath
resolveSocket (Just p) = pure p
resolveSocket Nothing = do
    mEnv <- lookupEnv "CARDANO_NODE_SOCKET_PATH"
    case mEnv of
        Just p -> pure p
        Nothing ->
            throwIO . userError $
                "capture-swap-context: pass --node-socket "
                    <> "or set CARDANO_NODE_SOCKET_PATH"
