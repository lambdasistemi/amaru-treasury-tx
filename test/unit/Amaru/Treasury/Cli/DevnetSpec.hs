{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Cli.DevnetSpec
Description : CLI parser tests for DevNet operator commands
License     : Apache-2.0
-}
module Amaru.Treasury.Cli.DevnetSpec (spec) where

import Options.Applicative
    ( ParserResult (..)
    , defaultPrefs
    , execParserPure
    )
import Ouroboros.Network.Magic (NetworkMagic (..))
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    )

import Amaru.Treasury.Cli
    ( Cmd (..)
    , opts
    )
import Amaru.Treasury.Cli.Common
    ( GlobalOpts (..)
    )
import Amaru.Treasury.Cli.Devnet
    ( DevnetDisburseSubmitOpts (..)
    , DevnetGovernanceWithdrawalInitOpts (..)
    , DevnetRegistryInitOpts (..)
    , DevnetStakeRewardInitOpts (..)
    , registryInitCommandLines
    , requireDevnetDisburseSubmitNetwork
    , requireDevnetGovernanceWithdrawalInitNetwork
    , requireDevnetRegistryInitNetwork
    , requireDevnetStakeRewardInitNetwork
    )

spec :: Spec
spec = describe "devnet commands" $ do
    describe "registry-init command" $ do
        it "parses the nested devnet registry-init command" $
            case parseCmd registryInitArgs of
                Right (g, CmdDevnetRegistryInit o) -> do
                    goSocketPath g `shouldBe` Just "node.socket"
                    goNetworkMagic g `shouldBe` NetworkMagic 42
                    goNetworkName g `shouldBe` Just "devnet"
                    o
                        `shouldBe` DevnetRegistryInitOpts
                            { drioFundingAddress = fundingAddress
                            , drioSigningKeyFile = "payment.skey"
                            , drioRunDir = "runs/devnet/registry-init"
                            }
                Right _ ->
                    expectationFailure "expected devnet registry-init command"
                Left e -> expectationFailure e

        it "rejects non-DevNet networks before submission" $
            requireDevnetRegistryInitNetwork
                GlobalOpts
                    { goSocketPath = Just "node.socket"
                    , goNetworkMagic = NetworkMagic 764_824_073
                    , goNetworkName = Just "mainnet"
                    }
                `shouldBe` Left
                    "registry-init: --network must be devnet"

        it "renders command success lines with contract field names" $
            registryInitCommandLines
                42
                "runs/devnet/registry-init"
                "seed"
                "registry"
                "refs"
                `shouldBe` [ "registry-init: run-dir runs/devnet/registry-init"
                           , "registry-init: network devnet magic 42"
                           , "registry-init: phase registry-init passed"
                           , "registry-init: seed-split-tx-id seed"
                           , "registry-init: registry-mint-tx-id registry"
                           , "registry-init: reference-scripts-tx-id refs"
                           , "registry-init: summary runs/devnet/registry-init/registry-init/summary.json"
                           , "registry-init: registry runs/devnet/registry-init/registry-init/registry.json"
                           ]

    describe "stake-reward-init command" $ do
        it "parses the nested devnet stake-reward-init command" $
            case parseCmd stakeRewardInitArgs of
                Right (g, CmdDevnetStakeRewardInit o) -> do
                    goSocketPath g `shouldBe` Just "node.socket"
                    goNetworkMagic g `shouldBe` NetworkMagic 42
                    goNetworkName g `shouldBe` Just "devnet"
                    o
                        `shouldBe` DevnetStakeRewardInitOpts
                            { dsrioRegistryFile =
                                "runs/devnet/stake/registry-init/registry.json"
                            , dsrioFundingAddress = fundingAddress
                            , dsrioSigningKeyFile = "payment.skey"
                            , dsrioRunDir = "runs/devnet/stake"
                            }
                Right _ ->
                    expectationFailure "expected devnet stake-reward-init command"
                Left e -> expectationFailure e

        it "rejects non-DevNet networks before stake-reward effects" $
            requireDevnetStakeRewardInitNetwork
                GlobalOpts
                    { goSocketPath = Just "node.socket"
                    , goNetworkMagic = NetworkMagic 1
                    , goNetworkName = Just "preprod"
                    }
                `shouldBe` Left
                    "stake-reward-init: --network must be devnet"

    describe "governance-withdrawal-init command" $ do
        it "parses the nested devnet governance-withdrawal-init command" $
            case parseCmd governanceWithdrawalInitArgs of
                Right (g, CmdDevnetGovernanceWithdrawalInit o) -> do
                    goSocketPath g `shouldBe` Just "node.socket"
                    goNetworkMagic g `shouldBe` NetworkMagic 42
                    goNetworkName g `shouldBe` Just "devnet"
                    o
                        `shouldBe` DevnetGovernanceWithdrawalInitOpts
                            { dgwioRegistryFile =
                                "runs/devnet/registry-init/registry.json"
                            , dgwioStakeRewardFile =
                                "runs/devnet/stake-reward-init/accounts.json"
                            , dgwioFundingAddress = fundingAddress
                            , dgwioSigningKeyFile = "payment.skey"
                            , dgwioRunDir = "runs/devnet"
                            , dgwioAmountLovelace = 2_000_000
                            , dgwioRewardTimeoutSeconds = 180
                            }
                Right _ ->
                    expectationFailure
                        "expected devnet governance-withdrawal-init command"
                Left e -> expectationFailure e

        it "rejects non-DevNet networks before governance inputs are read" $
            requireDevnetGovernanceWithdrawalInitNetwork
                GlobalOpts
                    { goSocketPath = Just "/does/not/exist/node.socket"
                    , goNetworkMagic = NetworkMagic 764_824_073
                    , goNetworkName = Just "mainnet"
                    }
                `shouldBe` Left
                    "governance-withdrawal-init: --network must be devnet"

    describe "disburse-submit command" $ do
        it "parses the nested devnet disburse-submit command" $
            case parseCmd disburseSubmitArgs of
                Right (g, CmdDevnetDisburseSubmit o) -> do
                    goSocketPath g `shouldBe` Just "node.socket"
                    goNetworkMagic g `shouldBe` NetworkMagic 42
                    goNetworkName g `shouldBe` Just "devnet"
                    o
                        `shouldBe` DevnetDisburseSubmitOpts
                            { ddsioRegistryFile =
                                "runs/devnet/registry-init/registry.json"
                            , ddsioMaterializedFile =
                                "runs/devnet/governance-withdrawal-init/materialized.json"
                            , ddsioFundingAddress = fundingAddress
                            , ddsioSigningKeyFile = "payment.skey"
                            , ddsioBeneficiaryAddress = beneficiaryAddress
                            , ddsioRunDir = "runs/devnet"
                            , ddsioAmountLovelace = 1_000_000
                            }
                Right _ ->
                    expectationFailure
                        "expected devnet disburse-submit command"
                Left e -> expectationFailure e

        it "rejects non-DevNet networks before disburse effects" $
            requireDevnetDisburseSubmitNetwork
                GlobalOpts
                    { goSocketPath = Just "/does/not/exist/node.socket"
                    , goNetworkMagic = NetworkMagic 1
                    , goNetworkName = Just "preprod"
                    }
                `shouldBe` Left
                    "disburse-submit: --network must be devnet"

