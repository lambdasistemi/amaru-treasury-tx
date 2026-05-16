{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Devnet.GovernanceWithdrawalInitSpec
Description : Unit tests for DevNet governance/withdrawal init projections
License     : Apache-2.0
-}
module Amaru.Treasury.Devnet.GovernanceWithdrawalInitSpec (spec) where

import Data.Aeson
    ( object
    , (.=)
    )
import Data.Text qualified as T
import System.Directory
    ( createDirectoryIfMissing
    , doesFileExist
    , getTemporaryDirectory
    , removePathForcibly
    )
import System.FilePath ((</>))
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    )

import Amaru.Treasury.Devnet.GovernanceWithdrawalInit
    ( DevnetGovernanceStakeRewardAccount (..)
    , DevnetGovernanceStakeRewardAccounts (..)
    , DevnetGovernanceWithdrawalRegistry (..)
    , GovernanceWithdrawalGovernanceEvidence (..)
    , GovernanceWithdrawalInitFailure (..)
    , GovernanceWithdrawalInitFailureStep (..)
    , GovernanceWithdrawalInitResult (..)
    , GovernanceWithdrawalMaterializationEvidence (..)
    , GovernanceWithdrawalObservedTxIds (..)
    , GovernanceWithdrawalWithdrawalEvidence (..)
    , governanceWithdrawalInitCommandLines
    , governanceWithdrawalInitFailurePath
    , governanceWithdrawalInitFailureValue
    , governanceWithdrawalInitGovernancePath
    , governanceWithdrawalInitGovernanceValue
    , governanceWithdrawalInitIntentPath
    , governanceWithdrawalInitMaterializationPath
    , governanceWithdrawalInitMaterializationValue
    , governanceWithdrawalInitProvenancePath
    , governanceWithdrawalInitProvenanceValue
    , governanceWithdrawalInitReportJsonPath
    , governanceWithdrawalInitReportMarkdownPath
    , governanceWithdrawalInitSignedTxPath
    , governanceWithdrawalInitSubmitLogPath
    , governanceWithdrawalInitSummaryPath
    , governanceWithdrawalInitSummaryValue
    , governanceWithdrawalInitTxBodyPath
    , governanceWithdrawalInitTxBuildLogPath
    , governanceWithdrawalInitWithdrawalPath
    , governanceWithdrawalInitWithdrawalValue
    , gwpRegistry
    , validateGovernanceWithdrawalInitInputs
    , validateGovernanceWithdrawalPrerequisites
    , validateTreasuryMaterializationDelta
    , writeGovernanceWithdrawalInitFailure
    )
import Amaru.Treasury.LedgerParse
    ( scriptHashFromHex
    , txInFromText
    )
import Cardano.Ledger.Address
    ( Addr (..)
    )
import Cardano.Ledger.BaseTypes (Network (Testnet))
import Cardano.Ledger.Credential
    ( Credential (..)
    , StakeReference (..)
    )
import Cardano.Ledger.Hashes (ScriptHash)
import Cardano.Ledger.TxIn (TxIn)

