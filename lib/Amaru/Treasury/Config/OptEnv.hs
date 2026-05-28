{- |
Module      : Amaru.Treasury.Config.OptEnv
Description : opt-env-conf settings for treasury runtime config
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Shared opt-env-conf settings for CLI/env/config source
parsing. This module intentionally targets opt-env-conf
0.8.0.0, which is the version available at the repository
Cabal index state.
-}
module Amaru.Treasury.Config.OptEnv
    ( treasuryConfigOverridesParser
    , treasuryConfigWithYamlParser
    ) where

import Data.Text (Text)
import Data.Word (Word32, Word64)
import OptEnvConf
    ( Parser
    , auto
    , conf
    , env
    , filePathSetting
    , help
    , long
    , metavar
    , option
    , optional
    , reader
    , setting
    , strOption
    , subConfig
    , withYamlConfig
    )

import Amaru.Treasury.Config.Types
    ( TreasuryConfigOverrides (..)
    )

-- | Shared settings for all treasury config source values.
treasuryConfigOverridesParser :: Parser TreasuryConfigOverrides
treasuryConfigOverridesParser =
    TreasuryConfigOverrides
        <$> optional configPathSetting
        <*> optional profileSetting
        <*> optional networkSetting
        <*> optional networkMagicSetting
        <*> optional nodeSocketSetting
        <*> optional metadataPathSetting
        <*> optional defaultScopeSetting
        <*> optional tenantIdSetting
        <*> optional walletAddressSetting
        <*> optional swapOrderAddressSetting
        <*> optional (subConfig "api" apiManifestSetting)
        <*> optional (subConfig "api" apiBuildIdentitySetting)
        <*> optional (subConfig "api" apiStaticSetting)
        <*> optional (subConfig "api" apiIndexerDbSetting)
        <*> optional (subConfig "api" apiIndexerLagThresholdSlotsSetting)
        <*> optional (subConfig "api" apiIndexerStartSlotSetting)
        <*> optional (subConfig "api" apiIndexerStartBlockHashSetting)

-- | Settings parser wrapped in YAML config loading.
treasuryConfigWithYamlParser :: Parser TreasuryConfigOverrides
treasuryConfigWithYamlParser =
    withYamlConfig
        (optional configPathFileSetting)
        treasuryConfigOverridesParser
  where
    configPathFileSetting =
        filePathSetting
            [ option
            , long "config"
            , env "AMARU_TREASURY_CONFIG"
            , conf "config"
            , metavar "PATH"
            , help "Path to treasury YAML config"
            ]

configPathSetting :: Parser FilePath
configPathSetting =
    strOption
        [ long "config"
        , env "AMARU_TREASURY_CONFIG"
        , conf "config"
        , metavar "PATH"
        , help "Path to treasury YAML config"
        ]

profileSetting :: Parser Text
profileSetting =
    strOption
        [ long "profile"
        , env "AMARU_TREASURY_PROFILE"
        , conf "profile"
        , metavar "NAME"
        , help "Treasury profile name"
        ]

networkSetting :: Parser Text
networkSetting =
    strOption
        [ long "network"
        , env "AMARU_TREASURY_NETWORK"
        , conf "network"
        , metavar "NAME"
        , help "mainnet | preprod | preview | devnet"
        ]

networkMagicSetting :: Parser Word32
networkMagicSetting =
    setting
        [ option
        , reader auto
        , long "network-magic"
        , env "AMARU_TREASURY_NETWORK_MAGIC"
        , conf "networkMagic"
        , metavar "WORD32"
        , help "Cardano network magic"
        ]

nodeSocketSetting :: Parser FilePath
nodeSocketSetting =
    strOption
        [ long "node-socket"
        , env "AMARU_TREASURY_NODE_SOCKET"
        , env "CARDANO_NODE_SOCKET_PATH"
        , conf "nodeSocket"
        , metavar "PATH"
        , help "cardano-node N2C socket"
        ]