parseCmd :: [String] -> Either String (GlobalOpts, Cmd)
parseCmd args =
    case execParserPure defaultPrefs opts args of
        Success parsed -> Right parsed
        Failure{} -> Left "parse failure"
        CompletionInvoked{} -> Left "completion invoked"

registryInitArgs :: [String]
registryInitArgs =
    [ "--network"
    , "devnet"
    , "--node-socket"
    , "node.socket"
    , "devnet"
    , "registry-init"
    , "--funding-address"
    , fundingAddress
    , "--signing-key-file"
    , "payment.skey"
    , "--run-dir"
    , "runs/devnet/registry-init"
    ]

stakeRewardInitArgs :: [String]
stakeRewardInitArgs =
    [ "--network"
    , "devnet"
    , "--node-socket"
    , "node.socket"
    , "devnet"
    , "stake-reward-init"
    , "--registry-file"
    , "runs/devnet/stake/registry-init/registry.json"
    , "--funding-address"
    , fundingAddress
    , "--signing-key-file"
    , "payment.skey"
    , "--run-dir"
    , "runs/devnet/stake"
    ]

governanceWithdrawalInitArgs :: [String]
governanceWithdrawalInitArgs =
    [ "--network"
    , "devnet"
    , "--node-socket"
    , "node.socket"
    , "devnet"
    , "governance-withdrawal-init"
    , "--registry-file"
    , "runs/devnet/registry-init/registry.json"
    , "--stake-reward-file"
    , "runs/devnet/stake-reward-init/accounts.json"
    , "--funding-address"
    , fundingAddress
    , "--signing-key-file"
    , "payment.skey"
    , "--run-dir"
    , "runs/devnet"
    , "--amount-lovelace"
    , "2000000"
    , "--reward-timeout-seconds"
    , "180"
    ]

disburseSubmitArgs :: [String]
disburseSubmitArgs =
    [ "--network"
    , "devnet"
    , "--node-socket"
    , "node.socket"
    , "devnet"
    , "disburse-submit"
    , "--registry-file"
    , "runs/devnet/registry-init/registry.json"
    , "--materialized-file"
    , "runs/devnet/governance-withdrawal-init/materialized.json"
    , "--funding-address"
    , fundingAddress
    , "--signing-key-file"
    , "payment.skey"
    , "--beneficiary-address"
    , beneficiaryAddress
    , "--run-dir"
    , "runs/devnet"
    ]

fundingAddress :: String
fundingAddress =
    "addr_test1vqg7qku3m5d8czwgh3p6hrq3r8qu9m7u"

beneficiaryAddress :: String
beneficiaryAddress =
    "addr_test1q802wxt6cg6aw0nl0vdzfxavu65rxu3yzhvgayw7chfxymduzkt66uw9t5kspx5jwjecx80dz4g33htknafhdhkvzd5st4f9xu"
