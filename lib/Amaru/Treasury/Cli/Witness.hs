{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

{- |
Module      : Amaru.Treasury.Cli.Witness
Description : CLI parser and runner for detached witness creation
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

The @witness@ command creates one detached vkey witness from an
encrypted age vault identity. Transaction construction and witness
assembly remain separate commands.
-}
module Amaru.Treasury.Cli.Witness
    ( WitnessOpts (..)
    , runWitness
    , witnessOptsP
    ) where

import Control.Exception (IOException, catch, onException)
import Control.Monad (unless, when)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Options.Applicative
    ( Parser
    , auto
    , help
    , long
    , metavar
    , option
    , optional
    , short
    , strOption
    , switch
    )
import System.Directory
    ( doesFileExist
    , removeFile
    , renameFile
    )
import System.Exit (exitFailure)
import System.FilePath (takeDirectory)
import System.IO
    ( hClose
    , hPutStrLn
    , openTempFile
    , stderr
    , stdout
    )

import Amaru.Treasury.Cli.Common
    ( GlobalOpts
    , resolveNetworkName
    )
import Amaru.Treasury.Cli.Passphrase
    ( readVaultPassphrase
    )
import Amaru.Treasury.Tx.Witness
    ( createWitness
    , decodeWitnessTransaction
    , parseWitnessKeyHash
    , renderTxWitnessError
    , validateWitnessRequest
    , witnessTransactionFacts
    )
import Amaru.Treasury.Vault.Age
    ( VaultPassphrase
    , decryptAgeVault
    , defaultVaultWorkFactor
    , parseVaultWorkFactor
    , renderAgeVaultError
    )
import Amaru.Treasury.Vault.Witness
    ( decodeWitnessVault
    , renderVaultError
    , resolveVaultIdentity
    , vaultIdentityNetwork
    )

-- | Options for the @witness@ command.
data WitnessOpts = WitnessOpts
    { woTxPath :: !(Maybe FilePath)
    , woVaultPath :: !FilePath
    , woPassphraseFd :: !(Maybe Int)
    , woIdentity :: !Text
    , woExpectedKeyHash :: !(Maybe Text)
    , woAllowUnlistedKey :: !Bool
    , woOutPath :: !(Maybe FilePath)
    , woForce :: !Bool
    }
    deriving stock (Eq, Show)

-- | Parser for @witness@ command options.
witnessOptsP :: Parser WitnessOpts
witnessOptsP =
    WitnessOpts
        <$> optional
            ( strOption
                ( long "tx"
                    <> metavar "PATH"
                    <> help
                        "Unsigned Conway transaction CBOR hex or cardano-cli envelope (defaults to stdin)"
                )
            )
        <*> strOption
            ( long "vault"
                <> metavar "PATH"
                <> help "age-encrypted witness vault"
            )
        <*> optional
            ( option
                auto
                ( long "vault-passphrase-fd"
                    <> metavar "FD"
                    <> help
                        "Read the vault passphrase from an inherited file descriptor"
                )
            )
        <*> ( T.pack
                <$> strOption
                    ( long "identity"
                        <> metavar "LABEL_OR_KEY_HASH"
                        <> help "Vault identity label or 28-byte key hash"
                    )
            )
        <*> optional
            ( T.pack
                <$> strOption
                    ( long "expected-key-hash"
                        <> metavar "HASH"
                        <> help
                            "Assert the selected identity key hash, required for unlisted-key transactions unless --allow-unlisted-key is used"
                    )
            )
        <*> switch
            ( long "allow-unlisted-key"
                <> help
                    "Allow signing when the transaction declares no required signer hashes"
            )
        <*> optional
            ( strOption
                ( long "out"
                    <> short 'o'
                    <> metavar "PATH"
                    <> help
                        "Path to write witness CBOR hex (defaults to stdout)"
                )
            )
        <*> switch
            ( long "force"
                <> help "Overwrite an existing --out path"
            )

-- | Run the @witness@ command.
runWitness :: GlobalOpts -> WitnessOpts -> IO ()
runWitness g opts@WitnessOpts{..} = do
    networkName <-
        either (die . T.pack) pure (resolveNetworkName g)
    txBytes <- maybe BS.getContents BS.readFile woTxPath
    passphrase <-
        either die pure
            =<< readVaultPassphrase
                "Vault passphrase: "
                woPassphraseFd
    vaultBytes <- decryptVault woVaultPath passphrase

    vault <-
        either (die . renderVaultError) pure $
            decodeWitnessVault vaultBytes
    identity <-
        either (die . renderVaultError) pure $
            resolveVaultIdentity woIdentity vault
    unless (vaultIdentityNetwork identity == networkName) $
        die $
            "vault identity network `"
                <> vaultIdentityNetwork identity
                <> "` does not match selected network `"
                <> networkName
                <> "`"
    tx <-
        either (die . renderTxWitnessError) pure $
            decodeWitnessTransaction txBytes
    expectedKeyHash <-
        traverse
            (either (die . renderTxWitnessError) pure . parseWitnessKeyHash)
            woExpectedKeyHash
    either (die . renderTxWitnessError) pure $
        validateWitnessRequest
            expectedKeyHash
            woAllowUnlistedKey
            identity
            (witnessTransactionFacts tx)
    witnessHex <-
        either (die . renderTxWitnessError) pure $
            createWitness identity tx
    writeWitness opts witnessHex

decryptVault :: FilePath -> VaultPassphrase -> IO BS.ByteString
decryptVault path passphrase = do
    maxWorkFactor <-
        either (die . renderAgeVaultError) pure $
            parseVaultWorkFactor defaultVaultWorkFactor
    encrypted <- BS.readFile path
    case decryptAgeVault maxWorkFactor passphrase encrypted of
        Right cleartext -> pure cleartext
        Left err ->
            die $
                "failed to decrypt witness vault `"
                    <> T.pack path
                    <> "`: "
                    <> renderAgeVaultError err

writeWitness :: WitnessOpts -> BS.ByteString -> IO ()
writeWitness WitnessOpts{woOutPath = Nothing} witnessHex =
    BS.hPut stdout witnessHex >> BS.hPut stdout "\n"
writeWitness WitnessOpts{woOutPath = Just path, woForce} witnessHex = do
    exists <- doesFileExist path
    when (exists && not woForce) $
        die ("output path already exists: " <> T.pack path)
    writeFileAtomic path witnessHex

writeFileAtomic :: FilePath -> BS.ByteString -> IO ()
writeFileAtomic path bytes = do
    let dir = takeDirectory path
    (tmp, handle) <- openTempFile dir ".witness.tmp"
    hClose handle
    (BS.writeFile tmp bytes >> renameFile tmp path)
        `onException` ignoreRemove tmp

ignoreRemove :: FilePath -> IO ()
ignoreRemove path =
    removeFile path `catch` \(_ :: IOException) -> pure ()

die :: Text -> IO a
die msg = do
    hPutStrLn stderr ("witness: " <> T.unpack msg)
    exitFailure
