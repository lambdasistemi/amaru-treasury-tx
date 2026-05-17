{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

{- |
Module      : Amaru.Treasury.Devnet.DisburseSubmitSpec
Description : Unit tests for DevNet disburse-submit projections
License     : Apache-2.0
-}
module Amaru.Treasury.Devnet.DisburseSubmitSpec (spec) where

import Data.Aeson
    ( Value
    , eitherDecode
    , encode
    , object
    , (.=)
    )
import Data.Either (isLeft)
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
    , shouldSatisfy
    )

import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.BaseTypes (Network (Testnet))
import Cardano.Ledger.Credential
    ( Credential (..)
    , StakeReference (..)
    )
import Cardano.Ledger.Hashes (ScriptHash)
import Cardano.Ledger.TxIn (TxIn)

import Amaru.Treasury.Devnet.DisburseSubmit
    ( DevnetDisburseSubmitMaterialized (..)
    , DisburseSubmitBeneficiaryEvidence (..)
    , DisburseSubmitDisburseEvidence (..)
    , DisburseSubmitFailure (..)
    , DisburseSubmitFailureStep (..)
    , DisburseSubmitObservedTxIds (..)
    , DisburseSubmitPrerequisites (..)
    , DisburseSubmitResult (..)
    , DisburseSubmitTreasuryEvidence (..)
    , ddspTreasuryInput
    , disburseSubmitBeneficiaryPath
    , disburseSubmitBeneficiaryValue
    , disburseSubmitCommandLines
    , disburseSubmitDirectory
    , disburseSubmitDisbursePath
    , disburseSubmitDisburseValue
    , disburseSubmitFailurePath
    , disburseSubmitFailureValue
    , disburseSubmitIntentPath
    , disburseSubmitProvenancePath
    , disburseSubmitProvenanceValue
    , disburseSubmitReportJsonPath
    , disburseSubmitReportMarkdownPath
    , disburseSubmitSignedTxPath
    , disburseSubmitSubmitLogPath
    , disburseSubmitSummaryPath
    , disburseSubmitSummaryValue
    , disburseSubmitTreasuryPath
    , disburseSubmitTreasuryValue
    , disburseSubmitTxBodyPath
    , dsfCode
    , dsfFailedStep
    , validateDisburseSubmitInputs
    , validateDisburseSubmitPrerequisites
    , writeDisburseSubmitFailure
    )
import Amaru.Treasury.Devnet.GovernanceWithdrawalInit
    ( DevnetGovernanceWithdrawalRegistry (..)
    , renderAddr
    )
import Amaru.Treasury.IntentJSON.Common
    ( parseAddr
    )
import Amaru.Treasury.LedgerParse
    ( scriptHashFromHex
    , txInFromText
    )

