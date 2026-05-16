{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Devnet.StakeRewardInitSpec
Description : Unit tests for DevNet stake/reward setup projections
License     : Apache-2.0
-}
module Amaru.Treasury.Devnet.StakeRewardInitSpec (spec) where

import Cardano.Ledger.BaseTypes (Network (..))
import Cardano.Ledger.TxIn (TxId, TxIn (..))
import Data.Aeson
    ( Value
    , object
    , (.=)
    )
import Data.Text qualified as T
import System.FilePath ((</>))
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    )

import Amaru.Treasury.Devnet.StakeRewardInit
    ( DevnetStakeRewardAccount (..)
    , DevnetStakeRewardInitResult (..)
    , StakeRewardInitDiagnostic (..)
    , stakeRewardInitAccountsPath
    , stakeRewardInitAccountsValue
    , stakeRewardInitCommandLines
    , stakeRewardInitProvenancePath
    , stakeRewardInitProvenanceValue
    , stakeRewardInitSummaryPath
    , stakeRewardInitSummaryValue
    )
import Amaru.Treasury.LedgerParse
    ( txInFromText
    )

spec :: Spec
spec =
    describe "Amaru.Treasury.Devnet.StakeRewardInit" $ do
        it "renders the stake-reward-init artifact paths" $ do
            stakeRewardInitSummaryPath sampleRunDir
                `shouldBe` sampleRunDir
                    </> "stake-reward-init"
                    </> "summary.json"
            stakeRewardInitAccountsPath sampleRunDir
                `shouldBe` sampleRunDir
                    </> "stake-reward-init"
                    </> "accounts.json"
            stakeRewardInitProvenancePath sampleRunDir
                `shouldBe` sampleRunDir
                    </> "stake-reward-init"
                    </> "provenance.json"

        it
            "renders stake-reward-init summary, accounts, provenance, and success lines"
            $ do
                result <- sampleResult
                stakeRewardInitSummaryValue
                    42
                    sampleRunDir
                    sampleRegistryPath
                    result
                    `shouldBe` object
                        [ "phase" .= ("stake-reward-init" :: T.Text)
                        , "network" .= ("devnet" :: T.Text)
                        , "networkMagic" .= (42 :: Int)
                        , "registryPath" .= sampleRegistryPath
                        , "setupTxId" .= sampleSetupTxId
                        , "accountsPath"
                            .= stakeRewardInitAccountsPath sampleRunDir
                        , "provenancePath"
                            .= stakeRewardInitProvenancePath sampleRunDir
                        ]
                stakeRewardInitAccountsValue result
                    `shouldBe` object
                        [ "phase" .= ("stake-reward-init" :: T.Text)
                        , "network" .= ("devnet" :: T.Text)
                        , "accounts"
                            .= object
                                [ "treasury"
                                    .= accountValue
                                        sampleTreasuryHash
                                        sampleTreasuryHash
                                , "permissions"
                                    .= accountValue
                                        samplePermissionsHash
                                        samplePermissionsHash
                                ]
                        ]
                stakeRewardInitProvenanceValue
                    `shouldBe` object
                        [ "phase" .= ("stake-reward-init" :: T.Text)
                        , "source" .= ("amaru-treasury-tx" :: T.Text)
                        , "issue" .= (148 :: Int)
                        , "parentIssue" .= (151 :: Int)
                        , "dependsOnIssue" .= (147 :: Int)
                        ]
                stakeRewardInitCommandLines 42 sampleRunDir result
                    `shouldBe` [ "stake-reward-init: run-dir runs/devnet/sample"
                               , "stake-reward-init: network devnet magic 42"
                               , "stake-reward-init: phase stake-reward-init passed"
                               , "stake-reward-init: setup-tx-id "
                                    <> T.unpack sampleSetupTxId
                               , "stake-reward-init: treasury-reward-account "
                                    <> T.unpack sampleTreasuryHash
                               , "stake-reward-init: permissions-reward-account "
                                    <> T.unpack samplePermissionsHash
                               , "stake-reward-init: summary runs/devnet/sample/stake-reward-init/summary.json"
                               , "stake-reward-init: accounts runs/devnet/sample/stake-reward-init/accounts.json"
                               ]

        it
            "keeps the stake-reward-init provider reward-account limitation explicit"
            $ do
                result <- sampleResult
                dsrirDiagnostics result
                    `shouldBe` [ RewardAccountRegistrationInferredFromAcceptedTx
                               ]

sampleRunDir :: FilePath
sampleRunDir =
    "runs/devnet/sample"

sampleRegistryPath :: FilePath
sampleRegistryPath =
    sampleRunDir </> "registry-init" </> "registry.json"

sampleSetupTxId :: T.Text
sampleSetupTxId =
    "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"

sampleTreasuryHash :: T.Text
sampleTreasuryHash =
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

samplePermissionsHash :: T.Text
samplePermissionsHash =
    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

sampleResult :: IO DevnetStakeRewardInitResult
sampleResult = do
    setupTxId <- parseTxId sampleSetupTxId
    pure
        DevnetStakeRewardInitResult
            { dsrirSetupTxId = setupTxId
            , dsrirTreasury =
                sampleAccount sampleTreasuryHash sampleTreasuryHash
            , dsrirPermissions =
                sampleAccount samplePermissionsHash samplePermissionsHash
            , dsrirDiagnostics =
                [RewardAccountRegistrationInferredFromAcceptedTx]
            }

sampleAccount :: T.Text -> T.Text -> DevnetStakeRewardAccount
sampleAccount scriptHash rewardAccount =
    DevnetStakeRewardAccount
        { dsraScriptHash = scriptHash
        , dsraRewardAccount = rewardAccount
        , dsraLedgerNetwork = Testnet
        , dsraRegistered = True
        , dsraRewardsLovelace = 0
        }

accountValue :: T.Text -> T.Text -> Value
accountValue scriptHash rewardAccount =
    object
        [ "scriptHash" .= scriptHash
        , "rewardAccount" .= rewardAccount
        , "ledgerNetwork" .= ("Testnet" :: T.Text)
        , "registered" .= True
        , "rewardsLovelace" .= (0 :: Integer)
        ]

parseTxId :: T.Text -> IO TxId
parseTxId txIdText = do
    TxIn txId _ <- parse "tx id" txInFromText (txIdText <> "#0")
    pure txId

parse :: String -> (T.Text -> Either String a) -> T.Text -> IO a
parse label parser input =
    case parser input of
        Left err ->
            expectationFailure (label <> ": " <> err)
                *> error "unreachable"
        Right ok -> pure ok
