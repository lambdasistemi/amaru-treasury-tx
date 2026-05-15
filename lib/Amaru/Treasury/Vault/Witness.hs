{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

{- |
Module      : Amaru.Treasury.Vault.Witness
Description : Decrypted witness vault schema
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

This module parses and encodes the JSON payload produced by the vault
boundary. Encryption is intentionally outside this module; the values
handled here are the in-memory cleartext schema.
-}
module Amaru.Treasury.Vault.Witness
    ( SigningSource (..)
    , VaultError (..)
    , VaultIdentity
    , VaultIdentitySpec (..)
    , WitnessVault
    , decodeWitnessVault
    , encodeWitnessVault
    , renderVaultError
    , resolveVaultIdentity
    , vaultIdentityKeyHash
    , vaultIdentityKeyHashText
    , vaultIdentityLabel
    , vaultIdentityNetwork
    , vaultIdentitySource
    ) where

import Control.Monad (foldM)
import Data.Aeson
    ( FromJSON (..)
    , Value
    , eitherDecodeStrict'
    , encode
    , object
    , withObject
    , (.:)
    , (.:?)
    , (.=)
    )
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BSL
import Data.Foldable (toList)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes)
import Data.Text (Text)
import Data.Text qualified as T

import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Ledger.Hashes (KeyHash (..))
import Cardano.Ledger.Keys (KeyRole (..))
import Data.ByteString.Base16 qualified as B16
import Data.Text.Encoding qualified as TE

import Amaru.Treasury.IntentJSON.Common (parseGuardKeyHash)

-- | A supported signing-material source in a decrypted vault.
newtype SigningSource
    = CardanoCliSKey Value
    deriving stock (Eq, Show)

-- | One selectable vault identity.
data VaultIdentity = VaultIdentity
    { vaultIdentityLabel :: !Text
    , vaultIdentityNetwork :: !Text
    , vaultIdentityKeyHash :: !(KeyHash Guard)
    , vaultIdentitySource :: !SigningSource
    }
    deriving stock (Eq, Show)

-- | Input for encoding a v1 witness vault cleartext payload.
data VaultIdentitySpec = VaultIdentitySpec
    { visLabel :: !Text
    , visNetwork :: !Text
    , visKeyHash :: !(KeyHash Guard)
    , visDescription :: !(Maybe Text)
    , visSource :: !SigningSource
    }
    deriving stock (Eq, Show)

-- | Parsed vault indexed by identity label.
newtype WitnessVault = WitnessVault
    { unWitnessVault :: Map Text VaultIdentity
    }
    deriving stock (Eq, Show)

{- | Vault-schema failures. These errors deliberately avoid carrying
secret-bearing values.
-}
data VaultError
    = VaultMalformedJson !Text
    | VaultUnsupportedVersion !Int
    | VaultMissingIdentity !Text ![Text]
    | VaultLabelMismatch !Text !Text
    | VaultMalformedKeyHash !Text
    | VaultDuplicateKeyHash !Text !(NonEmpty Text)
    | VaultUnsupportedSource !Text
    deriving stock (Eq, Show)

newtype VaultDocument = VaultDocument RawVault

data RawVault = RawVault
    { rvVersion :: !Int
    , rvIdentities :: !(Map Text RawIdentity)
    }

data RawIdentity = RawIdentity
    { riLabel :: !Text
    , riNetwork :: !Text
    , riKeyHash :: !Text
    , riSource :: !RawSource
    }

data RawSource = RawSource
    { rsKind :: !Text
    , rsKeyEnvelope :: !(Maybe Value)
    }

instance FromJSON VaultDocument where
    parseJSON =
        withObject "WitnessVaultDocument" $ \o ->
            VaultDocument <$> o .: "amaruTreasuryWitnessVault"

instance FromJSON RawVault where
    parseJSON =
        withObject "WitnessVault" $ \o ->
            RawVault
                <$> o .: "version"
                <*> o .: "identities"

instance FromJSON RawIdentity where
    parseJSON =
        withObject "VaultIdentity" $ \o ->
            RawIdentity
                <$> o .: "label"
                <*> o .: "network"
                <*> o .: "keyHash"
                <*> o .: "source"

instance FromJSON RawSource where
    parseJSON =
        withObject "SigningSource" $ \o ->
            RawSource
                <$> o .: "kind"
                <*> o .:? "keyEnvelope"

-- | Parse a decrypted v1 witness vault payload.
decodeWitnessVault :: ByteString -> Either VaultError WitnessVault
decodeWitnessVault raw = do
    VaultDocument RawVault{..} <-
        case eitherDecodeStrict' raw of
            Left err -> Left (VaultMalformedJson (T.pack err))
            Right doc -> Right doc
    if rvVersion == 1
        then pure ()
        else Left (VaultUnsupportedVersion rvVersion)
    identities <-
        traverse
            (uncurry validateIdentity)
            (Map.toList rvIdentities)
    checkDuplicateKeyHashes identities
    pure (WitnessVault (Map.fromList identities))