spec :: Spec
spec =
    describe "Amaru.Treasury.Devnet.DisburseSubmit" $ do
        it "renders the disburse-submit artifact paths" $ do
            disburseSubmitDirectory sampleRunDir
                `shouldBe` commandDir
            disburseSubmitSummaryPath sampleRunDir
                `shouldBe` commandDir </> "summary.json"
            disburseSubmitDisbursePath sampleRunDir
                `shouldBe` commandDir </> "disburse.json"
            disburseSubmitBeneficiaryPath sampleRunDir
                `shouldBe` commandDir </> "beneficiary.json"
            disburseSubmitTreasuryPath sampleRunDir
                `shouldBe` commandDir </> "treasury.json"
            disburseSubmitProvenancePath sampleRunDir
                `shouldBe` commandDir </> "provenance.json"
            disburseSubmitFailurePath sampleRunDir
                `shouldBe` commandDir </> "failure.json"
            disburseSubmitIntentPath sampleRunDir
                `shouldBe` commandDir </> "intent.json"
            disburseSubmitTxBodyPath sampleRunDir
                `shouldBe` commandDir </> "tx-body.cbor.hex"
            disburseSubmitReportJsonPath sampleRunDir
                `shouldBe` commandDir </> "report.json"
            disburseSubmitReportMarkdownPath sampleRunDir
                `shouldBe` commandDir </> "report.md"
            disburseSubmitSignedTxPath sampleRunDir
                `shouldBe` commandDir </> "signed-tx.cbor.hex"
            disburseSubmitSubmitLogPath sampleRunDir
                `shouldBe` commandDir </> "submit.log"

        it "rejects non-positive amounts with stable failure artifacts" $
            case validateDisburseSubmitInputs 0 of
                Left err -> do
                    dsfCode err `shouldBe` "amount-lovelace-non-positive"
                    dsfFailedStep err
                        `shouldBe` DisburseSubmitValidateInputs
                Right{} ->
                    expectationFailure "expected zero amount to fail"

        it "validates the registry and materialized prerequisites" $ do
            case validateDisburseSubmitPrerequisites
                sampleRegistryPath
                1_000_000
                sampleRegistry
                sampleMaterialized of
                Right prereqs ->
                    ddspTreasuryInput prereqs `shouldBe` sampleTreasuryInput
                Left err ->
                    expectationFailure $
                        "expected prerequisites to validate: " <> show err

            let mismatched =
                    sampleMaterialized
                        { ddsmTreasuryAddressText = otherAddress
                        , ddsmTreasuryAddress = parse "addr" parseAddr otherAddress
                        }
            case validateDisburseSubmitPrerequisites
                sampleRegistryPath
                1_000_000
                sampleRegistry
                mismatched of
                Left err ->
                    dsfCode err `shouldBe` "treasury-address-mismatch"
                Right{} ->
                    expectationFailure "expected treasury address mismatch"

            case validateDisburseSubmitPrerequisites
                sampleRegistryPath
                3_000_000
                sampleRegistry
                sampleMaterialized of
                Left err ->
                    dsfCode err `shouldBe` "treasury-amount-insufficient"
                Right{} ->
                    expectationFailure "expected treasury shortfall"

        it "rejects materialized artifacts with the wrong phase or network" $ do
            eitherDecode @DevnetDisburseSubmitMaterialized
                (encode (materializedJson "stake-reward-init" "devnet"))
                `shouldSatisfy` isLeft
            eitherDecode @DevnetDisburseSubmitMaterialized
                (encode (materializedJson "governance-withdrawal-init" "preprod"))
                `shouldSatisfy` isLeft

        it
            "renders summary, disburse, beneficiary, treasury, provenance, and success lines"
            $ do
                let result = sampleResult
                disburseSubmitSummaryValue 42 sampleRunDir result
                    `shouldBe` object
                        [ "phase" .= ("disburse-submit" :: T.Text)
                        , "status" .= ("passed" :: T.Text)
                        , "network" .= ("devnet" :: T.Text)
                        , "networkMagic" .= (42 :: Int)
                        , "runDirectory" .= sampleRunDir
                        , "registryPath" .= sampleRegistryPath
                        , "materializedPath" .= sampleMaterializedPath
                        , "amountLovelace" .= (1_000_000 :: Integer)
                        , "disbursePath"
                            .= disburseSubmitDisbursePath sampleRunDir
                        , "beneficiaryPath"
                            .= disburseSubmitBeneficiaryPath sampleRunDir
                        , "treasuryPath"
                            .= disburseSubmitTreasuryPath sampleRunDir
                        , "provenancePath"
                            .= disburseSubmitProvenancePath sampleRunDir
                        ]
                disburseSubmitDisburseValue result
                    `shouldBe` object
                        [ "phase" .= ("disburse-submit" :: T.Text)
                        , "network" .= ("devnet" :: T.Text)
                        , "intentPath" .= disburseSubmitIntentPath sampleRunDir
                        , "txBodyPath" .= disburseSubmitTxBodyPath sampleRunDir
                        , "reportJsonPath"
                            .= disburseSubmitReportJsonPath sampleRunDir
                        , "reportMarkdownPath"
                            .= disburseSubmitReportMarkdownPath sampleRunDir
                        , "signedTxPath"
                            .= disburseSubmitSignedTxPath sampleRunDir
                        , "submitLogPath"
                            .= disburseSubmitSubmitLogPath sampleRunDir
                        , "txId" .= sampleTxId
                        , "submittedTxId" .= sampleTxId
                        , "amountLovelace" .= (1_000_000 :: Integer)
                        , "feeLovelace" .= (171_000 :: Integer)
                        ]
                disburseSubmitBeneficiaryValue result
                    `shouldBe` object
                        [ "phase" .= ("disburse-submit" :: T.Text)
                        , "network" .= ("devnet" :: T.Text)
                        , "address" .= sampleBeneficiaryAddress
                        , "txIn" .= sampleBeneficiaryTxIn
                        , "lovelace" .= (1_000_000 :: Integer)
                        ]
                disburseSubmitTreasuryValue result
                    `shouldBe` object
                        [ "phase" .= ("disburse-submit" :: T.Text)
                        , "network" .= ("devnet" :: T.Text)
                        , "input" .= sampleTreasuryInputText
                        , "output" .= sampleTreasuryOutput
                        , "address" .= sampleTreasuryAddress
                        , "lovelaceBefore" .= (2_000_000 :: Integer)
                        , "lovelaceAfter" .= (1_000_000 :: Integer)
                        , "consumed" .= True
                        ]
                disburseSubmitProvenanceValue
                    `shouldBe` object
                        [ "phase" .= ("disburse-submit" :: T.Text)
                        , "source" .= ("amaru-treasury-tx" :: T.Text)
                        , "issue" .= (150 :: Int)
                        , "parentIssue" .= (151 :: Int)
                        , "dependsOnIssues" .= ([147, 149] :: [Int])
                        ]
                disburseSubmitCommandLines 42 sampleRunDir result
                    `shouldBe` [ "disburse-submit: run-dir runs/devnet/sample"
                               , "disburse-submit: network devnet magic 42"
                               , "disburse-submit: phase disburse-submit passed"
                               , "disburse-submit: submitted-tx-id "
                                    <> T.unpack sampleTxId
                               , "disburse-submit: beneficiary-address "
                                    <> T.unpack sampleBeneficiaryAddress
                               , "disburse-submit: beneficiary-tx-in "
                                    <> T.unpack sampleBeneficiaryTxIn
                               , "disburse-submit: beneficiary-lovelace 1000000"
                               , "disburse-submit: treasury-input "
                                    <> T.unpack sampleTreasuryInputText
                               , "disburse-submit: treasury-lovelace-before 2000000"
                               , "disburse-submit: treasury-lovelace-after 1000000"
                               , "disburse-submit: signed-tx runs/devnet/sample/disburse-submit/signed-tx.cbor.hex"
                               , "disburse-submit: submit-log runs/devnet/sample/disburse-submit/submit.log"
                               , "disburse-submit: summary runs/devnet/sample/disburse-submit/summary.json"
                               ]

        it
            "removes stale command-owned success artifacts on failure"
            $ do
                tmp <- getTemporaryDirectory
                let runDir =
                        tmp
                            </> "amaru-treasury-tx-disburse-submit-cleanup-test"
                    stalePaths =
                        [ disburseSubmitSummaryPath runDir
                        , disburseSubmitDisbursePath runDir
                        , disburseSubmitBeneficiaryPath runDir
                        , disburseSubmitTreasuryPath runDir
                        , disburseSubmitProvenancePath runDir
                        , disburseSubmitIntentPath runDir
                        , disburseSubmitTxBodyPath runDir
                        , disburseSubmitReportJsonPath runDir
                        , disburseSubmitReportMarkdownPath runDir
                        , disburseSubmitSignedTxPath runDir
                        , disburseSubmitSubmitLogPath runDir
                        ]
                removePathForcibly runDir
                createDirectoryIfMissing True (disburseSubmitDirectory runDir)
                mapM_ (`writeFile` "stale") stalePaths
                writeDisburseSubmitFailure runDir sampleFailure

                doesFileExist (disburseSubmitFailurePath runDir)
                    >>= (`shouldBe` True)
                mapM_
                    ( \path -> do
                        exists <- doesFileExist path
                        exists `shouldBe` False
                    )
                    stalePaths
                removePathForcibly runDir

        it "renders stable failure projection fields" $
            disburseSubmitFailureValue sampleRunDir sampleFailure
                `shouldBe` object
                    [ "phase" .= ("disburse-submit" :: T.Text)
                    , "status" .= ("failed" :: T.Text)
                    , "code" .= ("submit-rejected" :: T.Text)
                    , "message" .= ("node rejected tx" :: T.Text)
                    , "failedStep" .= ("submit" :: T.Text)
                    , "observedTxIds"
                        .= object
                            [ "build" .= Just sampleTxId
                            , "submitted" .= Just sampleTxId
                            ]
                    , "beneficiaryLovelace"
                        .= (Nothing :: Maybe Integer)
                    , "treasuryBeforeLovelace"
                        .= (Just 2_000_000 :: Maybe Integer)
                    , "treasuryAfterLovelace"
                        .= (Nothing :: Maybe Integer)
                    , "summaryPath" .= disburseSubmitFailurePath sampleRunDir
                    ]

