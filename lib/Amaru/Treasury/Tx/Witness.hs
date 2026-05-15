{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

{- |
Module      : Amaru.Treasury.Tx.Witness
Description : Create detached Conway vkey witnesses
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Pure helpers for the vault-backed witness command. The module decodes
the unsigned Conway transaction shape already used by @attach-witness@,
checks selected-key facts, and creates one detached vkey witness from
a decrypted vault signing-key envelope.
-}
module Amaru.Treasury.Tx.Witness
    ( TransactionSigningFacts (..)
    , TxWitnessError (..)
    , cardanoCliSigningKeyHash
    , createWitness
    , decodeWitnessTransaction
    , parseWitnessKeyHash
    , renderGuardKeyHash
    , renderTxWitnessError
    , validateWitnessRequest
    , witnessTransactionFacts
    ) where

import Control.Monad (unless, when)
import Data.Aeson
    ( Value (..)
    , withObject
    , (.:)
    )
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as BSL
import Data.Foldable qualified as Foldable
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word8)
import Lens.Micro ((^.))

import Cardano.Crypto.DSIGN.Class
    ( SignKeyDSIGN
    , deriveVerKeyDSIGN
    , rawDeserialiseSignKeyDSIGN
    )
import Cardano.Crypto.Hash.Class (Hash, hashToBytes)
import Cardano.Ledger.Address (getNetwork)
import Cardano.Ledger.Api.Era (eraProtVerLow)
import Cardano.Ledger.Api.Tx
    ( bodyTxL
    , outputsTxBodyL
    , reqSignerHashesTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out (addrTxOutL)
import Cardano.Ledger.BaseTypes (Network (..))
import Cardano.Ledger.Binary
    ( serialize
    )
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (TopTx, TxBody, TxOut)
import Cardano.Ledger.Hashes
    ( EraIndependentTxBody
    , HASH
    , KeyHash (..)
    , extractHash
    , hashAnnotated
    )
import Cardano.Ledger.Keys
    ( DSIGN
    , KeyRole (..)
    , VKey (..)
    , WitVKey (..)
    , hashKey
    , signedDSIGN
    )
import Cardano.Node.Client.Ledger (ConwayTx)

import Amaru.Treasury.IntentJSON.Common
    ( decodeHexBytesAny
    , parseGuardKeyHash
    )
import Amaru.Treasury.Tx.AttachWitness
    ( AttachError
    , decodeUnsignedTxHex
    , renderAttachError
    )
import Amaru.Treasury.Tx.Envelope
    ( EnvelopeError
    , decodeEnvelope
    , renderEnvelopeError
    )
import Amaru.Treasury.Vault.Witness
    ( SigningSource (..)
    , VaultIdentity
    , vaultIdentityKeyHash
    , vaultIdentityNetwork
    , vaultIdentitySource
    )

-- | Facts extracted from an unsigned transaction before signing.
data TransactionSigningFacts = TransactionSigningFacts
    { tsfBodyHashHex :: !Text
    , tsfRequiredSigners :: !(Set (KeyHash Guard))
    , tsfNetwork :: !(Maybe Network)
    }
    deriving stock (Eq, Show)

-- | Failures from transaction decoding, validation, or signing.
data TxWitnessError
    = TxWitnessDecodeFailed !Text
    | TxWitnessMalformedKeyHash !Text
    | TxWitnessSelectedKeyNotRequired
        !(KeyHash Guard)
        !(Set (KeyHash Guard))
    | TxWitnessUnlistedKeyRequiresApproval
    | TxWitnessExpectedKeyMismatch !(KeyHash Guard) !(KeyHash Guard)
    | TxWitnessNetworkMismatch !Text !Network
    | TxWitnessUnsupportedSigningSource !Text
    | TxWitnessMalformedSigningKey !Text
    | TxWitnessSigningKeyHashMismatch !(KeyHash Guard) !(KeyHash Guard)
    deriving stock (Eq, Show)

data SigningKeyEnvelope = SigningKeyEnvelope
    { skeType :: !Text
    , skeCborHex :: !Text
    }

-- | Decode raw CBOR hex or a @cardano-cli@ Conway tx envelope.
decodeWitnessTransaction
    :: ByteString -> Either TxWitnessError ConwayTx
decodeWitnessTransaction raw = do
    txHex <-
        if startsWithJsonObject raw
            then mapEnvelopeError (decodeEnvelope raw)
            else Right raw
    mapAttachError (decodeUnsignedTxHex txHex)

mapEnvelopeError :: Either EnvelopeError a -> Either TxWitnessError a
mapEnvelopeError =
    either
        (Left . TxWitnessDecodeFailed . renderEnvelopeError)
        Right

mapAttachError :: Either AttachError a -> Either TxWitnessError a
mapAttachError =
    either
        (Left . TxWitnessDecodeFailed . renderAttachError)
        Right

{- | Extract transaction-body hash, required signers, and visible
output-network facts.
-}
witnessTransactionFacts :: ConwayTx -> TransactionSigningFacts
witnessTransactionFacts tx =
    let body = tx ^. bodyTxL
        conwayBody :: TxBody TopTx ConwayEra
        conwayBody = body
        bodyHash = extractHash (hashAnnotated conwayBody)
        required =
            Set.toAscList (conwayBody ^. reqSignerHashesTxBodyL)
        networks =
            Set.fromList
                [ outputNetwork txOut
                | txOut <- Foldable.toList (conwayBody ^. outputsTxBodyL)
                ]
    in  TransactionSigningFacts
            { tsfBodyHashHex = renderHash bodyHash
            , tsfRequiredSigners = Set.fromList required
            , tsfNetwork = singleNetwork networks
            }

outputNetwork :: TxOut ConwayEra -> Network
outputNetwork txOut =
    getNetwork (txOut ^. addrTxOutL)

{- | Validate that a vault identity is an acceptable signer for the
transaction facts and operator policy.
-}
validateWitnessRequest
    :: Maybe (KeyHash Guard)
    -> Bool
    -> VaultIdentity
    -> TransactionSigningFacts
    -> Either TxWitnessError ()
validateWitnessRequest expectedKeyHash allowUnlisted identity facts = do
    let selected = vaultIdentityKeyHash identity
    case expectedKeyHash of
        Nothing -> pure ()
        Just expected ->
            unless (expected == selected) $
                Left (TxWitnessExpectedKeyMismatch expected selected)
    case tsfNetwork facts of
        Nothing -> pure ()
        Just network ->
            unless (identityNetworkMatches network identity) $
                Left
                    ( TxWitnessNetworkMismatch
                        (vaultIdentityNetwork identity)
                        network
                    )
    if Set.null (tsfRequiredSigners facts)
        then
            unless (allowUnlisted || expectedKeyHash == Just selected) $
                Left TxWitnessUnlistedKeyRequiresApproval
        else
            unless (Set.member selected (tsfRequiredSigners facts)) $
                Left
                    ( TxWitnessSelectedKeyNotRequired
                        selected
                        (tsfRequiredSigners facts)
                    )

-- | Create one detached vkey witness as raw CBOR hex.
createWitness
    :: VaultIdentity -> ConwayTx -> Either TxWitnessError ByteString
createWitness identity tx =
    case vaultIdentitySource identity of
        CardanoCliSKey keyEnvelope -> do
            signKey <- decodeCardanoCliSigningKey keyEnvelope
            let body = tx ^. bodyTxL
                bodyHash = extractHash (hashAnnotated body)
                vkey = VKey (deriveVerKeyDSIGN signKey) :: VKey Witness
                derived = witnessKeyHashToGuard (hashKey vkey)
                witness =
                    WitVKey
                        vkey
                        (signedDSIGN signKey bodyHash)
            unless (derived == vaultIdentityKeyHash identity) $
                Left
                    ( TxWitnessSigningKeyHashMismatch
                        (vaultIdentityKeyHash identity)
                        derived
                    )
            Right $
                B16.encode
                    ( BSL.toStrict
                        (serialize (eraProtVerLow @ConwayEra) witness)
                    )

-- | Derive the payment key hash from an imported cardano-cli signing key.
cardanoCliSigningKeyHash
    :: Value -> Either TxWitnessError (KeyHash Guard)
cardanoCliSigningKeyHash keyEnvelope = do
    signKey <- decodeCardanoCliSigningKey keyEnvelope
    let vkey = VKey (deriveVerKeyDSIGN signKey) :: VKey Witness
    Right (witnessKeyHashToGuard (hashKey vkey))

decodeCardanoCliSigningKey
    :: Value -> Either TxWitnessError (SignKeyDSIGN DSIGN)
decodeCardanoCliSigningKey value = do
    SigningKeyEnvelope{..} <-
        case parseEither parseSigningKeyEnvelope value of
            Left err -> Left (TxWitnessMalformedSigningKey (T.pack err))
            Right envelope -> Right envelope
    when (skeType /= "PaymentSigningKeyShelley_ed25519") $
        Left
            ( TxWitnessUnsupportedSigningSource
                ("cardano-cli key envelope type " <> skeType)
            )
    keyBytes <-
        case decodeHexBytesAny skeCborHex of
            Left err -> Left (TxWitnessMalformedSigningKey (T.pack err))
            Right bytes -> Right bytes
    rawKey <- decodeShelleySigningKeyBytes keyBytes
    case rawDeserialiseSignKeyDSIGN @DSIGN rawKey of
        Nothing ->
            Left
                ( TxWitnessMalformedSigningKey
                    "could not decode Ed25519 signing key bytes"
                )
        Just key -> Right key

decodeShelleySigningKeyBytes
    :: ByteString -> Either TxWitnessError ByteString
decodeShelleySigningKeyBytes bytes
    | BS.length bytes == 34 && BS.take 2 bytes == "\x58\x20" =
        Right (BS.drop 2 bytes)
    | otherwise =
        Left
            ( TxWitnessMalformedSigningKey
                "expected a 32-byte CBOR bytestring signing key"
            )

parseSigningKeyEnvelope
    :: Value -> Parser SigningKeyEnvelope
parseSigningKeyEnvelope =
    withObject "SigningKeyEnvelope" $ \o ->
        SigningKeyEnvelope
            <$> o .: "type"
            <*> o .: "cborHex"

-- | Parse a 28-byte key hash into the Guard role used by tx bodies.
parseWitnessKeyHash :: Text -> Either TxWitnessError (KeyHash Guard)
parseWitnessKeyHash text =
    case parseGuardKeyHash text of
        Right keyHash -> Right keyHash
        Left err -> Left (TxWitnessMalformedKeyHash (T.pack err))

-- | Render a Guard key hash as lowercase hex.
renderGuardKeyHash :: KeyHash Guard -> Text
renderGuardKeyHash (KeyHash h) =
    TE.decodeUtf8 (B16.encode (hashToBytes h))

renderTxWitnessError :: TxWitnessError -> Text
renderTxWitnessError = \case
    TxWitnessDecodeFailed err ->
        "failed to decode witness transaction: " <> err
    TxWitnessMalformedKeyHash err ->
        "malformed witness key hash: " <> err
    TxWitnessSelectedKeyNotRequired selected required ->
        "selected key "
            <> renderGuardKeyHash selected
            <> " is not in transaction required signer hashes "
            <> renderKeyHashSet required
    TxWitnessUnlistedKeyRequiresApproval ->
        "transaction declares no required signer hashes; pass --expected-key-hash or --allow-unlisted-key"
    TxWitnessExpectedKeyMismatch expected selected ->
        "expected key hash "
            <> renderGuardKeyHash expected
            <> " but selected vault identity has "
            <> renderGuardKeyHash selected
    TxWitnessNetworkMismatch identityNetwork txNetwork ->
        "vault identity network `"
            <> identityNetwork
            <> "` does not match transaction network `"
            <> renderNetwork txNetwork
            <> "`"
    TxWitnessUnsupportedSigningSource source ->
        "unsupported signing source: " <> source
    TxWitnessMalformedSigningKey err ->
        "malformed signing key material: " <> err
    TxWitnessSigningKeyHashMismatch expected actual ->
        "vault identity key hash "
            <> renderGuardKeyHash expected
            <> " does not match signing key hash "
            <> renderGuardKeyHash actual

renderKeyHashSet :: Set (KeyHash Guard) -> Text
renderKeyHashSet keys =
    "["
        <> T.intercalate
            ","
            (renderGuardKeyHash <$> Set.toAscList keys)
        <> "]"

renderNetwork :: Network -> Text
renderNetwork = \case
    Mainnet -> "mainnet"
    Testnet -> "testnet"

identityNetworkMatches :: Network -> VaultIdentity -> Bool
identityNetworkMatches network identity =
    case (network, vaultIdentityNetwork identity) of
        (Mainnet, "mainnet") -> True
        (Testnet, "preprod") -> True
        (Testnet, "preview") -> True
        (Testnet, "devnet") -> True
        (Testnet, t) | "testnet:" `T.isPrefixOf` t -> True
        _ -> False

singleNetwork :: Set Network -> Maybe Network
singleNetwork networks =
    case Set.toList networks of
        [network] -> Just network
        _ -> Nothing

witnessKeyHashToGuard :: KeyHash Witness -> KeyHash Guard
witnessKeyHashToGuard (KeyHash h) = KeyHash h

renderHash :: Hash HASH EraIndependentTxBody -> Text
renderHash h =
    TE.decodeUtf8 (B16.encode (hashToBytes h))

startsWithJsonObject :: ByteString -> Bool
startsWithJsonObject raw =
    firstNonWhitespaceByte raw == Just 0x7b

firstNonWhitespaceByte :: ByteString -> Maybe Word8
firstNonWhitespaceByte =
    BS.find (not . isJsonWhitespace)

isJsonWhitespace :: Word8 -> Bool
isJsonWhitespace byte =
    byte == 0x20
        || byte == 0x09
        || byte == 0x0a
        || byte == 0x0d