metadataPathSetting :: Parser FilePath
metadataPathSetting =
    strOption
        [ long "metadata"
        , env "AMARU_TREASURY_METADATA"
        , conf "metadataPath"
        , metavar "PATH"
        , help "Treasury metadata path"
        ]

defaultScopeSetting :: Parser Text
defaultScopeSetting =
    strOption
        [ long "default-scope"
        , env "AMARU_TREASURY_DEFAULT_SCOPE"
        , conf "defaultScope"
        , metavar "SCOPE"
        , help "Default treasury scope"
        ]

tenantIdSetting :: Parser Text
tenantIdSetting =
    strOption
        [ long "tenant-id"
        , env "AMARU_TREASURY_TENANT_ID"
        , conf "tenantId"
        , metavar "TENANT"
        , help "Tenant identifier reserved for indexer slices"
        ]

walletAddressSetting :: Parser Text
walletAddressSetting =
    strOption
        [ long "wallet-address"
        , env "AMARU_TREASURY_WALLET_ADDRESS"
        , conf "walletAddress"
        , metavar "ADDRESS"
        , help "Operator wallet address"
        ]

swapOrderAddressSetting :: Parser Text
swapOrderAddressSetting =
    strOption
        [ long "swap-order-address"
        , env "AMARU_TREASURY_SWAP_ORDER_ADDRESS"
        , conf "swapOrderAddress"
        , metavar "ADDRESS"
        , help "Sundae swap-order script address"
        ]

apiManifestSetting :: Parser FilePath
apiManifestSetting =
    strOption
        [ long "api-manifest"
        , env "AMARU_TREASURY_API_MANIFEST"
        , conf "manifest"
        , metavar "PATH"
        , help "API recent transaction manifest path"
        ]

apiBuildIdentitySetting :: Parser FilePath
apiBuildIdentitySetting =
    strOption
        [ long "api-build-identity"
        , env "AMARU_TREASURY_API_BUILD_IDENTITY"
        , conf "buildIdentity"
        , metavar "PATH"
        , help "API build identity JSON path"
        ]

apiStaticSetting :: Parser FilePath
apiStaticSetting =
    strOption
        [ long "api-static"
        , env "AMARU_TREASURY_API_STATIC"
        , conf "static"
        , metavar "PATH"
        , help "API static asset directory"
        ]

apiIndexerDbSetting :: Parser FilePath
apiIndexerDbSetting =
    strOption
        [ long "api-indexer-db"
        , env "AMARU_TREASURY_API_INDEXER_DB"
        , conf "indexerDb"
        , metavar "PATH"
        , help "API embedded indexer RocksDB directory"
        ]

apiIndexerLagThresholdSlotsSetting :: Parser Word64
apiIndexerLagThresholdSlotsSetting =
    setting
        [ option
        , reader auto
        , long "api-indexer-lag-threshold-slots"
        , env "AMARU_TREASURY_API_INDEXER_LAG_THRESHOLD_SLOTS"
        , conf "indexerLagThresholdSlots"
        , metavar "SLOTS"
        , help "API embedded indexer lag threshold"
        ]

apiIndexerStartSlotSetting :: Parser Word64
apiIndexerStartSlotSetting =
    setting
        [ option
        , reader auto
        , long "api-indexer-start-slot"
        , env "AMARU_TREASURY_API_INDEXER_START_SLOT"
        , conf "indexerStartSlot"
        , metavar "SLOT"
        , help "API embedded indexer cold-boot start slot"
        ]

apiIndexerStartBlockHashSetting :: Parser Text
apiIndexerStartBlockHashSetting =
    strOption
        [ long "api-indexer-start-block-hash"
        , env "AMARU_TREASURY_API_INDEXER_START_BLOCK_HASH"
        , conf "indexerStartBlockHash"
        , metavar "HASH"
        , help "API embedded indexer cold-boot start block hash"
        ]