spec :: Spec
spec =
    describe "Amaru.Treasury.Devnet.GovernanceWithdrawalInit" $ do
        it "renders the governance-withdrawal-init artifact paths" $ do
            governanceWithdrawalInitSummaryPath sampleRunDir
                `shouldBe` commandDir </> "summary.json"
            governanceWithdrawalInitGovernancePath sampleRunDir
                `shouldBe` commandDir </> "governance.json"
            governanceWithdrawalInitWithdrawalPath sampleRunDir
                `shouldBe` commandDir </> "withdrawal.json"
            governanceWithdrawalInitMaterializationPath sampleRunDir
                `shouldBe` commandDir </> "materialized.json"
            governanceWithdrawalInitProvenancePath sampleRunDir
                `shouldBe` commandDir </> "provenance.json"
            governanceWithdrawalInitFailurePath sampleRunDir
                `shouldBe` commandDir </> "failure.json"
            governanceWithdrawalInitIntentPath sampleRunDir
                `shouldBe` commandDir </> "intent.json"
            governanceWithdrawalInitTxBodyPath sampleRunDir
                `shouldBe` commandDir </> "tx-body.cbor.hex"
            governanceWithdrawalInitReportJsonPath sampleRunDir
                `shouldBe` commandDir </> "report.json"
            governanceWithdrawalInitReportMarkdownPath sampleRunDir
                `shouldBe` commandDir </> "report.md"
            governanceWithdrawalInitTxBuildLogPath sampleRunDir
                `shouldBe` commandDir </> "tx-build.log"
            governanceWithdrawalInitSignedTxPath sampleRunDir
                `shouldBe` commandDir </> "signed-tx.cbor.hex"
            governanceWithdrawalInitSubmitLogPath sampleRunDir
                `shouldBe` commandDir </> "submit.log"

        it
            "validates matching registry and stake-reward prerequisite artifacts"
            $ do
                case validateGovernanceWithdrawalPrerequisites
                    sampleRegistry
                    sampleAccounts of
                    Right prereqs ->
                        dgwrTreasuryScriptHashText (gwpRegistry prereqs)
                            `shouldBe` sampleTreasuryHash
                    Left err ->
                        expectationFailure $
                            "expected prerequisites to validate: " <> show err

                let unregistered =
                        sampleAccounts
                            { dgsrasTreasury =
                                (dgsrasTreasury sampleAccounts)
                                    { dgsraRegistered = False
                                    }
                            }
                case validateGovernanceWithdrawalPrerequisites
                    sampleRegistry
                    unregistered of
                    Left err ->
                        gwifCode err `shouldBe` "treasury-reward-not-registered"
                    Right{} ->
                        expectationFailure
                            "expected unregistered treasury account to fail"

        it "rejects non-positive scalar command inputs with stable failures" $ do
            case validateGovernanceWithdrawalInitInputs 0 180 of
                Left err -> do
                    gwifCode err `shouldBe` "amount-lovelace-non-positive"
                    gwifFailedStep err
                        `shouldBe` GovernanceWithdrawalValidateInputs
                Right{} ->
                    expectationFailure "expected zero amount to fail"

            case validateGovernanceWithdrawalInitInputs 2_000_000 0 of
                Left err -> do
                    gwifCode err
                        `shouldBe` "reward-timeout-seconds-non-positive"
                    gwifFailedStep err
                        `shouldBe` GovernanceWithdrawalValidateInputs
                Right{} ->
                    expectationFailure "expected zero reward timeout to fail"

        it
            "removes stale command-owned success and build artifacts on failure"
            $ do
                tmp <- getTemporaryDirectory
                let runDir =
                        tmp
                            </> "amaru-treasury-tx-governance-withdrawal-cleanup-test"
                    stalePaths =
                        [ governanceWithdrawalInitSummaryPath runDir
                        , governanceWithdrawalInitGovernancePath runDir
                        , governanceWithdrawalInitWithdrawalPath runDir
                        , governanceWithdrawalInitMaterializationPath runDir
                        , governanceWithdrawalInitProvenancePath runDir
                        , governanceWithdrawalInitIntentPath runDir
                        , governanceWithdrawalInitTxBodyPath runDir
                        , governanceWithdrawalInitReportJsonPath runDir
                        , governanceWithdrawalInitReportMarkdownPath runDir
                        , governanceWithdrawalInitTxBuildLogPath runDir
                        , governanceWithdrawalInitSignedTxPath runDir
                        , governanceWithdrawalInitSubmitLogPath runDir
                        ]
                removePathForcibly runDir
                createDirectoryIfMissing
                    True
                    (runDir </> "governance-withdrawal-init")
                mapM_ (`writeFile` "stale") stalePaths
                writeGovernanceWithdrawalInitFailure runDir sampleFailure

                doesFileExist (governanceWithdrawalInitFailurePath runDir)
                    >>= (`shouldBe` True)
                mapM_
                    ( \path -> do
                        exists <- doesFileExist path
                        exists `shouldBe` False
                    )
                    stalePaths
                removePathForcibly runDir

        it "rejects materialization when treasury ADA delta does not match" $ do
            validateTreasuryMaterializationDelta sampleObservedTxIds 10 30 20
                `shouldBe` Right ()
            case validateTreasuryMaterializationDelta
                sampleObservedTxIds
                10
                25
                20 of
                Left err -> do
                    gwifCode err
                        `shouldBe` "materialization-treasury-delta-mismatch"
                    gwifFailedStep err
                        `shouldBe` GovernanceWithdrawalMaterializationVerify
                Right{} ->
                    expectationFailure
                        "expected mismatched materialization delta to fail"

        it
            "renders summary, governance, withdrawal, materialization, provenance, and success lines"
            $ do
                let result = sampleResult
                governanceWithdrawalInitSummaryValue 42 sampleRunDir result
                    `shouldBe` object
                        [ "phase" .= ("governance-withdrawal-init" :: T.Text)
                        , "status" .= ("passed" :: T.Text)
                        , "network" .= ("devnet" :: T.Text)
                        , "networkMagic" .= (42 :: Int)
                        , "runDirectory" .= sampleRunDir
                        , "registryPath" .= sampleRegistryPath
                        , "stakeRewardPath" .= sampleStakeRewardPath
                        , "amountLovelace" .= (2_000_000 :: Integer)
                        , "governancePath"
                            .= governanceWithdrawalInitGovernancePath sampleRunDir
                        , "withdrawalPath"
                            .= governanceWithdrawalInitWithdrawalPath sampleRunDir
                        , "materializationPath"
                            .= governanceWithdrawalInitMaterializationPath sampleRunDir
                        , "provenancePath"
                            .= governanceWithdrawalInitProvenancePath sampleRunDir
                        ]
                governanceWithdrawalInitGovernanceValue result
                    `shouldBe` object
                        [ "phase" .= ("governance-withdrawal-init" :: T.Text)
                        , "network" .= ("devnet" :: T.Text)
                        , "proposalTxId" .= sampleProposalTxId
                        , "governanceActionId" .= sampleActionId
                        , "voteTxId" .= sampleVoteTxId
                        , "treasuryRewardAccount" .= sampleTreasuryHash
                        , "treasuryScriptHash" .= sampleTreasuryHash
                        , "amountLovelace" .= (2_000_000 :: Integer)
                        , "rewardBeforeLovelace" .= (0 :: Integer)
                        , "rewardAfterGovernanceLovelace"
                            .= (2_000_000 :: Integer)
                        , "setupEpoch" .= (2 :: Integer)
                        , "voteEpoch" .= (3 :: Integer)
                        , "finalEpoch" .= (4 :: Integer)
                        ]
                governanceWithdrawalInitWithdrawalValue result
                    `shouldBe` object
                        [ "phase" .= ("governance-withdrawal-init" :: T.Text)
                        , "network" .= ("devnet" :: T.Text)
                        , "intentPath"
                            .= governanceWithdrawalInitIntentPath sampleRunDir
                        , "txBodyPath"
                            .= governanceWithdrawalInitTxBodyPath sampleRunDir
                        , "reportJsonPath"
                            .= governanceWithdrawalInitReportJsonPath sampleRunDir
                        , "reportMarkdownPath"
                            .= governanceWithdrawalInitReportMarkdownPath sampleRunDir
                        , "txBuildLogPath"
                            .= governanceWithdrawalInitTxBuildLogPath sampleRunDir
                        , "signedTxPath"
                            .= governanceWithdrawalInitSignedTxPath sampleRunDir
                        , "submitLogPath"
                            .= governanceWithdrawalInitSubmitLogPath sampleRunDir
                        , "txId" .= sampleWithdrawTxId
                        , "submittedTxId" .= sampleWithdrawTxId
                        , "feeLovelace" .= (173_000 :: Integer)
                        , "rewardBeforeSubmitLovelace" .= (2_000_000 :: Integer)
                        , "rewardAfterSubmitLovelace" .= (0 :: Integer)
                        ]
                governanceWithdrawalInitMaterializationValue result
                    `shouldBe` object
                        [ "phase" .= ("governance-withdrawal-init" :: T.Text)
                        , "network" .= ("devnet" :: T.Text)
                        , "governanceActionId" .= sampleActionId
                        , "treasuryRewardAccount" .= sampleTreasuryHash
                        , "submittedTxId" .= sampleWithdrawTxId
                        , "treasuryMaterializedTxIn" .= sampleMaterializedTxIn
                        , "treasuryAddress" .= sampleTreasuryAddress
                        , "materializedAdaLovelace" .= (2_000_000 :: Integer)
                        , "rewardBeforeSubmitLovelace" .= (2_000_000 :: Integer)
                        , "rewardAfterSubmitLovelace" .= (0 :: Integer)
                        , "treasuryUtxoLovelaceBefore" .= (0 :: Integer)
                        , "treasuryUtxoLovelaceAfter"
                            .= (2_000_000 :: Integer)
                        , "registryPath" .= sampleRegistryPath
                        , "stakeRewardPath" .= sampleStakeRewardPath
                        ]
                governanceWithdrawalInitProvenanceValue
                    `shouldBe` object
                        [ "phase" .= ("governance-withdrawal-init" :: T.Text)
                        , "source" .= ("amaru-treasury-tx" :: T.Text)
                        , "issue" .= (149 :: Int)
                        , "parentIssue" .= (151 :: Int)
                        , "dependsOnIssues" .= ([147, 148] :: [Int])
                        ]
                governanceWithdrawalInitCommandLines 42 sampleRunDir result
                    `shouldBe` [ "governance-withdrawal-init: run-dir runs/devnet/sample"
                               , "governance-withdrawal-init: network devnet magic 42"
                               , "governance-withdrawal-init: phase governance-withdrawal-init passed"
                               , "governance-withdrawal-init: governance-proposal-tx-id "
                                    <> T.unpack sampleProposalTxId
                               , "governance-withdrawal-init: governance-action-id "
                                    <> T.unpack sampleActionId
                               , "governance-withdrawal-init: vote-tx-id "
                                    <> T.unpack sampleVoteTxId
                               , "governance-withdrawal-init: treasury-reward-account "
                                    <> T.unpack sampleTreasuryHash
                               , "governance-withdrawal-init: reward-before-lovelace 0"
                               , "governance-withdrawal-init: reward-after-governance-lovelace 2000000"
                               , "governance-withdrawal-init: withdraw-tx-id "
                                    <> T.unpack sampleWithdrawTxId
                               , "governance-withdrawal-init: withdraw-submitted-tx-id "
                                    <> T.unpack sampleWithdrawTxId
                               , "governance-withdrawal-init: treasury-materialized-tx-in "
                                    <> T.unpack sampleMaterializedTxIn
                               , "governance-withdrawal-init: treasury-materialized-ada 2000000"
                               , "governance-withdrawal-init: summary runs/devnet/sample/governance-withdrawal-init/summary.json"
                               , "governance-withdrawal-init: materialization runs/devnet/sample/governance-withdrawal-init/materialized.json"
                               ]

        it "renders stable failure projection fields" $ do
            governanceWithdrawalInitFailureValue sampleRunDir sampleFailure
                `shouldBe` object
                    [ "phase" .= ("governance-withdrawal-init" :: T.Text)
                    , "status" .= ("failed" :: T.Text)
                    , "code" .= ("reward-timeout" :: T.Text)
                    , "message"
                        .= ( "timed out waiting for treasury reward account"
                                :: T.Text
                           )
                    , "failedStep" .= ("reward-wait" :: T.Text)
                    , "observedTxIds"
                        .= object
                            [ "proposal" .= Just sampleProposalTxId
                            , "vote" .= Just sampleVoteTxId
                            , "withdrawal" .= (Nothing :: Maybe T.Text)
                            ]
                    , "lastObservedRewardLovelace"
                        .= (Just 0 :: Maybe Integer)
                    , "epoch" .= (Just 3 :: Maybe Integer)
                    , "tipSlot" .= (Just 500 :: Maybe Integer)
                    , "summaryPath"
                        .= governanceWithdrawalInitFailurePath sampleRunDir
                    ]

