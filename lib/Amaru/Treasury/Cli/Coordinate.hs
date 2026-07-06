{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

{- |
Module      : Amaru.Treasury.Cli.Coordinate
Description : CLI parser and runner for coordinator witness collection
License     : Apache-2.0
-}
module Amaru.Treasury.Cli.Coordinate
    ( CoordinateDeps (..)
    , CoordinateOpts (..)
    , CoordinateReceipt (..)
    , coordinateOptsP
    , runCoordinate
    , runCoordinateWith
    ) where

import Data.Aeson
    ( ToJSON (..)
    , encode
    , object
    , (.=)
    )
import Data.ByteString qualified as BS
import Data.ByteString.Lazy.Char8 qualified as BSL8
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word8)
import Options.Applicative
    ( Parser
    , auto
    , help
    , long
    , many
    , metavar
    , option
    , optional
    , strOption
    , value
    )
import Ouroboros.Network.Magic (NetworkMagic)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

import Amaru.Treasury.Cli.Passphrase
    ( readVaultPassphrase
    )
import Amaru.Treasury.Coordinator.Client
    ( CoordinatorBaseUrl
    , EntryStatus
    , Receipt (..)
    , addWitness
    , getFeeStatus
    , httpCoordinatorTransport
    , normalizeCoordinatorBaseUrl
    , publishEntry
    , quoteFee
    , renderCoordinatorClientError
    , submitEntry
    )
import Amaru.Treasury.Coordinator.FeePayment
    ( FeePaymentInputs (..)
    , payCoordinatorFee
    , planCoordinatorFeePayment
    )
import Amaru.Treasury.Coordinator.Workflow
    ( CoordinationEffects (..)
    , CoordinationError (..)
    , CoordinationRequest (..)
    , CoordinationResult (..)
    , WorkflowConfig (..)
    , runCoordinationWorkflow
    )
import Amaru.Treasury.Vault.Age
    ( decryptAgeVault
    , defaultVaultWorkFactor
    , parseVaultWorkFactor
    , renderAgeVaultError
    )
import Amaru.Treasury.Vault.Witness
    ( VaultIdentity
    , decodeWitnessVault
    , renderVaultError
    , resolveVaultIdentity
    )

-- | Options for the @coordinate@ command.
data CoordinateOpts = CoordinateOpts
    { coTxPath :: !(Maybe FilePath)
    , coCoordinatorUrl :: !Text
    , coVaultPath :: !FilePath
    , coPassphraseFd :: !(Maybe Int)
    , coRequester :: !Text
    , coOwners :: !(NonEmpty Text)
    , coFeeWalletTxIn :: !Text
    , coFeeWalletAddress :: !Text
    , coFeeStatusPolls :: !Int
    }
    deriving stock (Eq, Show)

-- | Injectable dependencies for parser/runner tests.
data CoordinateDeps m = CoordinateDeps
    { cdReadTx :: Maybe FilePath -> m Text
    , cdLoadIdentities
        :: CoordinateOpts
        -> m (VaultIdentity, NonEmpty VaultIdentity)
    , cdRunWorkflow
        :: WorkflowConfig
        -> CoordinationRequest
        -> m (Either CoordinationError CoordinationResult)
    }

-- | Machine-readable coordinate command receipt.
data CoordinateReceipt = CoordinateReceipt
    { corEntryId :: !Text
    , corUploadedWitnesses :: ![Text]
    , corSubmittedTxId :: !Text
    , corFeePayment :: !(Maybe Text)
    , corFinalStatus :: !EntryStatus
    }
    deriving stock (Eq, Show)

instance ToJSON CoordinateReceipt where
    toJSON CoordinateReceipt{..} =
        object
            [ "entry_id" .= corEntryId
            , "uploaded_witnesses" .= corUploadedWitnesses
            , "submitted_tx_id" .= corSubmittedTxId
            , "fee_payment" .= corFeePayment
            , "final_status" .= corFinalStatus
            ]

