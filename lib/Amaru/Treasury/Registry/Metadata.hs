{- |
Module      : Amaru.Treasury.Registry.Metadata
Description : Untrusted upstream registry metadata
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Parser for a local `journal/2026/metadata.json` snapshot. Values
parsed here are hints only; `Amaru.Treasury.Registry.Verify` checks
each consumed field against an on-chain or build-time anchor.
-}
module Amaru.Treasury.Registry.Metadata
    ( -- * JSON model
      UpstreamMetadata (..)
    , TreasuryEntry (..)
    , ScriptDeployment (..)
    , TxInRef (..)

      -- * Reading
    , readUpstreamMetadataFile
    , decodeUpstreamMetadata

      -- * Errors
    , RegistryWalkError (..)
    ) where

import Control.Exception (IOException, try)
import Data.Aeson
    ( FromJSON (..)
    , eitherDecodeStrict'
    , withObject
    , (.!=)
    , (.:)
    , (.:?)
    )
import Data.Aeson.Types (Parser)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T

import Amaru.Treasury.Scope (ScopeId, scopeFromText)

-- | Top-level upstream metadata. This is not trusted.
data UpstreamMetadata = UpstreamMetadata
    { umScopeOwners :: !TxInRef
    , umTreasuries :: !(Map ScopeId TreasuryEntry)
    }
    deriving (Eq, Show)

-- | Per-scope metadata entry.
data TreasuryEntry = TreasuryEntry
    { teOwner :: !(Maybe Text)
    , teAddress :: !Text
    , teTreasuryScript :: !ScriptDeployment
    , tePermissionsScript :: !ScriptDeployment
    , teRegistryScript :: !ScriptDeployment
    }
    deriving (Eq, Show)

-- | Script hash plus the reference UTxO that should carry it.
data ScriptDeployment = ScriptDeployment
    { sdHash :: !Text
    , sdDeployedAt :: !TxInRef
    }
    deriving (Eq, Show)

-- | Upstream `txid#index` reference.
newtype TxInRef = TxInRef {unTxInRef :: Text}
    deriving (Eq, Ord, Show)

-- | Read and decode a local metadata snapshot.
readUpstreamMetadataFile
    :: FilePath
    -> IO (Either RegistryWalkError UpstreamMetadata)
readUpstreamMetadataFile path = do
    bytes <- try (BS.readFile path) :: IO (Either IOException ByteString)
    pure $ case bytes of
        Left err ->
            Left (MetadataReadError path (T.pack (show err)))
        Right bs -> decodeUpstreamMetadata bs

-- | Decode metadata bytes without assigning trust to the result.
decodeUpstreamMetadata
    :: ByteString
    -> Either RegistryWalkError UpstreamMetadata
decodeUpstreamMetadata =
    either (Left . MetadataParse) Right . eitherDecodeStrict'

-- | Typed errors raised by metadata loading and registry verification.
data RegistryWalkError
    = MetadataReadError !FilePath !Text
    | MetadataParse !String
    | AnchorMismatch !Text !(Maybe ScopeId) !Text !Text
    | AnchorSpent !Text !(Maybe ScopeId) !TxInRef
    | AnchorAmbiguous !Text !(Maybe ScopeId) ![Text]
    | ChainQueryError !Text
    deriving (Eq, Show)

instance FromJSON UpstreamMetadata where
    parseJSON = withObject "UpstreamMetadata" $ \o -> do
        scopeOwners <- o .: "scope_owners"
        treasuriesRaw <- o .: "treasuries" :: Parser (Map Text TreasuryEntry)
        treasuries <- traverse parseScopeKey (Map.toList treasuriesRaw)
        pure
            UpstreamMetadata
                { umScopeOwners = scopeOwners
                , umTreasuries = Map.fromList treasuries
                }
      where
        parseScopeKey (k, v) =
            case scopeFromText k of
                Right s -> pure (s, v)
                Left err -> fail err

instance FromJSON TreasuryEntry where
    parseJSON = withObject "TreasuryEntry" $ \o ->
        TreasuryEntry
            <$> o .:? "owner" .!= Nothing
            <*> o .: "address"
            <*> o .: "treasury_script"
            <*> o .: "permissions_script"
            <*> o .: "registry_script"

instance FromJSON ScriptDeployment where
    parseJSON = withObject "ScriptDeployment" $ \o ->
        ScriptDeployment
            <$> o .: "hash"
            <*> o .: "deployed_at"

instance FromJSON TxInRef where
    parseJSON = fmap TxInRef . parseJSON
