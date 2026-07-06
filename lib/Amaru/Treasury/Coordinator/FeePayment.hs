{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

{- |
Module      : Amaru.Treasury.Coordinator.FeePayment
Description : Coordinator fee-payment boundary
License     : Apache-2.0

This module isolates the fee-payment contract from the coordinator
workflow. The pure plan pins the ledger-critical target: the quoted
fee address, quoted lovelace, and metadata label @9721@ carrying the
quoted transaction body hash. The node-backed payment executor remains
behind a small boundary so workflow and CLI tests can inject it.
-}
module Amaru.Treasury.Coordinator.FeePayment
    ( FeePaymentInputs (..)
    , FeePaymentPlan (..)
    , coordinatorFeeMetadataLabel
    , planCoordinatorFeePayment
    , payCoordinatorFee
    ) where

import Data.Aeson
    ( Value
    , encode
    , object
    , (.=)
    )
import Data.Aeson.Key qualified as Key
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word64)
import Ouroboros.Network.Magic (NetworkMagic (..))
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process
    ( proc
    , readCreateProcessWithExitCode
    )

import Amaru.Treasury.Coordinator.Client
    ( FeeQuote (..)
    )
import Amaru.Treasury.Tx.AttachWitness
    ( attachWitnesses
    , decodeVKeyWitnessHex
    , encodeSignedTxHex
    )
import Amaru.Treasury.Tx.Submit
    ( SubmitOutcome (..)
    , renderSubmitOutcome
    , submitSignedTx
    )
import Amaru.Treasury.Tx.Witness
    ( createWitness
    , decodeWitnessTransaction
    , renderTxWitnessError
    )
import Amaru.Treasury.Vault.Witness
    ( VaultIdentity
    )

-- | Metadata label required by the coordinator fee contract.
coordinatorFeeMetadataLabel :: Word64
coordinatorFeeMetadataLabel = 9721

-- | Operator-supplied local wallet hints for the fee boundary.
data FeePaymentInputs = FeePaymentInputs
    { fpiNetworkMagic :: !NetworkMagic
    -- ^ Network magic for cardano-cli build and node submit.
    , fpiSocketPath :: !FilePath
    -- ^ Local cardano-node socket path.
    , fpiPayer :: !VaultIdentity
    -- ^ Vault identity that signs the fee transaction.
    , fpiWalletTxIn :: !Text
    -- ^ Wallet UTxO intended to fund the coordinator fee.
    , fpiWalletAddress :: !Text
    -- ^ Change/signing wallet address for the fee transaction.
    }
    deriving stock (Eq, Show)

-- | Pure fee-payment plan derived from a coordinator quote.
data FeePaymentPlan = FeePaymentPlan
    { fppAddress :: !Text
    -- ^ Quoted coordinator fee address.
    , fppLovelace :: !Integer
    -- ^ Quoted lovelace amount.
    , fppMetadataLabel :: !Word64
    -- ^ Metadata label, pinned to 'coordinatorFeeMetadataLabel'.
    , fppMetadata :: !Value
    -- ^ Metadata payload carrying the quoted body hash.
    }
    deriving stock (Eq, Show)

-- | Build the ledger-critical fee-payment plan from a quote.
planCoordinatorFeePayment :: FeeQuote -> FeePaymentPlan
planCoordinatorFeePayment FeeQuote{..} =
    FeePaymentPlan
        { fppAddress = fqFeeAddress
        , fppLovelace = fqRequiredFeeLovelace
        , fppMetadataLabel = coordinatorFeeMetadataLabel
        , fppMetadata = object ["body_hash" .= fqBodyHash]
        }

{- | Execute a coordinator fee payment.

S3 keeps this as a narrow boundary: tests inject the effect through the
workflow, while the production runner builds, signs, and submits the
fee payment before polling the coordinator. The coordinator discovers
the matching metadata-tagged payment by body hash, so no output
reference is returned locally.
-}
payCoordinatorFee
    :: FeePaymentInputs
    -> FeePaymentPlan
    -> IO (Either Text (Maybe Text))