sampleRunDir :: FilePath
sampleRunDir =
    "runs/devnet/sample"

commandDir :: FilePath
commandDir =
    sampleRunDir </> "disburse-submit"

sampleRegistryPath :: FilePath
sampleRegistryPath =
    sampleRunDir </> "registry-init" </> "registry.json"

sampleMaterializedPath :: FilePath
sampleMaterializedPath =
    sampleRunDir
        </> "governance-withdrawal-init"
        </> "materialized.json"

sampleTxId :: T.Text
sampleTxId =
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

sampleTreasuryInputText :: T.Text
sampleTreasuryInputText =
    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb#0"

sampleTreasuryInput :: TxIn
sampleTreasuryInput =
    parse "tx in" txInFromText sampleTreasuryInputText

sampleTreasuryOutput :: T.Text
sampleTreasuryOutput =
    sampleTxId <> "#0"

sampleBeneficiaryTxIn :: T.Text
sampleBeneficiaryTxIn =
    sampleTxId <> "#1"

sampleTreasuryHash :: T.Text
sampleTreasuryHash =
    "dddddddddddddddddddddddddddddddddddddddddddddddddddddddd"

sampleTreasuryAddress :: T.Text
sampleTreasuryAddress =
    renderAddr sampleTreasuryAddr

sampleBeneficiaryAddress :: T.Text
sampleBeneficiaryAddress =
    renderAddr sampleBeneficiaryAddr

