{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE RecordWildCards #-}

{- |
Module      : Main
Description : amaru-treasury-tx CLI entry point
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Parses CLI arguments, wires up the local-node 'Provider'
backend, dispatches to the matching transaction-build
program, re-evaluates every redeemer against the final
tx, and emits an unsigned Conway transaction CBOR (hex)
on stdout (or a path).

Currently exposes one subcommand:

* @swap --intent path\/to\/intent.json [--out path\/swap.cbor]@ —
  builds the SundaeSwap order tx for a treasury scope.
  See [@docs\/swap.md@](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/docs/swap.md).
-}
module Main (main) where

import Control.Exception (throwIO)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as BSL
import Data.Maybe (fromMaybe)
import Options.Applicative
    ( Parser
    , ParserInfo
    , auto
    , command
    , execParser
    , fullDesc
    , help
    , helper
    , hsubparser
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
import System.Exit (exitFailure)
import System.IO (stderr)
import System.IO qualified as IO

import Cardano.Ledger.Coin (Coin (..))
import Ouroboros.Network.Magic (NetworkMagic (..))

import Data.Set qualified as Set

import Amaru.Treasury.Backend.N2C (withLocalNodeBackend)
import Amaru.Treasury.ChainContext (liveContext)
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

data GlobalOpts = GlobalOpts
    { goSocketPath :: !(Maybe FilePath)
    , goNetworkMagic :: !NetworkMagic
    }

newtype Cmd = CmdSwap SwapOpts

data SwapOpts = SwapOpts
    { soIntentPath :: !FilePath
    , soOutPath :: !(Maybe FilePath)
    }

globalOptsP :: Parser GlobalOpts
globalOptsP =
    GlobalOpts
        <$> optional
            ( strOption
                ( long "node-socket"
                    <> metavar "PATH"
                    <> help
                        "cardano-node N2C socket (defaults to CARDANO_NODE_SOCKET_PATH)"
                )
            )
        <*> ( NetworkMagic
                <$> option
                    auto
                    ( long "network-magic"
                        <> metavar "WORD32"
                        <> help "Network magic (mainnet=764824073)"
                        <> value 764_824_073
                    )
            )

swapOptsP :: Parser SwapOpts
swapOptsP =
    SwapOpts
        <$> strOption
            ( long "intent"
                <> short 'i'
                <> metavar "PATH"
                <> help "Path to the swap-intent JSON"
            )
        <*> optional
            ( strOption
                ( long "out"
                    <> short 'o'
                    <> metavar "PATH"
                    <> help "Write hex CBOR here (defaults to stdout)"
                )
            )

cmdP :: Parser Cmd
cmdP =
    hsubparser
        ( command
            "swap"
            ( info
                (CmdSwap <$> swapOptsP)
                ( progDesc
                    "Build a SundaeSwap treasury swap (ADA→USDM)"
                )
            )
        )

opts :: ParserInfo (GlobalOpts, Cmd)
opts =
    info
        ( ((,) <$> globalOptsP <*> cmdP)
            <**> helper
        )
        ( fullDesc
            <> progDesc
                "Build unsigned Amaru treasury transactions"
        )

main :: IO ()
main = do
    (g, c) <- execParser opts
    socket <- resolveSocket (goSocketPath g)
    case c of
        CmdSwap so ->
            runSwap g{goSocketPath = Just socket} so

resolveSocket :: Maybe FilePath -> IO FilePath
resolveSocket (Just p) = pure p
resolveSocket Nothing = do
    mEnv <- lookupEnv "CARDANO_NODE_SOCKET_PATH"
    case mEnv of
        Just p -> pure p
        Nothing ->
            throwIO . userError $
                "amaru-treasury-tx: pass --node-socket "
                    <> "or set CARDANO_NODE_SOCKET_PATH"

runSwap :: GlobalOpts -> SwapOpts -> IO ()
runSwap g SwapOpts{..} = do
    let socket = fromMaybe "(unset)" (goSocketPath g)
    IO.hPutStrLn stderr $
        "amaru-treasury-tx swap: reading "
            <> soIntentPath
    parsed <- decodeSwapIntentFile soIntentPath
    case parsed of
        Left e ->
            throwIO . userError $
                "intent JSON: " <> e
        Right sij -> case translateIntent sij of
            Left e ->
                throwIO . userError $
                    "intent translation: " <> e
            Right TranslatedIntent{..} -> do
                IO.hPutStrLn stderr $
                    "amaru-treasury-tx swap: connecting to "
                        <> socket
                withLocalNodeBackend
                    (goNetworkMagic g)
                    socket
                    $ \backend -> do
                        let intent = tiSwapIntent
                            allRequired =
                                Set.fromList $
                                    tiWalletTxIn
                                        : siTreasuryUtxos intent
                                        ++ [ siScopesDeployedAt
                                                intent
                                           , siPermissionsDeployedAt
                                                intent
                                           , siTreasuryDeployedAt
                                                intent
                                           , siRegistryDeployedAt
                                                intent
                                           ]
                        ctx <- liveContext backend allRequired
                        let inputs =
                                SwapBuildInputs
                                    { sbiIntent = intent
                                    , sbiRationale =
                                        tiRationale
                                    , sbiWalletTxIn =
                                        tiWalletTxIn
                                    , sbiWalletAddr =
                                        tiWalletAddr
                                    }
                        SwapBuildResult{..} <-
                            runSwapBuild ctx inputs
                        let cborStrict =
                                BSL.toStrict sbrCborBytes
                            hexed = B16.encode cborStrict
                            Coin feeLov = sbrFeeLovelace
                            Coin tcLov =
                                sbrTotalCollateralLovelace
                            failures =
                                [ (purpose, e)
                                | ScriptResult
                                    purpose
                                    (Left e) <-
                                    sbrScriptResults
                                ]
                        IO.hPutStrLn stderr $
                            "amaru-treasury-tx swap: "
                                <> show
                                    (BS.length cborStrict)
                                <> " bytes  fee="
                                <> show feeLov
                                <> "  total_collateral="
                                <> show tcLov
                        IO.hPutStrLn stderr $
                            "amaru-treasury-tx swap: "
                                <> "re-evaluated "
                                <> show
                                    (length sbrScriptResults)
                                <> " redeemers, "
                                <> show (length failures)
                                <> " failed"
                        mapM_
                            ( \(p, e) ->
                                IO.hPutStrLn stderr $
                                    "  FAIL: "
                                        <> show p
                                        <> " — "
                                        <> e
                            )
                            failures
                        case soOutPath of
                            Just p -> BS.writeFile p hexed
                            Nothing -> do
                                BS.putStr hexed
                                putStr "\n"
                        if null failures
                            then
                                IO.hPutStrLn
                                    stderr
                                    "amaru-treasury-tx swap: VALIDATION OK"
                            else do
                                IO.hPutStrLn
                                    stderr
                                    "amaru-treasury-tx swap: VALIDATION FAILED"
                                exitFailure
