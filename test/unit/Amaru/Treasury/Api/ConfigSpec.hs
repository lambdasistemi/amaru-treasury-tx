{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Api.ConfigSpec
Description : API config profile resolution tests
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0
-}
module Amaru.Treasury.Api.ConfigSpec (spec) where

import Data.List (isInfixOf)
import Ouroboros.Network.Magic (NetworkMagic (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
    ( Expectation
    , Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    , shouldSatisfy
    )

import Amaru.Treasury.Api.Config
    ( ApiIndexerRuntimeConfig (..)
    , ApiRuntimeConfig (..)
    , parseApiArgsWithEnv
    )
import Amaru.Treasury.Cli.Common
    ( GlobalOpts (..)
    )

spec :: Spec
spec = describe "Amaru.Treasury.Api.Config" $ do
    it "resolves API startup fields from the selected profile" $
        withSystemTempDirectory "treasury-api-config" $ \tmp -> do
            let configPath = tmp </> "treasury.yaml"
            writeFile configPath treasuryYaml

            resolved <-
                parseApiArgsWithEnv
                    []
                    [ "--config"
                    , configPath
                    , "--profile"
                    , "acme"
                    ]

            resolved
                `shouldResolveApi` ApiRuntimeConfig
                    { arcHost = "0.0.0.0"
                    , arcPort = 8080
                    , arcSocket = "/profile/node.socket"
                    , arcMetadata = "metadata-profile.json"
                    , arcManifest = "manifest-profile.json"
                    , arcBuildIdentity = "build-profile.json"
                    , arcStatic = "static-profile"
                    , arcIndexer =
                        ApiIndexerRuntimeConfig
                            { aircDbPath = "indexer-profile"
                            , aircLagThresholdSlots = 60
                            , aircStartSlot = Nothing
                            }
                    , arcGlobalOpts =
                        GlobalOpts
                            { goSocketPath = Just "/profile/node.socket"
                            , goNetworkMagic =
                                NetworkMagic 764824073
                            , goNetworkName = Just "mainnet"
                            }
                    }

    it "resolves API startup fields from environment variables alone" $ do
        resolved <-
            parseApiArgsWithEnv
                [ ("AMARU_TREASURY_NODE_SOCKET", "/env/node.socket")
                , ("AMARU_TREASURY_METADATA", "metadata-env.json")
                ,
                    ( "AMARU_TREASURY_API_MANIFEST"
                    , "manifest-env.json"
                    )
                ,
                    ( "AMARU_TREASURY_API_BUILD_IDENTITY"
                    , "build-env.json"
                    )
                , ("AMARU_TREASURY_API_STATIC", "static-env")
                , ( "AMARU_TREASURY_API_INDEXER_DB"
                  , "indexer-env"
                  )
                ]
                []

        resolved
            `shouldResolveApi` ApiRuntimeConfig
                { arcHost = "0.0.0.0"
                , arcPort = 8080
                , arcSocket = "/env/node.socket"
                , arcMetadata = "metadata-env.json"
                , arcManifest = "manifest-env.json"
                , arcBuildIdentity = "build-env.json"
                , arcStatic = "static-env"
                , arcIndexer =
                    ApiIndexerRuntimeConfig
                        { aircDbPath = "indexer-env"
                        , aircLagThresholdSlots = 60
                        , aircStartSlot = Nothing
                        }
                , arcGlobalOpts =
                    GlobalOpts
                        { goSocketPath = Just "/env/node.socket"
                        , goNetworkMagic = NetworkMagic 764824073
                        , goNetworkName = Just "mainnet"
                        }
                }

    it "lets explicit API flags override profile and API YAML values" $
        withSystemTempDirectory "treasury-api-config" $ \tmp -> do
            let configPath = tmp </> "treasury.yaml"
            writeFile configPath treasuryYaml

            resolved <-
                parseApiArgsWithEnv
                    []
                    [ "--config"
                    , configPath
                    , "--profile"
                    , "acme"
                    , "--host"
                    , "127.0.0.1"
                    , "-p"
                    , "9090"
                    , "--socket"
                    , "/cli/node.socket"
                    , "--metadata"
                    , "metadata-cli.json"
                    , "--manifest"
                    , "manifest-cli.json"
                    , "--build-identity"
                    , "build-cli.json"
                    , "--static"
                    , "static-cli"
                    , "--indexer-db"
                    , "indexer-cli"
                    , "--indexer-lag-threshold-slots"
                    , "42"
                    , "--indexer-start-slot"
                    , "123"
                    ]

            resolved
                `shouldResolveApi` ApiRuntimeConfig
                    { arcHost = "127.0.0.1"
                    , arcPort = 9090
                    , arcSocket = "/cli/node.socket"
                    , arcMetadata = "metadata-cli.json"
                    , arcManifest = "manifest-cli.json"
                    , arcBuildIdentity = "build-cli.json"
                    , arcStatic = "static-cli"
                    , arcIndexer =
                        ApiIndexerRuntimeConfig
                            { aircDbPath = "indexer-cli"
                            , aircLagThresholdSlots = 42
                            , aircStartSlot = Just 123
                            }
                    , arcGlobalOpts =
                        GlobalOpts
                            { goSocketPath = Just "/cli/node.socket"
                            , goNetworkMagic =
                                NetworkMagic 764824073
                            , goNetworkName = Just "mainnet"
                            }
                    }

    it "reports missing API path diagnostics before server IO" $
        withSystemTempDirectory "treasury-api-config" $ \tmp -> do
            let configPath = tmp </> "treasury-missing-api.yaml"
            writeFile configPath missingApiYaml

            resolved <-
                parseApiArgsWithEnv
                    []
                    [ "--config"
                    , configPath
                    , "--profile"
                    , "acme"
                    ]

            resolved
                `shouldFailWith` "config: missing required field api.manifest"

    it "preserves the old flag-only startup invocation" $ do
        resolved <-
            parseApiArgsWithEnv
                []
                [ "--socket"
                , "/flag/node.socket"
                , "--metadata"
                , "metadata-flag.json"
                , "--manifest"
                , "manifest-flag.json"
                , "--build-identity"
                , "build-flag.json"
                , "--static"
                , "static-flag"
                , "--indexer-db"
                , "indexer-flag"
                ]

        resolved
            `shouldResolveApi` ApiRuntimeConfig
                { arcHost = "0.0.0.0"
                , arcPort = 8080
                , arcSocket = "/flag/node.socket"
                , arcMetadata = "metadata-flag.json"
                , arcManifest = "manifest-flag.json"
                , arcBuildIdentity = "build-flag.json"
                , arcStatic = "static-flag"
                , arcIndexer =
                    ApiIndexerRuntimeConfig
                        { aircDbPath = "indexer-flag"
                        , aircLagThresholdSlots = 60
                        , aircStartSlot = Nothing
                        }
                , arcGlobalOpts =
                    GlobalOpts
                        { goSocketPath = Just "/flag/node.socket"
                        , goNetworkMagic = NetworkMagic 764824073
                        , goNetworkName = Just "mainnet"
                        }
                }

    it "preserves CARDANO_NODE_SOCKET_PATH compatibility" $ do
        resolved <-
            parseApiArgsWithEnv
                [ ("CARDANO_NODE_SOCKET_PATH", "/legacy/node.socket")
                , ("AMARU_TREASURY_METADATA", "metadata-env.json")
                ,
                    ( "AMARU_TREASURY_API_MANIFEST"
                    , "manifest-env.json"
                    )
                ,
                    ( "AMARU_TREASURY_API_BUILD_IDENTITY"
                    , "build-env.json"
                    )
                , ("AMARU_TREASURY_API_STATIC", "static-env")
                , ( "AMARU_TREASURY_API_INDEXER_DB"
                  , "indexer-env"
                  )
                ]
                []

        arcSocket <$> resolved `shouldBe` Right "/legacy/node.socket"

    it "rejects non-mainnet profile configuration for the API" $
        withSystemTempDirectory "treasury-api-config" $ \tmp -> do
            let configPath = tmp </> "treasury-non-mainnet.yaml"
            writeFile configPath nonMainnetYaml

            resolved <-
                parseApiArgsWithEnv
                    []
                    [ "--config"
                    , configPath
                    , "--profile"
                    , "acme"
                    ]

            resolved
                `shouldFailWith` "api: expected mainnet network"

shouldResolveApi
    :: Either String ApiRuntimeConfig
    -> ApiRuntimeConfig
    -> Expectation
shouldResolveApi resolved expected =
    case resolved of
        Right runtime -> runtime `shouldBe` expected
        Left err ->
            expectationFailure ("expected parse success: " <> err)

shouldFailWith
    :: Either String ApiRuntimeConfig -> String -> Expectation
shouldFailWith resolved needle =
    case resolved of
        Left err -> err `shouldSatisfy` isInfixOf needle
        Right runtime ->
            expectationFailure
                ("expected parse failure, got: " <> show runtime)

treasuryYaml :: String
treasuryYaml =
    "profiles:\n\
    \  acme:\n\
    \    profileName: acme\n\
    \    network: mainnet\n\
    \    nodeSocket: /profile/node.socket\n\
    \    metadataPath: metadata-profile.json\n\
    \api:\n\
    \  manifest: manifest-profile.json\n\
    \  buildIdentity: build-profile.json\n\
    \  static: static-profile\n\
    \  indexerDb: indexer-profile\n"

missingApiYaml :: String
missingApiYaml =
    "profiles:\n\
    \  acme:\n\
    \    profileName: acme\n\
    \    network: mainnet\n\
    \    nodeSocket: /profile/node.socket\n\
    \    metadataPath: metadata-profile.json\n"

nonMainnetYaml :: String
nonMainnetYaml =
    "profiles:\n\
    \  acme:\n\
    \    profileName: acme\n\
    \    network: preprod\n\
    \    nodeSocket: /profile/node.socket\n\
    \    metadataPath: metadata-profile.json\n\
    \api:\n\
    \  manifest: manifest-profile.json\n\
    \  buildIdentity: build-profile.json\n\
    \  static: static-profile\n\
    \  indexerDb: indexer-profile\n"
