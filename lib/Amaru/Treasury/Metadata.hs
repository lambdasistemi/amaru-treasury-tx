{- |
Module      : Amaru.Treasury.Metadata
Description : Parse the journal/2026 deployment metadata
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Parses
[`pragma-org/amaru-treasury/journal/2026/metadata.json`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/metadata.json)
into a Haskell-side representation. All hex strings,
bech32 addresses, and @txid#ix@ references are kept as
'Text' here; the per-action builder modules lift them
to the ledger types they need.
-}
module Amaru.Treasury.Metadata
    ( -- * Top-level
      TreasuryMetadata (..)
    , readMetadataFile

      -- * Per-scope
    , ScopeMetadata (..)
    , ScriptRef (..)

      -- * Errors
    , MetadataError (..)
    ) where

import Control.Exception (Exception, throwIO)
import Data.Aeson
    ( FromJSON (..)
    , withObject
    , (.!=)
    , (.:)
    , (.:?)
    )
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Parser)
import Data.ByteString.Lazy qualified as BL
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)

import Amaru.Treasury.Scope (ScopeId, scopeFromText)

-- | Top-level metadata describing every configured scope.
data TreasuryMetadata = TreasuryMetadata
    { tmScopeOwners :: !Text
    -- ^ UTxO holding the scope-owners NFT (@txid#ix@ hex).
    , tmTreasuries :: !(Map ScopeId ScopeMetadata)
    -- ^ Per-scope deployment.
    }
    deriving (Eq, Show)

-- | Per-scope deployment.
data ScopeMetadata = ScopeMetadata
    { smOwner :: !(Maybe Text)
    -- ^ 28-byte keyhash hex; 'Nothing' only for the
    --     'Contingency' scope.
    , smBudget :: !(Maybe Integer)
    -- ^ Informational budget; not consumed by the CLI.
    , smAddress :: !Text
    -- ^ Bech32-encoded scope contract address.
    , smTreasury :: !ScriptRef
    , smPermissions :: !ScriptRef
    , smRegistry :: !ScriptRef
    }
    deriving (Eq, Show)

-- | Script hash + deployed-at reference UTxO.
data ScriptRef = ScriptRef
    { srHash :: !Text
    -- ^ 28-byte script hash hex.
    , srDeployedAt :: !Text
    -- ^ @txid#ix@ string of the published reference UTxO.
    }
    deriving (Eq, Show)

-- | Errors raised while loading 'TreasuryMetadata'.
newtype MetadataError
    = -- | Aeson decoding failure with the upstream message.
      MetadataDecodeError String
    deriving (Eq, Show)

instance Exception MetadataError

instance FromJSON TreasuryMetadata where
    parseJSON = withObject "TreasuryMetadata" $ \o -> do
        scopeOwners <- o .: "scope_owners"
        treasuriesRaw <- o .: "treasuries" :: Parser (Map Text ScopeMetadata)
        treasuries <- traverse parseKey (Map.toList treasuriesRaw)
        pure $
            TreasuryMetadata
                { tmScopeOwners = scopeOwners
                , tmTreasuries = Map.fromList treasuries
                }
      where
        parseKey (k, v) = case scopeFromText k of
            Right s -> pure (s, v)
            Left err -> fail err

instance FromJSON ScopeMetadata where
    parseJSON = withObject "ScopeMetadata" $ \o -> do
        owner <- o .:? "owner" .!= Nothing
        budget <- o .:? "budget"
        address <- o .: "address"
        treasury <- o .: "treasury_script"
        permissions <- o .: "permissions_script"
        registry <- o .: "registry_script"
        pure $
            ScopeMetadata
                { smOwner = owner
                , smBudget = budget
                , smAddress = address
                , smTreasury = treasury
                , smPermissions = permissions
                , smRegistry = registry
                }

instance FromJSON ScriptRef where
    parseJSON = withObject "ScriptRef" $ \o -> do
        h <- o .: "hash"
        d <- o .: "deployed_at"
        pure $ ScriptRef{srHash = h, srDeployedAt = d}

{- | Read and decode a metadata file. Raises
'MetadataError' on failure.
-}
readMetadataFile :: FilePath -> IO TreasuryMetadata
readMetadataFile path = do
    bs <- BL.readFile path
    case Aeson.eitherDecode' bs of
        Right m -> pure m
        Left err -> throwIO (MetadataDecodeError err)
