{- |
Module      : Amaru.Treasury.Config.Types
Description : Shared treasury runtime config types
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Typed configuration records shared by the YAML loader,
opt-env-conf settings, and pure resolver.
-}
module Amaru.Treasury.Config.Types
    ( ApiConfig (..)
    , ResolvedNetwork (..)
    , ResolvedTreasuryConfig (..)
    , TreasuryConfig (..)
    , TreasuryConfigOverrides (..)
    , TreasuryProfileConfig (..)
    , emptyApiConfig
    , emptyTreasuryConfigOverrides
    ) where

import Data.Aeson
    ( FromJSON (..)
    , withObject
    , (.:)
    , (.:?)
    )
import Data.Aeson.Types ((.!=))
import Data.Map.Strict (Map)
import Data.Text (Text)
import Data.Word (Word32)

-- | API-specific runtime paths from the shared YAML file.
data ApiConfig = ApiConfig
    { acManifest :: !(Maybe FilePath)
    , acBuildIdentity :: !(Maybe FilePath)
    , acStatic :: !(Maybe FilePath)
    }
    deriving stock (Eq, Show)

-- | Empty API config used when the YAML file omits the @api@ section.
emptyApiConfig :: ApiConfig
emptyApiConfig =
    ApiConfig
        { acManifest = Nothing
        , acBuildIdentity = Nothing
        , acStatic = Nothing
        }

instance FromJSON ApiConfig where
    parseJSON =
        withObject "ApiConfig" $ \o ->
            ApiConfig
                <$> o .:? "manifest"
                <*> o .:? "buildIdentity"
                <*> o .:? "static"

-- | One named treasury profile in @treasury.yaml@.
data TreasuryProfileConfig = TreasuryProfileConfig
    { tpcProfileName :: !Text
    , tpcTenantId :: !(Maybe Text)
    , tpcNetwork :: !(Maybe Text)
    , tpcNetworkMagic :: !(Maybe Word32)
    , tpcNodeSocket :: !(Maybe FilePath)
    , tpcMetadataPath :: !(Maybe FilePath)
    , tpcDefaultScope :: !(Maybe Text)
    , tpcWalletAddress :: !(Maybe Text)
    , tpcSwapOrderAddress :: !(Maybe Text)
    }
    deriving stock (Eq, Show)

instance FromJSON TreasuryProfileConfig where
    parseJSON =
        withObject "TreasuryProfileConfig" $ \o ->
            TreasuryProfileConfig
                <$> o .:? "profileName" .!= ""
                <*> o .:? "tenantId"
                <*> o .:? "network"
                <*> o .:? "networkMagic"
                <*> o .:? "nodeSocket"
                <*> o .:? "metadataPath"
                <*> o .:? "defaultScope"
                <*> o .:? "walletAddress"
                <*> o .:? "swapOrderAddress"

-- | Complete YAML runtime config file.
data TreasuryConfig = TreasuryConfig
    { tcProfiles :: !(Map Text TreasuryProfileConfig)
    , tcApi :: !ApiConfig
    }
    deriving stock (Eq, Show)

instance FromJSON TreasuryConfig where
    parseJSON =
        withObject "TreasuryConfig" $ \o ->
            TreasuryConfig
                <$> o .: "profiles"
                <*> o .:? "api" .!= emptyApiConfig

-- | Field-level values supplied by a source above the YAML profile.
data TreasuryConfigOverrides = TreasuryConfigOverrides
    { tcoConfigPath :: !(Maybe FilePath)
    , tcoProfile :: !(Maybe Text)
    , tcoNetwork :: !(Maybe Text)
    , tcoNetworkMagic :: !(Maybe Word32)
    , tcoNodeSocket :: !(Maybe FilePath)
    , tcoMetadataPath :: !(Maybe FilePath)
    , tcoDefaultScope :: !(Maybe Text)
    , tcoTenantId :: !(Maybe Text)
    , tcoWalletAddress :: !(Maybe Text)
    , tcoSwapOrderAddress :: !(Maybe Text)
    , tcoApiManifest :: !(Maybe FilePath)
    , tcoApiBuildIdentity :: !(Maybe FilePath)
    , tcoApiStatic :: !(Maybe FilePath)
    }
    deriving stock (Eq, Show)

-- | Empty override set for sources that did not supply any values.
emptyTreasuryConfigOverrides :: TreasuryConfigOverrides
emptyTreasuryConfigOverrides =
    TreasuryConfigOverrides
        { tcoConfigPath = Nothing
        , tcoProfile = Nothing
        , tcoNetwork = Nothing
        , tcoNetworkMagic = Nothing
        , tcoNodeSocket = Nothing
        , tcoMetadataPath = Nothing
        , tcoDefaultScope = Nothing
        , tcoTenantId = Nothing
        , tcoWalletAddress = Nothing
        , tcoSwapOrderAddress = Nothing
        , tcoApiManifest = Nothing
        , tcoApiBuildIdentity = Nothing
        , tcoApiStatic = Nothing
        }

-- | Network name and magic after source resolution.
data ResolvedNetwork = ResolvedNetwork
    { rnName :: !(Maybe Text)
    , rnMagic :: !Word32
    }
    deriving stock (Eq, Show)

-- | Runtime treasury config after CLI/env/profile/default precedence.
data ResolvedTreasuryConfig = ResolvedTreasuryConfig
    { rtcProfileName :: !(Maybe Text)
    , rtcNetwork :: !ResolvedNetwork
    , rtcNodeSocket :: !(Maybe FilePath)
    , rtcMetadataPath :: !(Maybe FilePath)
    , rtcDefaultScope :: !(Maybe Text)
    , rtcTenantId :: !(Maybe Text)
    , rtcWalletAddress :: !(Maybe Text)
    , rtcSwapOrderAddress :: !(Maybe Text)
    }
    deriving stock (Eq, Show)
