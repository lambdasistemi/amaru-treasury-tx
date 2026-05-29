{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Config.FileSpec
Description : Unit tests for YAML treasury config decoding
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0
-}
module Amaru.Treasury.Config.FileSpec (spec) where

import Data.ByteString (ByteString)
import Data.Either (isLeft)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldSatisfy
    )

import Amaru.Treasury.Config.File
    ( decodeTreasuryConfigYaml
    )
import Amaru.Treasury.Config.Types
    ( ApiConfig (..)
    , TreasuryConfig (..)
    , TreasuryProfileConfig (..)
    , emptyApiConfig
    )

spec :: Spec
spec = describe "Amaru.Treasury.Config.File" $ do
    it "decodes YAML profiles and the optional API section" $ do
        decodeTreasuryConfigYaml fullConfigYaml
            `shouldBe` Right
                TreasuryConfig
                    { tcProfiles =
                        Map.singleton
                            "acme"
                            TreasuryProfileConfig
                                { tpcProfileName = "acme"
                                , tpcTenantId = Just "tenant-acme"
                                , tpcNetwork = Just "preprod"
                                , tpcNetworkMagic = Nothing
                                , tpcNodeSocket =
                                    Just "/run/cardano/node.socket"
                                , tpcMetadataPath =
                                    Just "metadata-preprod.json"
                                , tpcDefaultScope =
                                    Just "core_development"
                                , tpcWalletAddress = Just "addr1wallet"
                                , tpcSwapOrderAddress =
                                    Just "addr1swap"
                                }
                    , tcApi =
                        ApiConfig
                            { acManifest = Just "recent-txs.json"
                            , acBuildIdentity =
                                Just "build-identity.json"
                            , acStatic = Just "frontend/dist"
                            , acIndexerDb = Just "indexer-db"
                            , acIndexerLagThresholdSlots = Just 42
                            , acIndexerStartSlot = Just 123
                            , acIndexerStartBlockHash =
                                Just sampleBlockHashHex
                            }
                    }

    it "defaults a missing API section to an empty API config" $ do
        fmap tcApi (decodeTreasuryConfigYaml profileOnlyYaml)
            `shouldBe` Right emptyApiConfig

    it "rejects malformed YAML" $
        decodeTreasuryConfigYaml "profiles: ["
            `shouldSatisfy` isLeft

    it "rejects config files without a profiles map" $
        decodeTreasuryConfigYaml "api:\n  manifest: recent-txs.json\n"
            `shouldSatisfy` isLeft

fullConfigYaml :: ByteString
fullConfigYaml =
    "profiles:\n\
    \  acme:\n\
    \    profileName: acme\n\
    \    tenantId: tenant-acme\n\
    \    network: preprod\n\
    \    nodeSocket: /run/cardano/node.socket\n\
    \    metadataPath: metadata-preprod.json\n\
    \    defaultScope: core_development\n\
    \    walletAddress: addr1wallet\n\
    \    swapOrderAddress: addr1swap\n\
    \api:\n\
    \  manifest: recent-txs.json\n\
    \  buildIdentity: build-identity.json\n\
    \  static: frontend/dist\n\
    \  indexerDb: indexer-db\n\
    \  indexerLagThresholdSlots: 42\n\
    \  indexerStartSlot: 123\n\
    \  indexerStartBlockHash: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n"

profileOnlyYaml :: ByteString
profileOnlyYaml =
    "profiles:\n\
    \  acme:\n\
    \    network: mainnet\n\
    \    nodeSocket: /run/cardano/node.socket\n\
    \    metadataPath: metadata-mainnet.json\n"

sampleBlockHashHex :: Text
sampleBlockHashHex =
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