-- | Parser for @coordinate@ command options.
coordinateOptsP :: Parser CoordinateOpts
coordinateOptsP =
    CoordinateOpts
        <$> optional
            ( strOption
                ( long "tx"
                    <> metavar "PATH"
                    <> help
                        "Unsigned Conway transaction CBOR hex (defaults to stdin)"
                )
            )
        <*> ( T.pack
                <$> strOption
                    ( long "coordinator"
                        <> metavar "URL"
                        <> help "Coordinator service root or /v1 URL"
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
                    ( long "requester"
                        <> metavar "LABEL_OR_KEY_HASH"
                        <> help "Vault identity that pre-witnesses the tx"
                    )
            )
        <*> ((:|) <$> ownerP <*> many ownerP)
        <*> ( T.pack
                <$> strOption
                    ( long "fee-wallet-txin"
                        <> metavar "TXHASH#IX"
                        <> help "Wallet UTxO intended to fund the coordinator fee"
                    )
            )
        <*> ( T.pack
                <$> strOption
                    ( long "fee-wallet-address"
                        <> metavar "ADDR"
                        <> help "Requester wallet address for fee payment change"
                    )
            )
        <*> option
            auto
            ( long "fee-status-polls"
                <> metavar "N"
                <> help "Maximum fee-status polling attempts (default: 30)"
                <> value 30
            )
  where
    ownerP =
        T.pack
            <$> strOption
                ( long "owner"
                    <> metavar "LABEL_OR_KEY_HASH"
                    <> help "Owner vault identity to upload; repeat per signer"
                )

-- | Run @coordinate@ with production dependencies and print JSON.
runCoordinate :: NetworkMagic -> FilePath -> CoordinateOpts -> IO ()
runCoordinate magic socketPath opts = do
    receipt <-
        runCoordinateWith (productionDeps magic socketPath opts) opts
    BSL8.putStrLn (encode receipt)

-- | Run @coordinate@ through injected dependencies.
runCoordinateWith
    :: (MonadFail m)
    => CoordinateDeps m
    -> CoordinateOpts
    -> m CoordinateReceipt
runCoordinateWith CoordinateDeps{..} opts@CoordinateOpts{..} = do
    tx <- cdReadTx coTxPath
    (requester, owners) <- cdLoadIdentities opts
    result <-
        cdRunWorkflow
            WorkflowConfig{wcFeeStatusMaxPolls = coFeeStatusPolls}
            CoordinationRequest
                { crUnsignedTx = tx
                , crRequester = requester
                , crOwners = owners
                }
    case result of
        Left err -> fail (T.unpack (renderCoordinationError err))
        Right ok -> pure (receiptFromResult ok)

productionDeps
    :: NetworkMagic -> FilePath -> CoordinateOpts -> CoordinateDeps IO
productionDeps magic socketPath opts =
    CoordinateDeps
        { cdReadTx = readTxText
        , cdLoadIdentities = loadIdentities
        , cdRunWorkflow = \config request -> do
            base <- resolveBaseUrl (coCoordinatorUrl opts)
            runCoordinationWorkflow
                config
                (coordinatorEffects magic socketPath opts base (crRequester request))
                request
        }

coordinatorEffects
    :: NetworkMagic
    -> FilePath
    -> CoordinateOpts
    -> CoordinatorBaseUrl
    -> VaultIdentity
    -> CoordinationEffects IO
coordinatorEffects magic socketPath CoordinateOpts{..} base payer =
    CoordinationEffects
        { cweQuoteFee = quoteFee httpCoordinatorTransport base
        , cwePayFee = payFee
        , cweGetFeeStatus = getFeeStatus httpCoordinatorTransport base
        , cwePublishEntry = publishEntry httpCoordinatorTransport base
        , cweAddWitness = addWitness httpCoordinatorTransport base
        , cweSubmitEntry = submitEntry httpCoordinatorTransport base
        }
  where
    inputs =
        FeePaymentInputs
            { fpiNetworkMagic = magic
            , fpiSocketPath = socketPath
            , fpiPayer = payer
            , fpiWalletTxIn = coFeeWalletTxIn
            , fpiWalletAddress = coFeeWalletAddress
            }
    payFee quote = do
        let plan = planCoordinatorFeePayment quote
        payCoordinatorFee inputs plan

readTxText :: Maybe FilePath -> IO Text
readTxText path =
    TE.decodeUtf8 . stripWhitespace
        <$> maybe BS.getContents BS.readFile path

loadIdentities
    :: CoordinateOpts -> IO (VaultIdentity, NonEmpty VaultIdentity)
loadIdentities CoordinateOpts{..} = do
    passphrase <-
        either die pure
            =<< readVaultPassphrase
                "Vault passphrase: "
                coPassphraseFd
    maxWorkFactor <-
        either (die . renderAgeVaultError) pure $
            parseVaultWorkFactor defaultVaultWorkFactor
    encrypted <- BS.readFile coVaultPath
    cleartext <-
        case decryptAgeVault maxWorkFactor passphrase encrypted of
            Right raw -> pure raw
            Left err ->
                die $
                    "failed to decrypt witness vault `"
                        <> T.pack coVaultPath
                        <> "`: "
                        <> renderAgeVaultError err
    vault <-
        either (die . renderVaultError) pure $
            decodeWitnessVault cleartext
    requester <-
        either (die . renderVaultError) pure $
            resolveVaultIdentity coRequester vault
    owners <-
        traverse
            ( either (die . renderVaultError) pure . (`resolveVaultIdentity` vault)
            )
            coOwners
    pure (requester, owners)

receiptFromResult :: CoordinationResult -> CoordinateReceipt
receiptFromResult CoordinationResult{..} =
    CoordinateReceipt
        { corEntryId = cwrEntryId
        , corUploadedWitnesses = cwrUploadedWitnesses
        , corSubmittedTxId = rTxId cwrReceipt
        , corFeePayment = cwrFeePayment
        , corFinalStatus = cwrFinalStatus
        }

resolveBaseUrl :: Text -> IO CoordinatorBaseUrl
resolveBaseUrl raw =
    either (die . renderCoordinatorClientError) pure $
        normalizeCoordinatorBaseUrl raw

renderCoordinationError :: CoordinationError -> Text
renderCoordinationError = \case
    CoordinationDecodeFailed err -> "decode failed: " <> err
    CoordinationWitnessFailed err -> "witness failed: " <> T.pack (show err)
    CoordinationAttachFailed err -> "attach failed: " <> T.pack (show err)
    CoordinationClientFailure err -> renderCoordinatorClientError err
    CoordinationFeePaymentFailed err -> "fee payment failed: " <> err
    CoordinationBodyHashMismatch expected actual ->
        "coordinator body hash mismatch: expected "
            <> expected
            <> ", got "
            <> actual
    CoordinationFeeNotPaid bodyHash attempts _ ->
        "fee payment not observed for "
            <> bodyHash
            <> " after "
            <> T.pack (show attempts)
            <> " polls"

stripWhitespace :: BS.ByteString -> BS.ByteString
stripWhitespace =
    BS.filter (`notElem` whitespaceBytes)

whitespaceBytes :: [Word8]
whitespaceBytes = [0x20, 0x09, 0x0a, 0x0d]

die :: Text -> IO a
die msg = do
    hPutStrLn stderr ("coordinate: " <> T.unpack msg)
    exitFailure
