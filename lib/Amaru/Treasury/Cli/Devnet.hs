{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

{- |
Module      : Amaru.Treasury.Cli.Devnet
Description : DevNet-only operator commands
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Parser and runner for local DevNet bootstrap commands. These commands
are intentionally gated to the local @devnet@ network before any
signing-key material is read or any node connection is opened.
-}
module Amaru.Treasury.Cli.Devnet
    ( DevnetRegistryInitOpts (..)
    , devnetRegistryInitOptsP
    , requireDevnetRegistryInitNetwork
    , registryInitCommandLines
    , runDevnetRegistryInit
    ) where

import Control.Monad (unless)
import Data.Aeson
    ( Value
    , eitherDecodeFileStrict
    )
import Data.Text qualified as T
import Options.Applicative
    ( Parser
    , help
    , long
    , metavar
    , strOption
    )
import Ouroboros.Network.Magic (NetworkMagic (..))
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

import Cardano.Crypto.DSIGN.Class (SignKeyDSIGN)
import Cardano.Ledger.Address (Addr, getNetwork)
import Cardano.Ledger.BaseTypes (Network (Testnet))
import Cardano.Ledger.Keys (DSIGN)
import Cardano.Node.Client.Provider (Provider (..))

import Amaru.Treasury.Backend.N2C
    ( withLocalNodeClient
    )
import Amaru.Treasury.Cli.Common
    ( GlobalOpts (..)
    , resolveSocket
    )
import Amaru.Treasury.Devnet.RegistryInit
    ( DevnetRegistryInitConfig (..)
    )
import Amaru.Treasury.Devnet.RegistryInit qualified as RegistryInit
import Amaru.Treasury.IntentJSON.Common
    ( parseAddr
    )
import Amaru.Treasury.Tx.Submit
    ( renderTxId
    )
import Amaru.Treasury.Tx.Witness
    ( addCardanoCliPaymentKeyWitness
    , cardanoCliPaymentKeyHash
    , decodeCardanoCliSigningKey
    , renderTxWitnessError
    )

-- | Options for @devnet registry-init@.
data DevnetRegistryInitOpts = DevnetRegistryInitOpts
    { drioFundingAddress :: !String
    , drioSigningKeyFile :: !FilePath
    , drioRunDir :: !FilePath
    }
    deriving stock (Eq, Show)

-- | Parser for the @registry-init@ DevNet subcommand.
devnetRegistryInitOptsP :: Parser DevnetRegistryInitOpts
devnetRegistryInitOptsP =
    DevnetRegistryInitOpts
        <$> strOption
            ( long "funding-address"
                <> metavar "ADDR"
                <> help "DevNet funding address that owns bootstrap UTxOs"
            )
        <*> strOption
            ( long "signing-key-file"
                <> metavar "PATH"
                <> help "cardano-cli payment signing-key JSON for funding UTxOs"
            )
        <*> strOption
            ( long "run-dir"
                <> metavar "DIR"
                <> help "Directory where registry-init artifacts are written"
            )

-- | Validate that the global network selection is exactly DevNet.
requireDevnetRegistryInitNetwork :: GlobalOpts -> Either String ()
requireDevnetRegistryInitNetwork GlobalOpts{..}
    | goNetworkName == Just "devnet"
        && goNetworkMagic == NetworkMagic 42 =
        Right ()
    | otherwise =
        Left "registry-init: --network must be devnet"

-- | Run @devnet registry-init@ against a local DevNet node.
runDevnetRegistryInit
    :: GlobalOpts
    -> DevnetRegistryInitOpts
    -> IO ()
runDevnetRegistryInit globals DevnetRegistryInitOpts{..} = do
    case requireDevnetRegistryInitNetwork globals of
        Left err -> abort err
        Right () -> pure ()
    fundingAddress <- parseFundingAddress drioFundingAddress
    signingKey <- readPaymentSigningKey drioSigningKeyFile
    socket <- resolveSocket (goSocketPath globals)
    let networkMagic =
            fromIntegral (unNetworkMagic (goNetworkMagic globals))
        config =
            DevnetRegistryInitConfig
                { dricNetwork = Testnet
                , dricFundingAddress = fundingAddress
                , dricOwnerKeyHash =
                    cardanoCliPaymentKeyHash signingKey
                , dricSignTx =
                    addCardanoCliPaymentKeyWitness signingKey
                }
    withLocalNodeClient (goNetworkMagic globals) socket $
        \provider submitter -> do
            pp <- queryProtocolParams provider
            utxos <- queryUTxOs provider fundingAddress
            publication <-
                RegistryInit.publishDevnetRegistryInit
                    config
                    provider
                    submitter
                    pp
                    utxos
            RegistryInit.verifyRegistryInitPublication
                provider
                publication
            let linesOut =
                    registryInitCommandLines
                        networkMagic
                        drioRunDir
                        ( T.unpack
                            ( renderTxId
                                (RegistryInit.drpSeedSplitTxId publication)
                            )
                        )
                        ( T.unpack
                            ( renderTxId
                                ( RegistryInit.drpRegistryMintTxId
                                    publication
                                )
                            )
                        )
                        ( T.unpack
                            ( renderTxId
                                ( RegistryInit.drpReferenceScriptsTxId
                                    publication
                                )
                            )
                        )
            RegistryInit.writeRegistryInitArtifactsWithLines
                networkMagic
                drioRunDir
                publication
                linesOut
            mapM_
                putStrLn
                linesOut

-- | Human-readable success lines for the shipped registry-init command.
registryInitCommandLines
    :: Int
    -> FilePath
    -> String
    -> String
    -> String
    -> [String]
registryInitCommandLines
    networkMagic
    runDir
    seedSplitTxId
    registryMintTxId
    referenceScriptsTxId =
        [ "registry-init: run-dir " <> runDir
        , "registry-init: network devnet magic " <> show networkMagic
        , "registry-init: phase registry-init passed"
        , "registry-init: seed-split-tx-id " <> seedSplitTxId
        , "registry-init: registry-mint-tx-id " <> registryMintTxId
        , "registry-init: reference-scripts-tx-id "
            <> referenceScriptsTxId
        , "registry-init: summary "
            <> RegistryInit.registryInitSummaryPath runDir
        , "registry-init: registry "
            <> RegistryInit.registryInitRegistryPath runDir
        ]

parseFundingAddress :: String -> IO Addr
parseFundingAddress raw =
    case parseAddr (T.pack raw) of
        Left err ->
            abort $
                "registry-init: --funding-address: " <> err
        Right addr -> do
            unless (getNetwork addr == Testnet) $
                abort
                    "registry-init: --funding-address must be a testnet address"
            pure addr

readPaymentSigningKey
    :: FilePath
    -> IO (SignKeyDSIGN DSIGN)
readPaymentSigningKey path = do
    decoded <- eitherDecodeFileStrict path :: IO (Either String Value)
    value <- case decoded of
        Left err ->
            abort $
                "registry-init: --signing-key-file: " <> err
        Right value -> pure value
    case decodeCardanoCliSigningKey value of
        Left err ->
            abort $
                "registry-init: --signing-key-file: "
                    <> T.unpack (renderTxWitnessError err)
        Right signingKey -> pure signingKey

abort :: String -> IO a
abort message = do
    hPutStrLn stderr message
    exitFailure
