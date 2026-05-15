{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

{- |
Module      : Amaru.Treasury.Cli.Vault
Description : CLI commands for encrypted witness vaults
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

The @vault create@ command imports one Cardano payment signing key into
an age-encrypted witness vault. It never writes the cleartext vault
payload to disk.
-}
module Amaru.Treasury.Cli.Vault
    ( VaultCreateOpts (..)
    , VaultSigningKeyInput (..)
    , runVaultCreate
    , vaultCreateOptsP
    ) where

import Control.Applicative ((<|>))
import Control.Exception (IOException, catch, onException)
import Control.Monad (when)
import Data.Aeson (eitherDecodeStrict')
import Data.ByteString qualified as BS
import Data.List.NonEmpty (NonEmpty (..))
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8', encodeUtf8)
import Options.Applicative
    ( Parser
    , auto
    , flag'
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
    , hIsTerminalDevice
    , hPutStrLn
    , openTempFile
    , stderr
    , stdin
    )

import System.Console.Haskeline
    ( InputT
    , defaultSettings
    , getPassword
    , outputStrLn
    , runInputT
    )

import Amaru.Treasury.Cli.Common
    ( GlobalOpts
    , resolveNetworkName
    )
import Amaru.Treasury.Cli.Passphrase
    ( readVaultPassphraseConfirmed
    )
import Amaru.Treasury.Tx.Witness
    ( renderTxWitnessError
    , signingSourceKeyHash
    )
import Amaru.Treasury.Vault.Age
    ( defaultVaultWorkFactor
    , encryptAgeVault
    , parseVaultWorkFactor
    , renderAgeVaultError
    )
import Amaru.Treasury.Vault.Witness
    ( SigningSource (..)
    , VaultIdentitySpec (..)
    , encodeWitnessVault
    )

-- | Secret signing-key input source for @vault create@.
data VaultSigningKeyInput
    = VaultSigningKeyPaste
    | VaultSigningKeyStdin
    | VaultSigningKeyFile !FilePath
    deriving stock (Eq, Show)

-- | Options for @vault create@.
data VaultCreateOpts = VaultCreateOpts
    { vcoSigningKeyInput :: !VaultSigningKeyInput
    , vcoLabel :: !Text
    , vcoDescription :: !(Maybe Text)
    , vcoOutPath :: !FilePath
    , vcoPassphraseFd :: !(Maybe Int)
    , vcoWorkFactor :: !(Maybe Int)
    , vcoForce :: !Bool
    }
    deriving stock (Eq, Show)

-- | Parser for @vault create@ options.
vaultCreateOptsP :: Parser VaultCreateOpts
vaultCreateOptsP =
    VaultCreateOpts
        <$> signingKeyInputP
        <*> ( T.pack
                <$> strOption
                    ( long "label"
                        <> metavar "LABEL"
                        <> help "Stable vault identity label"
                    )
            )
        <*> optional
            ( T.pack
                <$> strOption
                    ( long "description"
                        <> metavar "TEXT"
                        <> help "Optional non-secret vault identity note"
                    )
            )
        <*> strOption
            ( long "out"
                <> short 'o'
                <> metavar "PATH"
                <> help "Path to write the encrypted age vault"
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
        <*> optional
            ( option
                auto
                ( long "vault-work-factor"
                    <> metavar "INT"
                    <> help "age scrypt work factor (1-18; default: 18)"
                )
            )
        <*> switch
            ( long "force"
                <> help "Overwrite an existing --out path"
            )

signingKeyInputP :: Parser VaultSigningKeyInput
signingKeyInputP =
    ( VaultSigningKeyPaste
        <$ flag'
            ()
            ( long "signing-key-paste"
                <> help
                    "Paste a cardano-cli .skey JSON envelope or cardano-addresses addr_xsk with terminal echo disabled"
            )
    )
        <|> ( VaultSigningKeyStdin
                <$ flag'
                    ()
                    ( long "signing-key-stdin"
                        <> help
                            "Read cardano-cli .skey JSON or cardano-addresses addr_xsk from non-terminal stdin"
                    )
            )
        <|> ( VaultSigningKeyFile
                <$> strOption
                    ( long "signing-key-file"
                        <> metavar "PATH"
                        <> help
                            "Read cardano-cli .skey JSON or cardano-addresses addr_xsk from a file (compatibility/testing; prefer --signing-key-paste)"
                    )
            )

-- | Run @vault create@.
runVaultCreate :: GlobalOpts -> VaultCreateOpts -> IO ()
runVaultCreate g VaultCreateOpts{..} = do
    networkName <-
        either (die . T.pack) pure (resolveNetworkName g)
    ensureWritableOutput vcoOutPath vcoForce
    signingSource <- readSigningKeySource vcoSigningKeyInput
    keyHash <-
        either (die . renderTxWitnessError) pure $
            signingSourceKeyHash signingSource
    workFactor <-
        either (die . renderAgeVaultError) pure $
            parseVaultWorkFactor (fromMaybe defaultVaultWorkFactor vcoWorkFactor)
    passphrase <-
        either die pure =<< readVaultPassphraseConfirmed vcoPassphraseFd
    encrypted <-
        either (die . renderAgeVaultError) pure
            =<< encryptAgeVault
                workFactor
                passphrase
                ( encodeWitnessVault
                    ( VaultIdentitySpec
                        { visLabel = vcoLabel
                        , visNetwork = networkName
                        , visKeyHash = keyHash
                        , visDescription = vcoDescription
                        , visSource = signingSource
                        }
                        :| []
                    )
                )
    writeFileAtomic vcoOutPath encrypted

readSigningKeySource :: VaultSigningKeyInput -> IO SigningSource
readSigningKeySource = \case
    VaultSigningKeyPaste ->
        either die pure =<< runInputT defaultSettings readPastedSigningKey
    VaultSigningKeyStdin -> do
        terminal <- hIsTerminalDevice stdin
        when terminal $
            die
                "refusing to read signing-key material from terminal stdin; use --signing-key-paste"
        decodeSigningKeySource "from stdin" =<< BS.getContents
    VaultSigningKeyFile path ->
        decodeSigningKeySource
            ("`" <> T.pack path <> "`")
            =<< BS.readFile path

readPastedSigningKey :: InputT IO (Either Text SigningSource)
readPastedSigningKey = do
    outputStrLn
        "Paste Cardano signing-key material. Accepted formats: cardano-cli .skey JSON or cardano-addresses addr_xsk. Input is hidden."
    go mempty
  where
    go acc = do
        line <- getPassword Nothing (prompt acc)
        case line of
            Nothing ->
                pure (decodePastedSigningKey acc)
            Just pastedLine -> do
                let next = acc <> T.pack pastedLine <> "\n"
                case decodePastedSigningKey next of
                    Right source -> pure (Right source)
                    Left err
                        | looksLikeJsonObject next -> go next
                        | otherwise -> pure (Left err)

    prompt acc
        | T.null acc = "signing key: "
        | otherwise = ""

decodePastedSigningKey :: Text -> Either Text SigningSource
decodePastedSigningKey raw
    | T.null raw = Left "no signing-key material was pasted"
    | otherwise =
        decodeSigningKeySourceText "from hidden paste" raw

decodeSigningKeySource :: Text -> BS.ByteString -> IO SigningSource
decodeSigningKeySource source raw =
    case decodeUtf8' raw of
        Left err ->
            die $
                "signing-key material "
                    <> source
                    <> " is not UTF-8 text: "
                    <> T.pack (show err)
        Right text ->
            case decodeSigningKeySourceText source text of
                Left err -> die err
                Right value -> pure value

decodeSigningKeySourceText
    :: Text -> Text -> Either Text SigningSource
decodeSigningKeySourceText source raw
    | T.null trimmed =
        Left ("empty signing-key material " <> source)
    | looksLikeJsonObject trimmed =
        case eitherDecodeStrict' (textBytes raw) of
            Left err ->
                Left $
                    "malformed signing-key JSON "
                        <> source
                        <> ": "
                        <> T.pack err
            Right value -> Right (CardanoCliSKey value)
    | "addr_xsk1" `T.isPrefixOf` T.toLower trimmed =
        Right (CardanoAddressesAddrXsk trimmed)
    | otherwise =
        Left $
            "unsupported signing-key material "
                <> source
                <> ": expected cardano-cli .skey JSON or cardano-addresses addr_xsk"
  where
    trimmed = T.strip raw

textBytes :: Text -> BS.ByteString
textBytes =
    encodeUtf8

looksLikeJsonObject :: Text -> Bool
looksLikeJsonObject raw =
    "{" `T.isPrefixOf` T.stripStart raw

ensureWritableOutput :: FilePath -> Bool -> IO ()
ensureWritableOutput path force = do
    exists <- doesFileExist path
    when (exists && not force) $
        die ("output path already exists: " <> T.pack path)

writeFileAtomic :: FilePath -> BS.ByteString -> IO ()
writeFileAtomic path bytes = do
    let dir = takeDirectory path
    (tmp, handle) <- openTempFile dir ".vault.tmp"
    hClose handle
    (BS.writeFile tmp bytes >> renameFile tmp path)
        `onException` ignoreRemove tmp

ignoreRemove :: FilePath -> IO ()
ignoreRemove path =
    removeFile path `catch` \(_ :: IOException) -> pure ()

die :: Text -> IO a
die msg = do
    hPutStrLn stderr ("vault create: " <> T.unpack msg)
    exitFailure
