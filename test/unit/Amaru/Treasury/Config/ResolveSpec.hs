{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Config.ResolveSpec
Description : Unit tests for treasury config precedence resolution
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0
-}
module Amaru.Treasury.Config.ResolveSpec (spec) where

import Data.Map.Strict qualified as Map
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldSatisfy
    )

import Amaru.Treasury.Config.Resolve
    ( RequiredField (..)
    , ResolveError (..)
    , ResolveInput (..)
    , envTreasuryConfigOverrides
    , resolveTreasuryConfig
    )
import Amaru.Treasury.Config.Types
    ( ResolvedNetwork (..)
    , ResolvedTreasuryConfig (..)
    , TreasuryConfig (..)
    , TreasuryConfigOverrides (..)
    , TreasuryProfileConfig (..)
    , emptyApiConfig
    , emptyTreasuryConfigOverrides
    )

spec :: Spec
spec = describe "Amaru.Treasury.Config.Resolve" $ do
    it "resolves required fields from the selected config profile" $
        resolveTreasuryConfig
            defaultResolveInput
                { riCli =
                    emptyTreasuryConfigOverrides
                        { tcoProfile = Just "acme"
                        }
                , riConfig = Just acmeConfig
                }
            `shouldBe` Right
                ResolvedTreasuryConfig
                    { rtcProfileName = Just "acme"
                    , rtcNetwork =
                        ResolvedNetwork
                            { rnName = Just "preprod"
                            , rnMagic = 1
                            }
                    , rtcNodeSocket = Just "/config/node.socket"
                    , rtcMetadataPath = Just "metadata-config.json"
                    , rtcDefaultScope = Just "core_development"
                    , rtcTenantId = Just "tenant-config"
                    , rtcWalletAddress = Just "addr1wallet-config"
                    , rtcSwapOrderAddress = Just "addr1swap-config"
                    }

    it "resolves required fields from environment variables alone" $
        resolveTreasuryConfig
            defaultResolveInput
                { riEnv =
                    envTreasuryConfigOverrides
                        [ ("AMARU_TREASURY_NETWORK", "devnet")
                        ,
                            ( "AMARU_TREASURY_NODE_SOCKET"
                            , "/env/node.socket"
                            )
                        , ("AMARU_TREASURY_METADATA", "metadata-env.json")
                        ,
                            ( "AMARU_TREASURY_DEFAULT_SCOPE"
                            , "middleware"
                            )
                        ]
                }
            `shouldBe` Right
                ResolvedTreasuryConfig
                    { rtcProfileName = Nothing
                    , rtcNetwork =
                        ResolvedNetwork
                            { rnName = Just "devnet"
                            , rnMagic = 42
                            }
                    , rtcNodeSocket = Just "/env/node.socket"
                    , rtcMetadataPath = Just "metadata-env.json"
                    , rtcDefaultScope = Just "middleware"
                    , rtcTenantId = Nothing
                    , rtcWalletAddress = Nothing
                    , rtcSwapOrderAddress = Nothing
                    }

    it "lets CLI values override config profile values" $
        resolveTreasuryConfig
            defaultResolveInput
                { riCli =
                    emptyTreasuryConfigOverrides
                        { tcoProfile = Just "acme"
                        , tcoNetwork = Just "preview"
                        , tcoNodeSocket = Just "/cli/node.socket"
                        , tcoMetadataPath = Just "metadata-cli.json"
                        }
                , riConfig = Just acmeConfig
                }
            `shouldBe` Right
                ResolvedTreasuryConfig
                    { rtcProfileName = Just "acme"
                    , rtcNetwork =
                        ResolvedNetwork
                            { rnName = Just "preview"
                            , rnMagic = 2
                            }
                    , rtcNodeSocket = Just "/cli/node.socket"
                    , rtcMetadataPath = Just "metadata-cli.json"
                    , rtcDefaultScope = Just "core_development"
                    , rtcTenantId = Just "tenant-config"
                    , rtcWalletAddress = Just "addr1wallet-config"
                    , rtcSwapOrderAddress = Just "addr1swap-config"
                    }

    it "accepts CARDANO_NODE_SOCKET_PATH as a socket env alias" $
        tcoNodeSocket
            ( envTreasuryConfigOverrides
                [ ("CARDANO_NODE_SOCKET_PATH", "/legacy/node.socket")
                ]
            )
            `shouldBe` Just "/legacy/node.socket"

    it "prefers AMARU_TREASURY_NODE_SOCKET over the legacy alias" $
        tcoNodeSocket
            ( envTreasuryConfigOverrides
                [ ("CARDANO_NODE_SOCKET_PATH", "/legacy/node.socket")
                ,
                    ( "AMARU_TREASURY_NODE_SOCKET"
                    , "/namespaced/node.socket"
                    )
                ]
            )
            `shouldBe` Just "/namespaced/node.socket"

    it "reports an unknown selected profile" $
        resolveTreasuryConfig
            defaultResolveInput
                { riCli =
                    emptyTreasuryConfigOverrides
                        { tcoProfile = Just "missing"
                        }
                , riConfig = Just acmeConfig
                }
            `shouldBe` Left (UnknownProfile "missing")

    it "reports missing required fields after source precedence" $
        resolveTreasuryConfig
            defaultResolveInput
                { riCli =
                    emptyTreasuryConfigOverrides
                        { tcoProfile = Just "incomplete"
                        }
                , riConfig = Just incompleteConfig
                }
            `shouldSatisfy` (== Left (MissingRequiredField "nodeSocket"))

defaultResolveInput :: ResolveInput
defaultResolveInput =
    ResolveInput
        { riCli = emptyTreasuryConfigOverrides
        , riEnv = emptyTreasuryConfigOverrides
        , riConfig = Nothing
        , riRequiredFields = [RequireNodeSocket, RequireMetadataPath]
        }

acmeConfig :: TreasuryConfig
acmeConfig =
    TreasuryConfig
        { tcProfiles =
            Map.singleton
                "acme"
                TreasuryProfileConfig
                    { tpcProfileName = "acme"
                    , tpcTenantId = Just "tenant-config"
                    , tpcNetwork = Just "preprod"
                    , tpcNetworkMagic = Nothing
                    , tpcNodeSocket = Just "/config/node.socket"
                    , tpcMetadataPath = Just "metadata-config.json"
                    , tpcDefaultScope = Just "core_development"
                    , tpcWalletAddress = Just "addr1wallet-config"
                    , tpcSwapOrderAddress = Just "addr1swap-config"
                    }
        , tcApi = emptyApiConfig
        }

incompleteConfig :: TreasuryConfig
incompleteConfig =
    TreasuryConfig
        { tcProfiles =
            Map.singleton
                "incomplete"
                TreasuryProfileConfig
                    { tpcProfileName = "incomplete"
                    , tpcTenantId = Nothing
                    , tpcNetwork = Just "mainnet"
                    , tpcNetworkMagic = Nothing
                    , tpcNodeSocket = Nothing
                    , tpcMetadataPath = Nothing
                    , tpcDefaultScope = Nothing
                    , tpcWalletAddress = Nothing
                    , tpcSwapOrderAddress = Nothing
                    }
        , tcApi = emptyApiConfig
        }
