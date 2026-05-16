{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Devnet.StakeRewardInitSpec
Description : Unit tests for DevNet stake/reward setup projections
License     : Apache-2.0
-}
module Amaru.Treasury.Devnet.StakeRewardInitSpec (spec) where

import Cardano.Crypto.Hash.Class
    ( Hash
    , HashAlgorithm
    , hashFromBytes
    )
import Cardano.Ledger.Api.PParams (emptyPParams)
import Cardano.Ledger.Api.Tx.Body
    ( certsTxBodyL
    , collateralInputsTxBodyL
    , inputsTxBodyL
    , referenceInputsTxBodyL
    )
import Cardano.Ledger.BaseTypes
    ( Network (..)
    , mkTxIxPartial
    )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Core (bodyTxL)
import Cardano.Ledger.Credential (Credential (..))
import Cardano.Ledger.Hashes
    ( ScriptHash (..)
    , unsafeMakeSafeHash
    )
import Cardano.Ledger.Keys (KeyRole (Staking))
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Tx.Build
    ( ConwayDelegCert (..)
    , ConwayTxCert (..)
    , DRep (..)
    , Delegatee (..)
    , draft
    )
import Data.Aeson
    ( Value
    , object
    , (.=)
    )
import Data.ByteString qualified as BS
import Data.Foldable (toList)
import Data.Maybe (fromJust)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Word (Word8)
import Lens.Micro ((^.))
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
    , stakeRewardSetupProgram
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
            "drafts stake-reward-init setup certifying only the treasury reward account"
            $ do
                let seedIn = mkTxIn 1
                    treasuryRef = mkTxIn 2
                    permissionsRef = mkTxIn 3
                    treasuryCredential = scriptCredential 10
                    stakeDeposit = Coin 2_000_000
                    tx =
                        draft emptyPParams $
                            stakeRewardSetupProgram
                                seedIn
                                treasuryRef
                                permissionsRef
                                treasuryCredential
                                stakeDeposit
                                (SlotNo 100)
                    body = tx ^. bodyTxL
                body ^. inputsTxBodyL `shouldBe` Set.singleton seedIn
                body
                    ^. collateralInputsTxBodyL
                    `shouldBe` Set.singleton seedIn
                body
                    ^. referenceInputsTxBodyL
                    `shouldBe` Set.fromList [treasuryRef, permissionsRef]
                toList (body ^. certsTxBodyL)
                    `shouldBe` [ ConwayTxCertDeleg $
                                    ConwayRegDelegCert
                                        treasuryCredential
                                        (DelegVote DRepAlwaysAbstain)
                                        stakeDeposit
                               ]

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
                                        True
                                , "permissions"
                                    .= accountValue
                                        samplePermissionsHash
                                        samplePermissionsHash
                                        False
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
                               , PermissionsRewardAccountAvailableForWithdrawZero
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
                sampleAccount sampleTreasuryHash sampleTreasuryHash True
            , dsrirPermissions =
                sampleAccount samplePermissionsHash samplePermissionsHash False
            , dsrirDiagnostics =
                [ RewardAccountRegistrationInferredFromAcceptedTx
                , PermissionsRewardAccountAvailableForWithdrawZero
                ]
            }

sampleAccount :: T.Text -> T.Text -> Bool -> DevnetStakeRewardAccount
sampleAccount scriptHash rewardAccount registered =
    DevnetStakeRewardAccount
        { dsraScriptHash = scriptHash
        , dsraRewardAccount = rewardAccount
        , dsraLedgerNetwork = Testnet
        , dsraRegistered = registered
        , dsraRewardsLovelace = 0
        }

accountValue :: T.Text -> T.Text -> Bool -> Value
accountValue scriptHash rewardAccount registered =
    object
        [ "scriptHash" .= scriptHash
        , "rewardAccount" .= rewardAccount
        , "ledgerNetwork" .= ("Testnet" :: T.Text)
        , "registered" .= registered
        , "rewardsLovelace" .= (0 :: Integer)
        ]

mkHash32 :: (HashAlgorithm h) => Word8 -> Hash h a
mkHash32 n =
    fromJust . hashFromBytes . BS.pack $
        replicate 31 0 ++ [n]

mkHash28 :: (HashAlgorithm h) => Word8 -> Hash h a
mkHash28 n =
    fromJust . hashFromBytes . BS.pack $
        replicate 27 0 ++ [n]

mkTxIn :: Word8 -> TxIn
mkTxIn n =
    TxIn
        (TxId (unsafeMakeSafeHash (mkHash32 n)))
        (mkTxIxPartial 0)

scriptCredential :: Word8 -> Credential Staking
scriptCredential n =
    ScriptHashObj (ScriptHash (mkHash28 n))

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