sampleRunDir :: FilePath
sampleRunDir =
    "runs/devnet/sample"

commandDir :: FilePath
commandDir =
    sampleRunDir </> "governance-withdrawal-init"

sampleRegistryPath :: FilePath
sampleRegistryPath =
    sampleRunDir </> "registry-init" </> "registry.json"

sampleStakeRewardPath :: FilePath
sampleStakeRewardPath =
    sampleRunDir </> "stake-reward-init" </> "accounts.json"

sampleProposalTxId :: T.Text
sampleProposalTxId =
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

sampleVoteTxId :: T.Text
sampleVoteTxId =
    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

sampleWithdrawTxId :: T.Text
sampleWithdrawTxId =
    "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

sampleActionId :: T.Text
sampleActionId =
    sampleProposalTxId <> "#0"

sampleMaterializedTxIn :: T.Text
sampleMaterializedTxIn =
    sampleWithdrawTxId <> "#0"

sampleTreasuryHash :: T.Text
sampleTreasuryHash =
    "dddddddddddddddddddddddddddddddddddddddddddddddddddddddd"

sampleTreasuryAddress :: T.Text
sampleTreasuryAddress =
    "addr_test1wzsampletreasury"

sampleResult :: GovernanceWithdrawalInitResult
sampleResult =
    GovernanceWithdrawalInitResult
        { gwirRegistryPath = sampleRegistryPath
        , gwirStakeRewardPath = sampleStakeRewardPath
        , gwirGovernance =
            GovernanceWithdrawalGovernanceEvidence
                { gwgeProposalTxId = sampleProposalTxId
                , gwgeGovernanceActionId = sampleActionId
                , gwgeVoteTxId = sampleVoteTxId
                , gwgeTreasuryRewardAccount = sampleTreasuryHash
                , gwgeTreasuryScriptHash = sampleTreasuryHash
                , gwgeAmountLovelace = 2_000_000
                , gwgeRewardBeforeLovelace = 0
                , gwgeRewardAfterGovernanceLovelace = 2_000_000
                , gwgeSetupEpoch = 2
                , gwgeVoteEpoch = 3
                , gwgeFinalEpoch = 4
                }
        , gwirWithdrawal =
            GovernanceWithdrawalWithdrawalEvidence
                { gwweIntentPath =
                    governanceWithdrawalInitIntentPath sampleRunDir
                , gwweTxBodyPath =
                    governanceWithdrawalInitTxBodyPath sampleRunDir
                , gwweReportJsonPath =
                    governanceWithdrawalInitReportJsonPath sampleRunDir
                , gwweReportMarkdownPath =
                    governanceWithdrawalInitReportMarkdownPath sampleRunDir
                , gwweTxBuildLogPath =
                    governanceWithdrawalInitTxBuildLogPath sampleRunDir
                , gwweSignedTxPath =
                    governanceWithdrawalInitSignedTxPath sampleRunDir
                , gwweSubmitLogPath =
                    governanceWithdrawalInitSubmitLogPath sampleRunDir
                , gwweTxId = sampleWithdrawTxId
                , gwweSubmittedTxId = sampleWithdrawTxId
                , gwweFeeLovelace = 173_000
                , gwweRewardBeforeSubmitLovelace = 2_000_000
                , gwweRewardAfterSubmitLovelace = 0
                }
        , gwirMaterialization =
            GovernanceWithdrawalMaterializationEvidence
                { gwmeGovernanceActionId = sampleActionId
                , gwmeTreasuryRewardAccount = sampleTreasuryHash
                , gwmeSubmittedTxId = sampleWithdrawTxId
                , gwmeTreasuryMaterializedTxIn = sampleMaterializedTxIn
                , gwmeTreasuryAddress = sampleTreasuryAddress
                , gwmeMaterializedAdaLovelace = 2_000_000
                , gwmeRewardBeforeSubmitLovelace = 2_000_000
                , gwmeRewardAfterSubmitLovelace = 0
                , gwmeTreasuryUtxoLovelaceBefore = 0
                , gwmeTreasuryUtxoLovelaceAfter = 2_000_000
                }
        }