payCoordinatorFee inputs@FeePaymentInputs{..} plan@FeePaymentPlan{..}
    | T.null (T.strip fpiWalletTxIn) =
        pure (Left "fee wallet tx-in is required")
    | T.null (T.strip fpiWalletAddress) =
        pure (Left "fee wallet address is required")
    | T.null (T.strip fppAddress) =
        pure (Left "coordinator fee address is required")
    | fppLovelace <= 0 =
        pure (Left "coordinator fee lovelace must be positive")
    | otherwise =
        runFeePayment inputs plan

runFeePayment
    :: FeePaymentInputs
    -> FeePaymentPlan
    -> IO (Either Text (Maybe Text))
runFeePayment inputs plan =
    withSystemTempDirectory "amaru-coordinator-fee" $ \dir -> do
        metadataPath <- writeMetadataFile dir plan
        let unsignedPath = dir </> "coordinator-fee.body"
        result <-
            runCardanoCli $
                buildFeeTxArgs inputs plan metadataPath unsignedPath
        case result of
            Left err ->
                pure (Left err)
            Right () -> do
                txBytes <- BS.readFile unsignedPath
                case signAndSubmit inputs txBytes of
                    Left err -> pure (Left err)
                    Right action -> action

signAndSubmit
    :: FeePaymentInputs
    -> BS.ByteString
    -> Either Text (IO (Either Text (Maybe Text)))
signAndSubmit FeePaymentInputs{..} txBytes = do
    tx <-
        either
            (Left . renderTxWitnessError)
            Right
            (decodeWitnessTransaction txBytes)
    witnessHex <-
        either
            (Left . renderTxWitnessError)
            Right
            (createWitness fpiPayer tx)
    witness <-
        either
            (Left . T.pack . show)
            Right
            (decodeVKeyWitnessHex 1 witnessHex)
    let signedTxHex = encodeSignedTxHex (attachWitnesses (Set.singleton witness) tx)
    pure $ do
        outcome <-
            submitSignedTx
                fpiNetworkMagic
                fpiSocketPath
                signedTxHex
        pure $
            case outcome of
                SubmitAccepted{} ->
                    Right Nothing
                SubmitRejected{} ->
                    Left (renderSubmitOutcome outcome)
                SubmitDecodeFailed{} ->
                    Left (renderSubmitOutcome outcome)

buildFeeTxArgs
    :: FeePaymentInputs
    -> FeePaymentPlan
    -> FilePath
    -> FilePath
    -> [String]
buildFeeTxArgs FeePaymentInputs{..} FeePaymentPlan{..} metadataPath outPath =
    [ "conway"
    , "transaction"
    , "build"
    ]
        <> networkArgs fpiNetworkMagic
        <> [ "--socket-path"
           , fpiSocketPath
           , "--tx-in"
           , T.unpack fpiWalletTxIn
           , "--tx-out"
           , T.unpack fppAddress <> "+" <> show fppLovelace
           , "--change-address"
           , T.unpack fpiWalletAddress
           , "--json-metadata-no-schema"
           , "--metadata-json-file"
           , metadataPath
           , "--witness-override"
           , "1"
           , "--out-file"
           , outPath
           ]

networkArgs :: NetworkMagic -> [String]
networkArgs (NetworkMagic 764824073) = ["--mainnet"]
networkArgs (NetworkMagic magic) =
    ["--testnet-magic", show magic]

writeMetadataFile :: FilePath -> FeePaymentPlan -> IO FilePath
writeMetadataFile dir FeePaymentPlan{..} = do
    let path = dir </> "coordinator-fee-metadata.json"
    BSL.writeFile path $
        encode $
            object [Key.fromText (T.pack (show fppMetadataLabel)) .= fppMetadata]
    pure path

runCardanoCli :: [String] -> IO (Either Text ())
runCardanoCli args = do
    (code, out, err) <-
        readCreateProcessWithExitCode (proc "cardano-cli" args) ""
    pure $
        case code of
            ExitSuccess -> Right ()
            ExitFailure n ->
                Left $
                    "cardano-cli fee payment build failed with exit "
                        <> T.pack (show n)
                        <> ": "
                        <> decodeProcessOutput out err

decodeProcessOutput :: String -> String -> Text
decodeProcessOutput out err =
    T.strip $
        T.pack err
            <> if null out then "" else "\n" <> T.pack out
