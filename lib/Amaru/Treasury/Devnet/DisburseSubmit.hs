{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeApplications #-}

{- |
Module      : Amaru.Treasury.Devnet.DisburseSubmit
Description : DevNet disburse submit command implementation
License     : Apache-2.0

Production-backed implementation for the DevNet disbursement proof.
The command consumes the registry-init artifact and the
governance-withdrawal-init materialization artifact, builds the normal
@disburse@ intent through @tx-build@, signs/submits the transaction, and
verifies that the #149 treasury UTxO was consumed into the beneficiary
and reduced treasury outputs.
-}
module Amaru.Treasury.Devnet.DisburseSubmit
    ( -- * Configuration
      DevnetDisburseSubmitConfig (..)

      -- * Prerequisites
    , DevnetDisburseSubmitMaterialized (..)
    , DisburseSubmitPrerequisites (..)
    , readDevnetDisburseSubmitRegistry
    , readDevnetDisburseSubmitMaterialized
    , validateDisburseSubmitInputs
    , validateDisburseSubmitPrerequisites

      -- * Result and failure types
    , DisburseSubmitDisburseEvidence (..)
    , DisburseSubmitBeneficiaryEvidence (..)
    , DisburseSubmitTreasuryEvidence (..)
    , DisburseSubmitResult (..)
    , DisburseSubmitObservedTxIds (..)
    , DisburseSubmitFailureStep (..)
    , DisburseSubmitFailure (..)

      -- * Runner
    , runDevnetDisburseSubmit

      -- * Artifacts
    , disburseSubmitDirectory
    , disburseSubmitSummaryPath
    , disburseSubmitDisbursePath
    , disburseSubmitBeneficiaryPath
    , disburseSubmitTreasuryPath
    , disburseSubmitProvenancePath
    , disburseSubmitFailurePath
    , disburseSubmitIntentPath
    , disburseSubmitTxBodyPath
    , disburseSubmitReportJsonPath
    , disburseSubmitReportMarkdownPath
    , disburseSubmitSignedTxPath
    , disburseSubmitSubmitLogPath
    , disburseSubmitSummaryValue
    , disburseSubmitDisburseValue
    , disburseSubmitBeneficiaryValue
    , disburseSubmitTreasuryValue
    , disburseSubmitProvenanceValue
    , disburseSubmitFailureValue
    , disburseSubmitCommandLines
    , disburseSubmitFailureLines
    , writeDisburseSubmitArtifactsWithLines
    , writeDisburseSubmitFailure
    ) where

import Cardano.Crypto.DSIGN.Class (SignKeyDSIGN)
import Cardano.Ledger.Address (Addr, getNetwork)
import Cardano.Ledger.Api.Tx (txIdTx)
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , addrTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.BaseTypes
    ( Network (..)
    , mkTxIxPartial
    )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Keys (DSIGN)
import Cardano.Ledger.Mary.Value
    ( MaryValue (..)
    , MultiAsset (..)
    )
import Cardano.Ledger.TxIn (TxId, TxIn (..))
import Cardano.Node.Client.Provider
    ( LedgerSnapshot (..)
    , Provider (..)
    )
import Cardano.Node.Client.Submitter
    ( SubmitResult (..)
    , Submitter (..)
    )
import Cardano.Slotting.Slot (SlotNo (..))
import Control.Concurrent (threadDelay)
import Control.Exception (try)
import Control.Monad (unless, when)
import Data.Aeson
    ( FromJSON (..)
    , Value
    , eitherDecodeFileStrict
    , encode
    , object
    , withObject
    , (.:)
    , (.=)
    )
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as BSL
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Data.Word (Word64)
import Lens.Micro ((^.))
import System.Directory
    ( createDirectoryIfMissing
    , doesFileExist
    , removeFile
    )
import System.Exit (ExitCode (..))
import System.FilePath ((</>))

import Amaru.Treasury.Cli.TxBuild qualified as TxBuild
import Amaru.Treasury.Devnet.GovernanceWithdrawalInit
    ( DevnetGovernanceWithdrawalRegistry (..)
    , readDevnetGovernanceWithdrawalRegistry
    , renderAddr
    )
import Amaru.Treasury.IntentJSON
    ( DisburseInputs (..)
    , RationaleJSON (..)
    , SAction (..)
    , ScopeJSON (..)
    , SomeTreasuryIntent (..)
    , TreasuryIntent (..)
    , WalletJSON (..)
    , encodeSomeTreasuryIntent
    )
import Amaru.Treasury.IntentJSON.Common
    ( parseAddr
    )
import Amaru.Treasury.LedgerParse
    ( txInFromText
    )
import Amaru.Treasury.Report qualified as Report
import Amaru.Treasury.Report.Render qualified as ReportRender
import Amaru.Treasury.Scope
    ( ScopeId (CoreDevelopment)
    , scopeText
    )
import Amaru.Treasury.Tx.AttachWitness
    ( decodeUnsignedTxHex
    , encodeSignedTxHex
    , renderAttachError
    )
import Amaru.Treasury.Tx.Submit
    ( renderTxId
    )
import Amaru.Treasury.Tx.SwapWizard
    ( txInToText
    )
import Amaru.Treasury.Tx.Witness
    ( addCardanoCliPaymentKeyWitness
    )

-- | Live inputs supplied by the CLI after DevNet gating.
data DevnetDisburseSubmitConfig = DevnetDisburseSubmitConfig
    { ddsicNetworkMagic :: !Int
    , ddsicSocketPath :: !FilePath
    , ddsicFundingAddress :: !Addr
    , ddsicSigningKey :: !(SignKeyDSIGN DSIGN)
    , ddsicBeneficiaryAddress :: !Addr
    , ddsicRunDir :: !FilePath
    , ddsicAmountLovelace :: !Integer
    }

-- | Projection consumed from #149 @materialized.json@.
data DevnetDisburseSubmitMaterialized = DevnetDisburseSubmitMaterialized
    { ddsmGovernanceActionId :: !T.Text
    , ddsmTreasuryRewardAccount :: !T.Text
    , ddsmSubmittedTxId :: !T.Text
    , ddsmTreasuryInputText :: !T.Text
    , ddsmTreasuryInput :: !TxIn
    , ddsmTreasuryAddressText :: !T.Text
    , ddsmTreasuryAddress :: !Addr
    , ddsmMaterializedAdaLovelace :: !Integer
    , ddsmRegistryPath :: !FilePath
    }
    deriving stock (Eq, Show)

instance FromJSON DevnetDisburseSubmitMaterialized where
    parseJSON =
        withObject "DevnetDisburseSubmitMaterialized" $ \o -> do
            phase <- o .: "phase"
            network <- o .: "network"
            unless (phase == ("governance-withdrawal-init" :: T.Text)) $
                fail "expected governance-withdrawal-init phase"
            unless (network == ("devnet" :: T.Text)) $
                fail "expected devnet materialized treasury input"
            treasuryInputText <- o .: "treasuryMaterializedTxIn"
            treasuryAddressText <- o .: "treasuryAddress"
            treasuryInput <-
                parseEitherText
                    "treasuryMaterializedTxIn"
                    txInFromText
                    treasuryInputText
            treasuryAddress <-
                parseEitherText "treasuryAddress" parseAddr treasuryAddressText
            unless (getNetwork treasuryAddress == Testnet) $
                fail "treasuryAddress: expected testnet address"
            materializedAda <- o .: "materializedAdaLovelace"
            unless (materializedAda > (0 :: Integer)) $
                fail "materializedAdaLovelace must be positive"
            DevnetDisburseSubmitMaterialized
                <$> o .: "governanceActionId"
                <*> o .: "treasuryRewardAccount"
                <*> o .: "submittedTxId"
                <*> pure treasuryInputText
                <*> pure treasuryInput
                <*> pure treasuryAddressText
                <*> pure treasuryAddress
                <*> pure materializedAda
                <*> o .: "registryPath"

-- | Validated handoff from #147 and #149.
data DisburseSubmitPrerequisites = DisburseSubmitPrerequisites
    { ddspRegistry :: !DevnetGovernanceWithdrawalRegistry
    , ddspMaterialized :: !DevnetDisburseSubmitMaterialized
    , ddspTreasuryInput :: !TxIn
    , ddspTreasuryBeforeLovelace :: !Integer
    , ddspTreasuryLeftoverLovelace :: !Integer
    }
    deriving stock (Eq, Show)

readDevnetDisburseSubmitRegistry
    :: FilePath -> IO (Either String DevnetGovernanceWithdrawalRegistry)
readDevnetDisburseSubmitRegistry =
    readDevnetGovernanceWithdrawalRegistry

readDevnetDisburseSubmitMaterialized
    :: FilePath -> IO (Either String DevnetDisburseSubmitMaterialized)
readDevnetDisburseSubmitMaterialized =
    eitherDecodeFileStrict

-- | Validate scalar inputs before file/key/socket effects.
validateDisburseSubmitInputs
    :: Integer -> Either DisburseSubmitFailure ()
validateDisburseSubmitInputs amountLovelace
    | amountLovelace <= 0 =
        Left
            ( inputValidationFailure
                "amount-lovelace-non-positive"
                "--amount-lovelace must be greater than 0"
            )
    | otherwise =
        Right ()

-- | Validate the #147/#149 DevNet handoff for ADA disbursement.
validateDisburseSubmitPrerequisites
    :: FilePath
    -> Integer
    -> DevnetGovernanceWithdrawalRegistry
    -> DevnetDisburseSubmitMaterialized
    -> Either DisburseSubmitFailure DisburseSubmitPrerequisites
validateDisburseSubmitPrerequisites
    _registryPath
    amountLovelace
    registry
    materialized = do
        validateDisburseSubmitInputs amountLovelace
        when
            (ddsmTreasuryAddress materialized /= dgwrTreasuryAddress registry)
            $ inputFailure
                "treasury-address-mismatch"
                "materialized treasury address does not match registry treasury address"
        when
            ( ddsmTreasuryRewardAccount materialized
                /= dgwrTreasuryScriptHashText registry
            )
            $ inputFailure
                "treasury-reward-account-mismatch"
                "materialized treasury reward account does not match registry treasury script hash"
        let before =
                ddsmMaterializedAdaLovelace materialized
            leftover =
                before - amountLovelace
        unless (leftover > 0) $
            inputFailure
                "treasury-amount-insufficient"
                "--amount-lovelace must leave a positive treasury leftover"
        Right
            DisburseSubmitPrerequisites
                { ddspRegistry = registry
                , ddspMaterialized = materialized
                , ddspTreasuryInput = ddsmTreasuryInput materialized
                , ddspTreasuryBeforeLovelace = before
                , ddspTreasuryLeftoverLovelace = leftover
                }
      where
        inputFailure code message =
            Left
                DisburseSubmitFailure
                    { dsfCode = code
                    , dsfMessage = message
                    , dsfFailedStep = DisburseSubmitValidateInputs
                    , dsfObservedTxIds = emptyObservedTxIds
                    , dsfBeneficiaryLovelace = Nothing
                    , dsfTreasuryBeforeLovelace = Nothing
                    , dsfTreasuryAfterLovelace = Nothing
                    }

data DisburseSubmitDisburseEvidence = DisburseSubmitDisburseEvidence
    { dsdeIntentPath :: !FilePath
    , dsdeTxBodyPath :: !FilePath
    , dsdeReportJsonPath :: !FilePath
    , dsdeReportMarkdownPath :: !FilePath
    , dsdeSignedTxPath :: !FilePath
    , dsdeSubmitLogPath :: !FilePath
    , dsdeTxId :: !T.Text
    , dsdeSubmittedTxId :: !T.Text
    , dsdeAmountLovelace :: !Integer
    , dsdeFeeLovelace :: !Integer
    }
    deriving stock (Eq, Show)

data DisburseSubmitBeneficiaryEvidence = DisburseSubmitBeneficiaryEvidence
    { dsbeAddress :: !T.Text
    , dsbeTxIn :: !T.Text
    , dsbeLovelace :: !Integer
    }
    deriving stock (Eq, Show)

data DisburseSubmitTreasuryEvidence = DisburseSubmitTreasuryEvidence
    { dsteInput :: !T.Text
    , dsteOutput :: !T.Text
    , dsteAddress :: !T.Text
    , dsteLovelaceBefore :: !Integer
    , dsteLovelaceAfter :: !Integer
    , dsteConsumed :: !Bool
    }
    deriving stock (Eq, Show)

data DisburseSubmitResult = DisburseSubmitResult
    { dsrRegistryPath :: !FilePath
    , dsrMaterializedPath :: !FilePath
    , dsrDisburse :: !DisburseSubmitDisburseEvidence
    , dsrBeneficiary :: !DisburseSubmitBeneficiaryEvidence
    , dsrTreasury :: !DisburseSubmitTreasuryEvidence
    }
    deriving stock (Eq, Show)

data DisburseSubmitObservedTxIds = DisburseSubmitObservedTxIds
    { dsoBuild :: !(Maybe T.Text)
    , dsoSubmitted :: !(Maybe T.Text)
    }
    deriving stock (Eq, Show)

data DisburseSubmitFailureStep
    = DisburseSubmitValidateInputs
    | DisburseSubmitBuildIntent
    | DisburseSubmitBuild
    | DisburseSubmitSubmit
    | DisburseSubmitVerify
    deriving stock (Eq, Show)

data DisburseSubmitFailure = DisburseSubmitFailure
    { dsfCode :: !T.Text
    , dsfMessage :: !T.Text
    , dsfFailedStep :: !DisburseSubmitFailureStep
    , dsfObservedTxIds :: !DisburseSubmitObservedTxIds
    , dsfBeneficiaryLovelace :: !(Maybe Integer)
    , dsfTreasuryBeforeLovelace :: !(Maybe Integer)
    , dsfTreasuryAfterLovelace :: !(Maybe Integer)
    }
    deriving stock (Eq, Show)

-- | Execute the command-owned DevNet flow and write artifacts.
runDevnetDisburseSubmit
    :: DevnetDisburseSubmitConfig
    -> FilePath
    -> FilePath
    -> DisburseSubmitPrerequisites
    -> Provider IO
    -> Submitter IO
    -> IO (Either DisburseSubmitFailure DisburseSubmitResult)
runDevnetDisburseSubmit
    config@DevnetDisburseSubmitConfig{..}
    registryPath
    materializedPath
    prereqs
    provider
    submitter = do
        createDirectoryIfMissing True (disburseSubmitDirectory ddsicRunDir)
        removeSuccessSummaries ddsicRunDir
        buildDisburseIntent config prereqs provider >>= \case
            Left failure -> failAndReturn failure
            Right () ->
                buildDisburseTransaction config prereqs >>= \case
                    Left failure -> failAndReturn failure
                    Right success ->
                        signSubmitAndVerifyDisburse
                            config
                            registryPath
                            materializedPath
                            prereqs
                            provider
                            submitter
                            success
                            >>= \case
                                Left failure -> failAndReturn failure
                                Right result -> do
                                    let linesOut =
                                            disburseSubmitCommandLines
                                                ddsicNetworkMagic
                                                ddsicRunDir
                                                result
                                    writeDisburseSubmitArtifactsWithLines
                                        ddsicNetworkMagic
                                        ddsicRunDir
                                        result
                                        linesOut
                                    pure (Right result)
      where
        failAndReturn failure = do
            writeDisburseSubmitFailure ddsicRunDir failure
            pure (Left failure)

buildDisburseIntent
    :: DevnetDisburseSubmitConfig
    -> DisburseSubmitPrerequisites
    -> Provider IO
    -> IO (Either DisburseSubmitFailure ())
buildDisburseIntent
    DevnetDisburseSubmitConfig{..}
    prereqs@DisburseSubmitPrerequisites{ddspRegistry = registry}
    provider = do
        fundingUtxos <- queryUTxOs provider ddsicFundingAddress
        case selectLargestAdaUtxo fundingUtxos of
            Nothing ->
                pure . Left $
                    DisburseSubmitFailure
                        { dsfCode = "wallet-utxo-missing"
                        , dsfMessage =
                            "no pure-ADA funding UTxO available for disburse submit"
                        , dsfFailedStep = DisburseSubmitBuildIntent
                        , dsfObservedTxIds = emptyObservedTxIds
                        , dsfBeneficiaryLovelace = Nothing
                        , dsfTreasuryBeforeLovelace =
                            Just (ddspTreasuryBeforeLovelace prereqs)
                        , dsfTreasuryAfterLovelace = Nothing
                        }
            Just (walletTxIn, _) -> do
                snapshot <- queryLedgerSnapshot provider
                let intent =
                        mkDisburseIntent
                            ddsicFundingAddress
                            ddsicBeneficiaryAddress
                            ddsicAmountLovelace
                            walletTxIn
                            registry
                            prereqs
                            (slotNumber (addSlots 20 (ledgerTipSlot snapshot)))
                BSL.writeFile
                    (disburseSubmitIntentPath ddsicRunDir)
                    (encodeSomeTreasuryIntent intent)
                pure (Right ())

mkDisburseIntent
    :: Addr
    -> Addr
    -> Integer
    -> TxIn
    -> DevnetGovernanceWithdrawalRegistry
    -> DisburseSubmitPrerequisites
    -> Word64
    -> SomeTreasuryIntent
mkDisburseIntent
    fundingAddress
    beneficiaryAddress
    amountLovelace
    walletTxIn
    registry
    prereqs
    upperBound =
        SomeTreasuryIntent SDisburse $
            TreasuryIntent
                { tiSAction = SDisburse
                , tiSchema = 1
                , tiNetwork = "devnet"
                , tiWallet =
                    WalletJSON
                        { wjTxIn = txInToText walletTxIn
                        , wjAddress = renderAddr fundingAddress
                        , wjExtraTxIns = []
                        }
                , tiScope =
                    ScopeJSON
                        { sjId = scopeText CoreDevelopment
                        , sjTreasuryAddress =
                            dgwrTreasuryAddressText registry
                        , sjTreasuryUtxos =
                            [txInToText (ddspTreasuryInput prereqs)]
                        , sjTreasuryLeftoverLovelace =
                            ddspTreasuryLeftoverLovelace prereqs
                        , sjTreasuryLeftoverUsdm = 0
                        , sjTreasuryLeftoverOtherAssets = mempty
                        , sjTreasuryScriptHash =
                            dgwrTreasuryScriptHashText registry
                        , sjPermissionsRewardAccount =
                            dgwrPermissionsScriptHashText registry
                        , sjScopesDeployedAt =
                            txInToText (dgwrScopesRef registry)
                        , sjPermissionsDeployedAt =
                            txInToText (dgwrPermissionsRef registry)
                        , sjTreasuryDeployedAt =
                            txInToText (dgwrTreasuryRef registry)
                        , sjRegistryDeployedAt =
                            txInToText (dgwrRegistryRef registry)
                        , sjRegistryPolicyId =
                            dgwrRegistryPolicyId registry
                        }
                , tiSigners = [dgwrOwnerKeyHash registry]
                , tiValidityUpperBoundSlot = upperBound
                , tiRationale =
                    RationaleJSON
                        { rjEvent = "devnet-disburse-submit"
                        , rjLabel = "DevNet disburse submit"
                        , rjDescription =
                            "Submit DevNet ADA disbursement proof"
                        , rjJustification =
                            "Issue #150 command recovery proof"
                        , rjDestinationLabel = "DevNet beneficiary"
                        }
                , tiPayload =
                    DisburseInputs
                        { diUnit = "ada"
                        , diAmount = amountLovelace
                        , diBeneficiaryAddress = renderAddr beneficiaryAddress
                        , diUsdmPolicy = ""
                        , diUsdmToken = ""
                        }
                }

buildDisburseTransaction
    :: DevnetDisburseSubmitConfig
    -> DisburseSubmitPrerequisites
    -> IO (Either DisburseSubmitFailure Report.TxBuildSuccess)
buildDisburseTransaction
    DevnetDisburseSubmitConfig{..}
    prereqs = do
        buildExit <-
            try @ExitCode $
                TxBuild.runTxBuild
                    ddsicSocketPath
                    TxBuild.TxBuildOpts
                        { TxBuild.tboIntentPath =
                            Just (disburseSubmitIntentPath ddsicRunDir)
                        , TxBuild.tboOutPath =
                            Just (disburseSubmitTxBodyPath ddsicRunDir)
                        , TxBuild.tboLog = Nothing
                        , TxBuild.tboReportPath =
                            Just (disburseSubmitReportJsonPath ddsicRunDir)
                        }
        case buildExit of
            Left exitCode -> do
                txBuildFailure <- readDisburseTxBuildFailure ddsicRunDir
                pure . Left $
                    DisburseSubmitFailure
                        { dsfCode = "tx-build-failed"
                        , dsfMessage =
                            "tx-build exited with "
                                <> T.pack (show exitCode)
                                <> maybe
                                    ""
                                    ( \failureReport ->
                                        ": "
                                            <> Report.bfCode failureReport
                                            <> ": "
                                            <> Report.bfMessage failureReport
                                    )
                                    txBuildFailure
                        , dsfFailedStep = DisburseSubmitBuild
                        , dsfObservedTxIds = emptyObservedTxIds
                        , dsfBeneficiaryLovelace = Nothing
                        , dsfTreasuryBeforeLovelace =
                            Just (ddspTreasuryBeforeLovelace prereqs)
                        , dsfTreasuryAfterLovelace = Nothing
                        }
            Right () -> do
                buildOutput <-
                    eitherDecodeFileStrict
                        @Report.TxBuildOutput
                        (disburseSubmitReportJsonPath ddsicRunDir)
                case buildOutput of
                    Left err ->
                        pure . Left $
                            DisburseSubmitFailure
                                { dsfCode = "tx-build-report-decode-failed"
                                , dsfMessage =
                                    "failed to decode tx-build report: "
                                        <> T.pack err
                                , dsfFailedStep = DisburseSubmitBuild
                                , dsfObservedTxIds = emptyObservedTxIds
                                , dsfBeneficiaryLovelace = Nothing
                                , dsfTreasuryBeforeLovelace =
                                    Just
                                        ( ddspTreasuryBeforeLovelace
                                            prereqs
                                        )
                                , dsfTreasuryAfterLovelace = Nothing
                                }
                    Right output ->
                        case Report.txoResult output of
                            Report.TxBuildOutputFailure failureReport ->
                                pure . Left $
                                    DisburseSubmitFailure
                                        { dsfCode = "tx-build-failed"
                                        , dsfMessage =
                                            Report.bfCode failureReport
                                                <> ": "
                                                <> Report.bfMessage
                                                    failureReport
                                        , dsfFailedStep = DisburseSubmitBuild
                                        , dsfObservedTxIds = emptyObservedTxIds
                                        , dsfBeneficiaryLovelace = Nothing
                                        , dsfTreasuryBeforeLovelace =
                                            Just
                                                ( ddspTreasuryBeforeLovelace
                                                    prereqs
                                                )
                                        , dsfTreasuryAfterLovelace = Nothing
                                        }
                            Report.TxBuildOutputSuccess success -> do
                                case ReportRender.renderBuildOutput output of
                                    Left err ->
                                        pure . Left $
                                            DisburseSubmitFailure
                                                { dsfCode =
                                                    "report-render-failed"
                                                , dsfMessage =
                                                    "failed to render disburse report: "
                                                        <> T.pack (show err)
                                                , dsfFailedStep =
                                                    DisburseSubmitBuild
                                                , dsfObservedTxIds =
                                                    observedTxIds
                                                        (Just (txId success))
                                                        Nothing
                                                , dsfBeneficiaryLovelace =
                                                    Nothing
                                                , dsfTreasuryBeforeLovelace =
                                                    Just
                                                        ( ddspTreasuryBeforeLovelace
                                                            prereqs
                                                        )
                                                , dsfTreasuryAfterLovelace =
                                                    Nothing
                                                }
                                    Right render -> do
                                        TIO.writeFile
                                            ( disburseSubmitReportMarkdownPath
                                                ddsicRunDir
                                            )
                                            (ReportRender.unRenderOutput render)
                                        pure (Right success)
      where
        txId success =
            Report.tiTxId (Report.trIdentity (Report.tbsReport success))

signSubmitAndVerifyDisburse
    :: DevnetDisburseSubmitConfig
    -> FilePath
    -> FilePath
    -> DisburseSubmitPrerequisites
    -> Provider IO
    -> Submitter IO
    -> Report.TxBuildSuccess
    -> IO (Either DisburseSubmitFailure DisburseSubmitResult)
signSubmitAndVerifyDisburse
    DevnetDisburseSubmitConfig{..}
    registryPath
    materializedPath
    prereqs@DisburseSubmitPrerequisites{ddspRegistry = registry}
    provider
    submitter
    success = do
        txHex <- BS.readFile (disburseSubmitTxBodyPath ddsicRunDir)
        case decodeUnsignedTxHex txHex of
            Left err ->
                pure . Left $
                    DisburseSubmitFailure
                        { dsfCode = "disburse-tx-decode-failed"
                        , dsfMessage =
                            "decode disburse tx before signing: "
                                <> renderAttachError err
                        , dsfFailedStep = DisburseSubmitSubmit
                        , dsfObservedTxIds =
                            observedTxIds (Just expectedTxId) Nothing
                        , dsfBeneficiaryLovelace = Nothing
                        , dsfTreasuryBeforeLovelace =
                            Just (ddspTreasuryBeforeLovelace prereqs)
                        , dsfTreasuryAfterLovelace = Nothing
                        }
            Right tx -> do
                let signed =
                        addCardanoCliPaymentKeyWitness ddsicSigningKey tx
                    submittedTxId =
                        txIdTx signed
                    submittedTxIdText =
                        renderTxId submittedTxId
                    observed =
                        observedTxIds
                            (Just expectedTxId)
                            (Just submittedTxIdText)
                if expectedTxId /= submittedTxIdText
                    then
                        pure . Left $
                            DisburseSubmitFailure
                                { dsfCode = "disburse-tx-id-mismatch"
                                , dsfMessage =
                                    "signed disburse tx id "
                                        <> submittedTxIdText
                                        <> " does not match tx-build report "
                                        <> expectedTxId
                                , dsfFailedStep = DisburseSubmitSubmit
                                , dsfObservedTxIds = observed
                                , dsfBeneficiaryLovelace = Nothing
                                , dsfTreasuryBeforeLovelace =
                                    Just
                                        ( ddspTreasuryBeforeLovelace
                                            prereqs
                                        )
                                , dsfTreasuryAfterLovelace = Nothing
                                }
                    else do
                        verifyTreasuryInputBefore
                            provider
                            registry
                            prereqs
                            observed
                            >>= \case
                                Left failure -> pure (Left failure)
                                Right treasuryBefore -> do
                                    BS.writeFile
                                        (disburseSubmitSignedTxPath ddsicRunDir)
                                        (encodeSignedTxHex signed)
                                    submitTx submitter signed >>= \case
                                        Rejected reason ->
                                            pure . Left $
                                                DisburseSubmitFailure
                                                    { dsfCode =
                                                        "submit-rejected"
                                                    , dsfMessage =
                                                        "node rejected tx: "
                                                            <> decodeUtf8Lenient
                                                                reason
                                                    , dsfFailedStep =
                                                        DisburseSubmitSubmit
                                                    , dsfObservedTxIds =
                                                        observed
                                                    , dsfBeneficiaryLovelace =
                                                        Nothing
                                                    , dsfTreasuryBeforeLovelace =
                                                        Just treasuryBefore
                                                    , dsfTreasuryAfterLovelace =
                                                        Nothing
                                                    }
                                        Submitted _ -> do
                                            writeFile
                                                ( disburseSubmitSubmitLogPath
                                                    ddsicRunDir
                                                )
                                                ( "submit: accepted "
                                                    <> T.unpack
                                                        submittedTxIdText
                                                    <> "\n"
                                                )
                                            verifySubmittedDisburse
                                                ddsicRunDir
                                                registryPath
                                                materializedPath
                                                registry
                                                prereqs
                                                ddsicBeneficiaryAddress
                                                ddsicAmountLovelace
                                                provider
                                                success
                                                submittedTxId
                                                submittedTxIdText
                                                treasuryBefore
      where
        identity =
            Report.trIdentity (Report.tbsReport success)
        expectedTxId =
            Report.tiTxId identity

verifyTreasuryInputBefore
    :: Provider IO
    -> DevnetGovernanceWithdrawalRegistry
    -> DisburseSubmitPrerequisites
    -> DisburseSubmitObservedTxIds
    -> IO (Either DisburseSubmitFailure Integer)
verifyTreasuryInputBefore
    provider
    registry
    prereqs
    observed = do
        utxos <-
            queryUTxOByTxIn provider (Set.singleton (ddspTreasuryInput prereqs))
        case Map.lookup (ddspTreasuryInput prereqs) utxos of
            Nothing ->
                pure $
                    verifyFailure
                        "treasury-input-missing"
                        "materialized treasury input is not live before submit"
                        Nothing
                        Nothing
            Just txOut
                | txOut ^. addrTxOutL /= dgwrTreasuryAddress registry ->
                    pure $
                        verifyFailure
                            "treasury-input-address-mismatch"
                            "live treasury input address does not match registry"
                            Nothing
                            Nothing
                | txOutHasAssets txOut ->
                    pure $
                        verifyFailure
                            "treasury-input-assets-present"
                            "ADA-only disburse input unexpectedly carries native assets"
                            Nothing
                            Nothing
                | txOutLovelace txOut
                    /= ddspTreasuryBeforeLovelace prereqs ->
                    pure $
                        verifyFailure
                            "treasury-input-lovelace-mismatch"
                            "live treasury input lovelace does not match materialized artifact"
                            (Just (txOutLovelace txOut))
                            Nothing
                | otherwise ->
                    pure (Right (txOutLovelace txOut))
      where
        verifyFailure code message before after =
            Left
                DisburseSubmitFailure
                    { dsfCode = code
                    , dsfMessage = message
                    , dsfFailedStep = DisburseSubmitVerify
                    , dsfObservedTxIds = observed
                    , dsfBeneficiaryLovelace = Nothing
                    , dsfTreasuryBeforeLovelace = before
                    , dsfTreasuryAfterLovelace = after
                    }

verifySubmittedDisburse
    :: FilePath
    -> FilePath
    -> FilePath
    -> DevnetGovernanceWithdrawalRegistry
    -> DisburseSubmitPrerequisites
    -> Addr
    -> Integer
    -> Provider IO
    -> Report.TxBuildSuccess
    -> TxId
    -> T.Text
    -> Integer
    -> IO (Either DisburseSubmitFailure DisburseSubmitResult)
verifySubmittedDisburse
    runDir
    registryPath
    materializedPath
    registry
    prereqs
    beneficiaryAddress
    amountLovelace
    provider
    success
    submittedTxId
    submittedTxIdText
    treasuryBefore = do
        let observed =
                observedTxIds
                    (Just (Report.tiTxId identity))
                    (Just submittedTxIdText)
            treasuryInput =
                ddspTreasuryInput prereqs
            treasuryOutput =
                txOutRef submittedTxId 0
            beneficiaryOutput =
                txOutRef submittedTxId 1
            expectedTreasuryAfter =
                treasuryBefore - amountLovelace
            failVerify code message beneficiaryLov treasuryAfter =
                Left
                    DisburseSubmitFailure
                        { dsfCode = code
                        , dsfMessage = message
                        , dsfFailedStep = DisburseSubmitVerify
                        , dsfObservedTxIds = observed
                        , dsfBeneficiaryLovelace = beneficiaryLov
                        , dsfTreasuryBeforeLovelace = Just treasuryBefore
                        , dsfTreasuryAfterLovelace = treasuryAfter
                        }
        inputSpent <- waitForSpentTxIn provider treasuryInput 60
        if not inputSpent
            then
                pure $
                    failVerify
                        "treasury-input-not-consumed"
                        "materialized treasury input was not consumed"
                        Nothing
                        Nothing
            else do
                treasuryOut <- waitForTxOut provider treasuryOutput 60
                beneficiaryOut <- waitForTxOut provider beneficiaryOutput 60
                case (treasuryOut, beneficiaryOut) of
                    (Nothing, _) ->
                        pure $
                            failVerify
                                "treasury-output-missing"
                                "submitted disburse treasury output was not observed"
                                Nothing
                                Nothing
                    (_, Nothing) ->
                        pure $
                            failVerify
                                "beneficiary-output-missing"
                                "submitted disburse beneficiary output was not observed"
                                Nothing
                                Nothing
                    (Just treasuryTxOut, Just beneficiaryTxOut)
                        | treasuryTxOut ^. addrTxOutL
                            /= dgwrTreasuryAddress registry ->
                            pure $
                                failVerify
                                    "treasury-output-address-mismatch"
                                    "submitted treasury output address does not match registry"
                                    (Just (txOutLovelace beneficiaryTxOut))
                                    (Just (txOutLovelace treasuryTxOut))
                        | txOutLovelace treasuryTxOut
                            /= expectedTreasuryAfter ->
                            pure $
                                failVerify
                                    "treasury-output-lovelace-mismatch"
                                    "submitted treasury output lovelace does not match expected leftover"
                                    (Just (txOutLovelace beneficiaryTxOut))
                                    (Just (txOutLovelace treasuryTxOut))
                        | txOutHasAssets treasuryTxOut ->
                            pure $
                                failVerify
                                    "treasury-output-assets-present"
                                    "ADA-only treasury output unexpectedly carries native assets"
                                    (Just (txOutLovelace beneficiaryTxOut))
                                    (Just (txOutLovelace treasuryTxOut))
                        | beneficiaryTxOut ^. addrTxOutL /= beneficiaryAddress ->
                            pure $
                                failVerify
                                    "beneficiary-output-address-mismatch"
                                    "submitted beneficiary output address does not match requested beneficiary"
                                    (Just (txOutLovelace beneficiaryTxOut))
                                    (Just (txOutLovelace treasuryTxOut))
                        | txOutLovelace beneficiaryTxOut /= amountLovelace ->
                            pure $
                                failVerify
                                    "beneficiary-output-lovelace-mismatch"
                                    "submitted beneficiary output lovelace does not match requested amount"
                                    (Just (txOutLovelace beneficiaryTxOut))
                                    (Just (txOutLovelace treasuryTxOut))
                        | txOutHasAssets beneficiaryTxOut ->
                            pure $
                                failVerify
                                    "beneficiary-output-assets-present"
                                    "ADA-only beneficiary output unexpectedly carries native assets"
                                    (Just (txOutLovelace beneficiaryTxOut))
                                    (Just (txOutLovelace treasuryTxOut))
                        | otherwise -> do
                            let disburse =
                                    DisburseSubmitDisburseEvidence
                                        { dsdeIntentPath =
                                            disburseSubmitIntentPath runDir
                                        , dsdeTxBodyPath =
                                            disburseSubmitTxBodyPath runDir
                                        , dsdeReportJsonPath =
                                            disburseSubmitReportJsonPath runDir
                                        , dsdeReportMarkdownPath =
                                            disburseSubmitReportMarkdownPath
                                                runDir
                                        , dsdeSignedTxPath =
                                            disburseSubmitSignedTxPath runDir
                                        , dsdeSubmitLogPath =
                                            disburseSubmitSubmitLogPath runDir
                                        , dsdeTxId = Report.tiTxId identity
                                        , dsdeSubmittedTxId = submittedTxIdText
                                        , dsdeAmountLovelace = amountLovelace
                                        , dsdeFeeLovelace =
                                            Report.tiFeeLovelace identity
                                        }
                                beneficiary =
                                    DisburseSubmitBeneficiaryEvidence
                                        { dsbeAddress =
                                            renderAddr beneficiaryAddress
                                        , dsbeTxIn =
                                            txInToText beneficiaryOutput
                                        , dsbeLovelace =
                                            txOutLovelace beneficiaryTxOut
                                        }
                                treasury =
                                    DisburseSubmitTreasuryEvidence
                                        { dsteInput = txInToText treasuryInput
                                        , dsteOutput =
                                            txInToText treasuryOutput
                                        , dsteAddress =
                                            dgwrTreasuryAddressText registry
                                        , dsteLovelaceBefore = treasuryBefore
                                        , dsteLovelaceAfter =
                                            txOutLovelace treasuryTxOut
                                        , dsteConsumed = True
                                        }
                            pure . Right $
                                DisburseSubmitResult
                                    { dsrRegistryPath = registryPath
                                    , dsrMaterializedPath = materializedPath
                                    , dsrDisburse = disburse
                                    , dsrBeneficiary = beneficiary
                                    , dsrTreasury = treasury
                                    }
      where
        identity =
            Report.trIdentity (Report.tbsReport success)

disburseSubmitDirectory :: FilePath -> FilePath
disburseSubmitDirectory runDir =
    runDir </> "disburse-submit"

disburseSubmitSummaryPath :: FilePath -> FilePath
disburseSubmitSummaryPath runDir =
    disburseSubmitDirectory runDir </> "summary.json"

disburseSubmitDisbursePath :: FilePath -> FilePath
disburseSubmitDisbursePath runDir =
    disburseSubmitDirectory runDir </> "disburse.json"

disburseSubmitBeneficiaryPath :: FilePath -> FilePath
disburseSubmitBeneficiaryPath runDir =
    disburseSubmitDirectory runDir </> "beneficiary.json"

disburseSubmitTreasuryPath :: FilePath -> FilePath
disburseSubmitTreasuryPath runDir =
    disburseSubmitDirectory runDir </> "treasury.json"

disburseSubmitProvenancePath :: FilePath -> FilePath
disburseSubmitProvenancePath runDir =
    disburseSubmitDirectory runDir </> "provenance.json"

disburseSubmitFailurePath :: FilePath -> FilePath
disburseSubmitFailurePath runDir =
    disburseSubmitDirectory runDir </> "failure.json"

disburseSubmitIntentPath :: FilePath -> FilePath
disburseSubmitIntentPath runDir =
    disburseSubmitDirectory runDir </> "intent.json"

disburseSubmitTxBodyPath :: FilePath -> FilePath
disburseSubmitTxBodyPath runDir =
    disburseSubmitDirectory runDir </> "tx-body.cbor.hex"

disburseSubmitReportJsonPath :: FilePath -> FilePath
disburseSubmitReportJsonPath runDir =
    disburseSubmitDirectory runDir </> "report.json"

disburseSubmitReportMarkdownPath :: FilePath -> FilePath
disburseSubmitReportMarkdownPath runDir =
    disburseSubmitDirectory runDir </> "report.md"

disburseSubmitSignedTxPath :: FilePath -> FilePath
disburseSubmitSignedTxPath runDir =
    disburseSubmitDirectory runDir </> "signed-tx.cbor.hex"

disburseSubmitSubmitLogPath :: FilePath -> FilePath
disburseSubmitSubmitLogPath runDir =
    disburseSubmitDirectory runDir </> "submit.log"

disburseSubmitSummaryValue
    :: Int -> FilePath -> DisburseSubmitResult -> Value
disburseSubmitSummaryValue networkMagic runDir result =
    object
        [ "phase" .= ("disburse-submit" :: T.Text)
        , "status" .= ("passed" :: T.Text)
        , "network" .= ("devnet" :: T.Text)
        , "networkMagic" .= networkMagic
        , "runDirectory" .= runDir
        , "registryPath" .= dsrRegistryPath result
        , "materializedPath" .= dsrMaterializedPath result
        , "amountLovelace" .= dsdeAmountLovelace (dsrDisburse result)
        , "disbursePath" .= disburseSubmitDisbursePath runDir
        , "beneficiaryPath" .= disburseSubmitBeneficiaryPath runDir
        , "treasuryPath" .= disburseSubmitTreasuryPath runDir
        , "provenancePath" .= disburseSubmitProvenancePath runDir
        ]

disburseSubmitDisburseValue :: DisburseSubmitResult -> Value
disburseSubmitDisburseValue result =
    let d = dsrDisburse result
    in  object
            [ "phase" .= ("disburse-submit" :: T.Text)
            , "network" .= ("devnet" :: T.Text)
            , "intentPath" .= dsdeIntentPath d
            , "txBodyPath" .= dsdeTxBodyPath d
            , "reportJsonPath" .= dsdeReportJsonPath d
            , "reportMarkdownPath" .= dsdeReportMarkdownPath d
            , "signedTxPath" .= dsdeSignedTxPath d
            , "submitLogPath" .= dsdeSubmitLogPath d
            , "txId" .= dsdeTxId d
            , "submittedTxId" .= dsdeSubmittedTxId d
            , "amountLovelace" .= dsdeAmountLovelace d
            , "feeLovelace" .= dsdeFeeLovelace d
            ]

disburseSubmitBeneficiaryValue :: DisburseSubmitResult -> Value
disburseSubmitBeneficiaryValue result =
    let b = dsrBeneficiary result
    in  object
            [ "phase" .= ("disburse-submit" :: T.Text)
            , "network" .= ("devnet" :: T.Text)
            , "address" .= dsbeAddress b
            , "txIn" .= dsbeTxIn b
            , "lovelace" .= dsbeLovelace b
            ]

disburseSubmitTreasuryValue :: DisburseSubmitResult -> Value
disburseSubmitTreasuryValue result =
    let t = dsrTreasury result
    in  object
            [ "phase" .= ("disburse-submit" :: T.Text)
            , "network" .= ("devnet" :: T.Text)
            , "input" .= dsteInput t
            , "output" .= dsteOutput t
            , "address" .= dsteAddress t
            , "lovelaceBefore" .= dsteLovelaceBefore t
            , "lovelaceAfter" .= dsteLovelaceAfter t
            , "consumed" .= dsteConsumed t
            ]

disburseSubmitProvenanceValue :: Value
disburseSubmitProvenanceValue =
    object
        [ "phase" .= ("disburse-submit" :: T.Text)
        , "source" .= ("amaru-treasury-tx" :: T.Text)
        , "issue" .= (150 :: Int)
        , "parentIssue" .= (151 :: Int)
        , "dependsOnIssues" .= ([147, 149] :: [Int])
        ]

disburseSubmitFailureValue
    :: FilePath -> DisburseSubmitFailure -> Value
disburseSubmitFailureValue runDir failure' =
    object
        [ "phase" .= ("disburse-submit" :: T.Text)
        , "status" .= ("failed" :: T.Text)
        , "code" .= dsfCode failure'
        , "message" .= dsfMessage failure'
        , "failedStep" .= failureStepText (dsfFailedStep failure')
        , "observedTxIds"
            .= object
                [ "build" .= dsoBuild observed
                , "submitted" .= dsoSubmitted observed
                ]
        , "beneficiaryLovelace" .= dsfBeneficiaryLovelace failure'
        , "treasuryBeforeLovelace" .= dsfTreasuryBeforeLovelace failure'
        , "treasuryAfterLovelace" .= dsfTreasuryAfterLovelace failure'
        , "summaryPath" .= disburseSubmitFailurePath runDir
        ]
  where
    observed =
        dsfObservedTxIds failure'

disburseSubmitCommandLines
    :: Int -> FilePath -> DisburseSubmitResult -> [String]
disburseSubmitCommandLines networkMagic runDir result =
    [ "disburse-submit: run-dir " <> runDir
    , "disburse-submit: network devnet magic " <> show networkMagic
    , "disburse-submit: phase disburse-submit passed"
    , "disburse-submit: submitted-tx-id "
        <> T.unpack (dsdeSubmittedTxId disburse)
    , "disburse-submit: beneficiary-address "
        <> T.unpack (dsbeAddress beneficiary)
    , "disburse-submit: beneficiary-tx-in "
        <> T.unpack (dsbeTxIn beneficiary)
    , "disburse-submit: beneficiary-lovelace "
        <> show (dsbeLovelace beneficiary)
    , "disburse-submit: treasury-input "
        <> T.unpack (dsteInput treasury)
    , "disburse-submit: treasury-lovelace-before "
        <> show (dsteLovelaceBefore treasury)
    , "disburse-submit: treasury-lovelace-after "
        <> show (dsteLovelaceAfter treasury)
    , "disburse-submit: signed-tx "
        <> disburseSubmitSignedTxPath runDir
    , "disburse-submit: submit-log "
        <> disburseSubmitSubmitLogPath runDir
    , "disburse-submit: summary "
        <> disburseSubmitSummaryPath runDir
    ]
  where
    disburse =
        dsrDisburse result
    beneficiary =
        dsrBeneficiary result
    treasury =
        dsrTreasury result

disburseSubmitFailureLines
    :: FilePath -> DisburseSubmitFailure -> [String]
disburseSubmitFailureLines runDir failure' =
    [ "disburse-submit: run-dir " <> runDir
    , "disburse-submit: phase disburse-submit failed"
    , "disburse-submit: "
        <> T.unpack (dsfCode failure')
        <> ": "
        <> T.unpack (dsfMessage failure')
    , "disburse-submit: failure " <> disburseSubmitFailurePath runDir
    ]

writeDisburseSubmitArtifactsWithLines
    :: Int
    -> FilePath
    -> DisburseSubmitResult
    -> [String]
    -> IO ()
writeDisburseSubmitArtifactsWithLines
    networkMagic
    runDir
    result
    linesOut = do
        let summary = disburseSubmitSummaryValue networkMagic runDir result
        createDirectoryIfMissing True (disburseSubmitDirectory runDir)
        removeIfExists (disburseSubmitFailurePath runDir)
        BSL.writeFile (disburseSubmitSummaryPath runDir) (encode summary)
        BSL.writeFile
            (disburseSubmitDisbursePath runDir)
            (encode (disburseSubmitDisburseValue result))
        BSL.writeFile
            (disburseSubmitBeneficiaryPath runDir)
            (encode (disburseSubmitBeneficiaryValue result))
        BSL.writeFile
            (disburseSubmitTreasuryPath runDir)
            (encode (disburseSubmitTreasuryValue result))
        BSL.writeFile
            (disburseSubmitProvenancePath runDir)
            (encode disburseSubmitProvenanceValue)
        BSL.writeFile (runDir </> "summary.json") (encode summary)
        writeFile (runDir </> "summary.log") (unlines linesOut)

writeDisburseSubmitFailure
    :: FilePath -> DisburseSubmitFailure -> IO ()
writeDisburseSubmitFailure runDir failure' = do
    let value =
            disburseSubmitFailureValue runDir failure'
        linesOut =
            disburseSubmitFailureLines runDir failure'
    createDirectoryIfMissing True (disburseSubmitDirectory runDir)
    removeSuccessSummaries runDir
    BSL.writeFile (disburseSubmitFailurePath runDir) (encode value)
    BSL.writeFile (runDir </> "summary.json") (encode value)
    writeFile (runDir </> "summary.log") (unlines linesOut)

inputValidationFailure :: T.Text -> T.Text -> DisburseSubmitFailure
inputValidationFailure code message =
    DisburseSubmitFailure
        { dsfCode = code
        , dsfMessage = message
        , dsfFailedStep = DisburseSubmitValidateInputs
        , dsfObservedTxIds = emptyObservedTxIds
        , dsfBeneficiaryLovelace = Nothing
        , dsfTreasuryBeforeLovelace = Nothing
        , dsfTreasuryAfterLovelace = Nothing
        }

failureStepText :: DisburseSubmitFailureStep -> T.Text
failureStepText = \case
    DisburseSubmitValidateInputs -> "validate-inputs"
    DisburseSubmitBuildIntent -> "build-intent"
    DisburseSubmitBuild -> "build"
    DisburseSubmitSubmit -> "submit"
    DisburseSubmitVerify -> "verify"

observedTxIds
    :: Maybe T.Text -> Maybe T.Text -> DisburseSubmitObservedTxIds
observedTxIds build submitted =
    DisburseSubmitObservedTxIds
        { dsoBuild = build
        , dsoSubmitted = submitted
        }

emptyObservedTxIds :: DisburseSubmitObservedTxIds
emptyObservedTxIds =
    observedTxIds Nothing Nothing

removeSuccessSummaries :: FilePath -> IO ()
removeSuccessSummaries runDir =
    mapM_
        removeIfExists
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

removeIfExists :: FilePath -> IO ()
removeIfExists path = do
    exists <- doesFileExist path
    when exists (removeFile path)

readDisburseTxBuildFailure
    :: FilePath -> IO (Maybe Report.BuildFailure)
readDisburseTxBuildFailure runDir = do
    let path = disburseSubmitReportJsonPath runDir
    exists <- doesFileExist path
    if not exists
        then pure Nothing
        else do
            decoded <- eitherDecodeFileStrict @Report.TxBuildOutput path
            pure $ case decoded of
                Right buildOutput ->
                    case Report.txoResult buildOutput of
                        Report.TxBuildOutputFailure failureReport ->
                            Just failureReport
                        Report.TxBuildOutputSuccess{} ->
                            Nothing
                Left{} -> Nothing

selectLargestAdaUtxo
    :: [(TxIn, TxOut ConwayEra)] -> Maybe (TxIn, TxOut ConwayEra)
selectLargestAdaUtxo =
    fmap snd . foldr choose Nothing
  where
    choose utxo@(_, txOut) best =
        let MaryValue (Coin lovelace) (MultiAsset assets) =
                txOut ^. valueTxOutL
        in  if Map.null assets
                then case best of
                    Nothing -> Just (lovelace, utxo)
                    Just (bestLovelace, _)
                        | lovelace > bestLovelace ->
                            Just (lovelace, utxo)
                    _ -> best
                else best

waitForSpentTxIn :: Provider IO -> TxIn -> Int -> IO Bool
waitForSpentTxIn _ _ attempts
    | attempts <= 0 = pure False
waitForSpentTxIn provider ref attempts = do
    found <- queryUTxOByTxIn provider (Set.singleton ref)
    if Map.member ref found
        then do
            threadDelay 500_000
            waitForSpentTxIn provider ref (attempts - 1)
        else pure True

waitForTxOut
    :: Provider IO -> TxIn -> Int -> IO (Maybe (TxOut ConwayEra))
waitForTxOut _ _ attempts
    | attempts <= 0 = pure Nothing
waitForTxOut provider ref attempts = do
    found <- queryUTxOByTxIn provider (Set.singleton ref)
    case Map.lookup ref found of
        Just txOut -> pure (Just txOut)
        Nothing -> do
            threadDelay 500_000
            waitForTxOut provider ref (attempts - 1)

txOutRef :: TxId -> Integer -> TxIn
txOutRef txId ix =
    TxIn txId (mkTxIxPartial ix)

txOutLovelace :: TxOut ConwayEra -> Integer
txOutLovelace txOut =
    let MaryValue (Coin lovelace) _ = txOut ^. valueTxOutL
    in  lovelace

txOutHasAssets :: TxOut ConwayEra -> Bool
txOutHasAssets txOut =
    let MaryValue _ (MultiAsset assets) = txOut ^. valueTxOutL
    in  not (Map.null assets)

addSlots :: Word64 -> SlotNo -> SlotNo
addSlots delta (SlotNo slot) =
    SlotNo (slot + delta)

slotNumber :: SlotNo -> Word64
slotNumber (SlotNo slot) =
    slot

decodeUtf8Lenient :: BS8.ByteString -> T.Text
decodeUtf8Lenient =
    TE.decodeUtf8With (\_ _ -> Just '?')

parseEitherText
    :: (MonadFail m)
    => String
    -> (T.Text -> Either String a)
    -> T.Text
    -> m a
parseEitherText label parser raw =
    case parser raw of
        Right ok -> pure ok
        Left err -> fail (label <> ": " <> err)
