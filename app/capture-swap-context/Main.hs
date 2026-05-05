{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE RecordWildCards #-}

{- |
Module      : Main
Description : Capture a live ChainContext into a fixture
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Reads a swap-intent JSON, queries the live mainnet node
for the 6 UTxOs the swap will reach for, runs the full
'runSwapBuild' pipeline once to capture the per-redeemer
'ExUnits', and writes the snapshot into a fixture
directory:

@
\<out-dir\>/
├── pparams.json    (caller copies their own dump here)
├── utxos.json      (written by this exe)
├── exunits.json    (written by this exe)
└── expected.cbor   (the build output, hex)
@

The offline golden harness then loads this directory via
'Amaru.Treasury.ChainContext.Fixture.readSwapFixture',
runs 'runSwapBuild' against the resulting frozen
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
import Amaru.Treasury.Tx.Swap (SwapIntent (..))
import Amaru.Treasury.Tx.SwapBuild
    ( ScriptResult (..)
    , SwapBuildInputs (..)
    , SwapBuildResult (..)
    , runSwapBuild
    )
import Amaru.Treasury.Tx.SwapIntentJSON
    ( TranslatedIntent (..)
    , decodeSwapIntentFile
    , translateIntent
    )

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
    parsed <- decodeSwapIntentFile coIntentPath
    sij <- case parsed of
        Left e ->
            throwIO . userError $ "intent JSON: " <> e
        Right v -> pure v
    TranslatedIntent{..} <- case translateIntent sij of
        Left e ->
            throwIO . userError $
                "intent translation: " <> e
        Right v -> pure v
    IO.hPutStrLn stderr $
        "capture: connecting to " <> socket
    withLocalNodeBackend coNetworkMagic socket $ \backend -> do
        let intent = tiSwapIntent
            allRequired =
                Set.fromList $
                    tiWalletTxIn
                        : siTreasuryUtxos intent
                        ++ [ siScopesDeployedAt intent
                           , siPermissionsDeployedAt intent
                           , siTreasuryDeployedAt intent
                           , siRegistryDeployedAt intent
                           ]
        IO.hPutStrLn stderr "capture: querying chain context"
        ctx <- liveContext backend allRequired
        IO.hPutStrLn stderr "capture: building tx"
        SwapBuildResult{..} <-
            runSwapBuild
                ctx
                SwapBuildInputs
                    { sbiIntent = intent
                    , sbiRationale = tiRationale
                    , sbiWalletTxIn = tiWalletTxIn
                    , sbiWalletAddr = tiWalletAddr
                    , sbiCollateralPercent = 150
                    }
        let exUnitsMap =
                Map.fromList
                    [ (srPurpose r, ex)
                    | r@ScriptResult{srOutcome = Right ex} <-
                        sbrScriptResults
                    ]
            failures =
                [ (srPurpose r, e)
                | r@ScriptResult{srOutcome = Left e} <-
                    sbrScriptResults
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
        let cborStrict = BSL.toStrict sbrCborBytes
            hexed = B16.encode cborStrict
            Coin feeLov = sbrFeeLovelace
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