otherAddress :: T.Text
otherAddress =
    sampleBeneficiaryAddress

sampleRegistry :: DevnetGovernanceWithdrawalRegistry
sampleRegistry =
    DevnetGovernanceWithdrawalRegistry
        { dgwrScopesRef = parseIndexedTxIn 0
        , dgwrRegistryRef = parseIndexedTxIn 1
        , dgwrPermissionsRef = parseIndexedTxIn 2
        , dgwrTreasuryRef = parseIndexedTxIn 3
        , dgwrRegistryPolicyId = sampleTreasuryHash
        , dgwrPermissionsScriptHashText = sampleTreasuryHash
        , dgwrPermissionsScriptHash = sampleScriptHash
        , dgwrTreasuryScriptHashText = sampleTreasuryHash
        , dgwrTreasuryScriptHash = sampleScriptHash
        , dgwrTreasuryAddressText = sampleTreasuryAddress
        , dgwrTreasuryAddress = sampleTreasuryAddr
        , dgwrOwnerKeyHash = sampleTreasuryHash
        }

sampleMaterialized :: DevnetDisburseSubmitMaterialized
sampleMaterialized =
    DevnetDisburseSubmitMaterialized
        { ddsmGovernanceActionId = sampleTxId <> "#0"
        , ddsmTreasuryRewardAccount = sampleTreasuryHash
        , ddsmSubmittedTxId = sampleTxId
        , ddsmTreasuryInputText = sampleTreasuryInputText
        , ddsmTreasuryInput = sampleTreasuryInput
        , ddsmTreasuryAddressText = sampleTreasuryAddress
        , ddsmTreasuryAddress = sampleTreasuryAddr
        , ddsmMaterializedAdaLovelace = 2_000_000
        , ddsmRegistryPath = sampleRegistryPath
        }