sampleObservedTxIds :: GovernanceWithdrawalObservedTxIds
sampleObservedTxIds =
    GovernanceWithdrawalObservedTxIds
        { gwoProposal = Just sampleProposalTxId
        , gwoVote = Just sampleVoteTxId
        , gwoWithdrawal = Nothing
        }

sampleFailure :: GovernanceWithdrawalInitFailure
sampleFailure =
    GovernanceWithdrawalInitFailure
        { gwifCode = "reward-timeout"
        , gwifMessage =
            "timed out waiting for treasury reward account"
        , gwifFailedStep = GovernanceWithdrawalRewardWait
        , gwifObservedTxIds = sampleObservedTxIds
        , gwifLastObservedRewardLovelace = Just 0
        , gwifEpoch = Just 3
        , gwifTipSlot = Just 500
        }

sampleRegistry :: DevnetGovernanceWithdrawalRegistry
sampleRegistry =
    DevnetGovernanceWithdrawalRegistry
        { dgwrScopesRef = parseTxIn sampleProposalTxId 0
        , dgwrRegistryRef = parseTxIn sampleProposalTxId 1
        , dgwrPermissionsRef = parseTxIn sampleProposalTxId 2
        , dgwrTreasuryRef = parseTxIn sampleProposalTxId 3
        , dgwrRegistryPolicyId = sampleTreasuryHash
        , dgwrPermissionsScriptHashText = sampleTreasuryHash
        , dgwrPermissionsScriptHash = sampleScriptHash
        , dgwrTreasuryScriptHashText = sampleTreasuryHash
        , dgwrTreasuryScriptHash = sampleScriptHash
        , dgwrTreasuryAddressText = sampleTreasuryAddress
        , dgwrTreasuryAddress =
            Addr
                Testnet
                (ScriptHashObj sampleScriptHash)
                (StakeRefBase (ScriptHashObj sampleScriptHash))
        , dgwrOwnerKeyHash = sampleTreasuryHash
        }