-- | Encode a v1 witness vault cleartext payload.
encodeWitnessVault :: NonEmpty VaultIdentitySpec -> ByteString
encodeWitnessVault identities =
    BSL.toStrict $
        encode $
            object
                [ "amaruTreasuryWitnessVault"
                    .= object
                        [ "version" .= (1 :: Int)
                        , "identities" .= identityMap identities
                        ]
                ]

validateIdentity
    :: Text -> RawIdentity -> Either VaultError (Text, VaultIdentity)
validateIdentity mapLabel raw = do
    let RawIdentity
            { riLabel
            , riNetwork
            , riKeyHash
            , riSource
            } = raw
    if mapLabel == riLabel
        then pure ()
        else Left (VaultLabelMismatch mapLabel riLabel)
    keyHash <-
        case parseGuardKeyHash riKeyHash of
            Right parsed -> Right parsed
            Left _ -> Left (VaultMalformedKeyHash riLabel)
    source <- validateSource riLabel riSource
    Right
        ( riLabel
        , VaultIdentity
            { vaultIdentityLabel = riLabel
            , vaultIdentityNetwork = T.toLower riNetwork
            , vaultIdentityKeyHash = keyHash
            , vaultIdentitySource = source
            }
        )

identityMap :: NonEmpty VaultIdentitySpec -> Map Text Value
identityMap =
    Map.fromList
        . fmap
            ( \identity ->
                ( visLabel identity
                , identityValue identity
                )
            )
        . toList

identityValue :: VaultIdentitySpec -> Value
identityValue VaultIdentitySpec{..} =
    object $
        catMaybes
            [ Just ("label" .= visLabel)
            , Just ("network" .= visNetwork)
            , Just ("keyHash" .= renderGuardKeyHash visKeyHash)
            , ("description" .=) <$> visDescription
            , Just ("source" .= sourceValue visSource)
            ]

sourceValue :: SigningSource -> Value
sourceValue = \case
    CardanoCliSKey keyEnvelope ->
        object
            [ "kind" .= ("cardano-cli-skey" :: Text)
            , "keyEnvelope" .= keyEnvelope
            ]

validateSource :: Text -> RawSource -> Either VaultError SigningSource
validateSource label RawSource{..} =
    case rsKind of
        "cardano-cli-skey" ->
            case rsKeyEnvelope of
                Just value -> Right (CardanoCliSKey value)
                Nothing -> Left (VaultUnsupportedSource label)
        other -> Left (VaultUnsupportedSource other)

checkDuplicateKeyHashes
    :: [(Text, VaultIdentity)] -> Either VaultError ()
checkDuplicateKeyHashes identities = do
    groups <-
        foldM
            addIdentity
            Map.empty
            identities
    case [ (keyHash, labels)
         | (keyHash, labels@(_ : _ : _)) <- Map.toList groups
         ] of
        [] -> Right ()
        (keyHash, first : second : rest) : _ ->
            Left (VaultDuplicateKeyHash keyHash (first :| (second : rest)))
        (_, [_]) : _ -> Right ()
        (_, []) : _ -> Right ()
  where
    addIdentity groups (label, identity) =
        Right $
            Map.insertWith
                (<>)
                (vaultIdentityKeyHashText identity)
                [label]
                groups

-- | Resolve a vault identity by label or by 28-byte key hash hex.
resolveVaultIdentity
    :: Text -> WitnessVault -> Either VaultError VaultIdentity
resolveVaultIdentity selector (WitnessVault identities) =
    case Map.lookup selector identities of
        Just identity -> Right identity
        Nothing ->
            case [ identity
                 | identity <- Map.elems identities
                 , vaultIdentityKeyHashText identity == T.toLower selector
                 ] of
                [identity] -> Right identity
                _ ->
                    Left
                        ( VaultMissingIdentity
                            selector
                            (Map.keys identities)
                        )

-- | Render a vault identity key hash as lowercase hex.
vaultIdentityKeyHashText :: VaultIdentity -> Text
vaultIdentityKeyHashText =
    renderGuardKeyHash . vaultIdentityKeyHash

renderGuardKeyHash :: KeyHash Guard -> Text
renderGuardKeyHash (KeyHash h) =
    TE.decodeUtf8 (B16.encode (hashToBytes h))

-- | Render a redacted operator diagnostic for a vault error.
renderVaultError :: VaultError -> Text
renderVaultError = \case
    VaultMalformedJson err ->
        "malformed witness vault JSON: " <> err
    VaultUnsupportedVersion version ->
        "unsupported witness vault version: " <> T.pack (show version)
    VaultMissingIdentity selector labels ->
        "missing witness vault identity `"
            <> selector
            <> "`; available identities: "
            <> T.intercalate ", " labels
    VaultLabelMismatch expected actual ->
        "witness vault identity label mismatch: map key `"
            <> expected
            <> "` contains label `"
            <> actual
            <> "`"
    VaultMalformedKeyHash label ->
        "witness vault identity `"
            <> label
            <> "` has a malformed key hash"
    VaultDuplicateKeyHash keyHash (first :| rest) ->
        "witness vault key hash "
            <> keyHash
            <> " is used by multiple identities: "
            <> T.intercalate ", " (first : rest)
    VaultUnsupportedSource kind ->
        "unsupported witness vault source: " <> kind