sampleResult :: DisburseSubmitResult
sampleResult =
    DisburseSubmitResult
        { dsrRegistryPath = sampleRegistryPath
        , dsrMaterializedPath = sampleMaterializedPath
        , dsrDisburse =
            DisburseSubmitDisburseEvidence
                { dsdeIntentPath = disburseSubmitIntentPath sampleRunDir
                , dsdeTxBodyPath = disburseSubmitTxBodyPath sampleRunDir
                , dsdeReportJsonPath =
                    disburseSubmitReportJsonPath sampleRunDir
                , dsdeReportMarkdownPath =
                    disburseSubmitReportMarkdownPath sampleRunDir
                , dsdeSignedTxPath = disburseSubmitSignedTxPath sampleRunDir
                , dsdeSubmitLogPath = disburseSubmitSubmitLogPath sampleRunDir
                , dsdeTxId = sampleTxId
                , dsdeSubmittedTxId = sampleTxId
                , dsdeAmountLovelace = 1_000_000
                , dsdeFeeLovelace = 171_000
                }
        , dsrBeneficiary =
            DisburseSubmitBeneficiaryEvidence
                { dsbeAddress = sampleBeneficiaryAddress
                , dsbeTxIn = sampleBeneficiaryTxIn
                , dsbeLovelace = 1_000_000
                }
        , dsrTreasury =
            DisburseSubmitTreasuryEvidence
                { dsteInput = sampleTreasuryInputText
                , dsteOutput = sampleTreasuryOutput
                , dsteAddress = sampleTreasuryAddress
                , dsteLovelaceBefore = 2_000_000
                , dsteLovelaceAfter = 1_000_000
                , dsteConsumed = True
                }
        }

sampleFailure :: DisburseSubmitFailure
sampleFailure =
    DisburseSubmitFailure
        { dsfCode = "submit-rejected"
        , dsfMessage = "node rejected tx"
        , dsfFailedStep = DisburseSubmitSubmit
        , dsfObservedTxIds =
            DisburseSubmitObservedTxIds
                { dsoBuild = Just sampleTxId
                , dsoSubmitted = Just sampleTxId
                }
        , dsfBeneficiaryLovelace = Nothing
        , dsfTreasuryBeforeLovelace = Just 2_000_000
        , dsfTreasuryAfterLovelace = Nothing
        }

materializedJson :: T.Text -> T.Text -> Value
materializedJson phase network =
    object
        [ "phase" .= phase
        , "network" .= network
        , "governanceActionId" .= (sampleTxId <> "#0")
        , "treasuryRewardAccount" .= sampleTreasuryHash
        , "submittedTxId" .= sampleTxId
        , "treasuryMaterializedTxIn" .= sampleTreasuryInputText
        , "treasuryAddress" .= sampleTreasuryAddress
        , "materializedAdaLovelace" .= (2_000_000 :: Integer)
        , "registryPath" .= sampleRegistryPath
        ]

sampleScriptHash :: ScriptHash
sampleScriptHash =
    parse "script hash" scriptHashFromHex sampleTreasuryHash

sampleOtherScriptHash :: ScriptHash
sampleOtherScriptHash =
    parse
        "other script hash"
        scriptHashFromHex
        "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"

sampleTreasuryAddr :: Addr
sampleTreasuryAddr =
    Addr
        Testnet
        (ScriptHashObj sampleScriptHash)
        (StakeRefBase (ScriptHashObj sampleScriptHash))

sampleBeneficiaryAddr :: Addr
sampleBeneficiaryAddr =
    Addr
        Testnet
        (ScriptHashObj sampleOtherScriptHash)
        (StakeRefBase (ScriptHashObj sampleOtherScriptHash))

parseIndexedTxIn :: Integer -> TxIn
parseIndexedTxIn ix =
    parse "tx in" txInFromText (sampleTxId <> "#" <> T.pack (show ix))

parse :: String -> (T.Text -> Either String a) -> T.Text -> a
parse label parser input =
    case parser input of
        Right ok -> ok
        Left err -> error (label <> ": " <> err)