sampleAccounts :: DevnetGovernanceStakeRewardAccounts
sampleAccounts =
    DevnetGovernanceStakeRewardAccounts
        { dgsrasTreasury =
            DevnetGovernanceStakeRewardAccount
                { dgsraScriptHash = sampleTreasuryHash
                , dgsraRewardAccount = sampleTreasuryHash
                , dgsraLedgerNetwork = "Testnet"
                , dgsraRegistered = True
                , dgsraRewardsLovelace = 0
                }
        , dgsrasPermissions =
            DevnetGovernanceStakeRewardAccount
                { dgsraScriptHash = sampleTreasuryHash
                , dgsraRewardAccount = sampleTreasuryHash
                , dgsraLedgerNetwork = "Testnet"
                , dgsraRegistered = False
                , dgsraRewardsLovelace = 0
                }
        }

sampleScriptHash :: ScriptHash
sampleScriptHash =
    parse "script hash" scriptHashFromHex sampleTreasuryHash

parseTxIn :: T.Text -> Integer -> TxIn
parseTxIn txId ix =
    parse "tx in" txInFromText (txId <> "#" <> T.pack (show ix))

parse :: String -> (T.Text -> Either String a) -> T.Text -> a
parse label parser input =
    case parser input of
        Right ok -> ok
        Left err -> error (label <> ": " <> err)
