{-# LANGUAGE DataKinds #-}
{-# LANGUAGE EmptyCase #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeApplications #-}

{- |
Module      : Amaru.Treasury.Devnet.GovernanceWithdrawalInit
Description : DevNet governance withdrawal setup and artifact projection
License     : Apache-2.0

Production-backed implementation for the DevNet governance withdrawal
handoff. The command consumes the registry-init and stake-reward-init
artifacts, proposes/votes a treasury withdrawal into the already
registered treasury reward account, builds the withdraw transaction
through the normal tx-build path, signs/submits it, and writes the #150
handoff materialization artifact.
-}
module Amaru.Treasury.Devnet.GovernanceWithdrawalInit
    ( -- * Configuration
      DevnetGovernanceWithdrawalInitConfig (..)

      -- * Prerequisites
    , DevnetGovernanceWithdrawalRegistry (..)
    , DevnetGovernanceStakeRewardAccount (..)
    , DevnetGovernanceStakeRewardAccounts (..)
    , GovernanceWithdrawalPrerequisites (..)
    , readDevnetGovernanceWithdrawalRegistry
    , readDevnetGovernanceStakeRewardAccounts
    , validateGovernanceWithdrawalInitInputs
    , validateGovernanceWithdrawalPrerequisites
    , validateTreasuryMaterializationDelta

      -- * Result and failure types
    , GovernanceWithdrawalGovernanceEvidence (..)
    , GovernanceWithdrawalWithdrawalEvidence (..)
    , GovernanceWithdrawalMaterializationEvidence (..)
    , GovernanceWithdrawalInitResult (..)
    , GovernanceWithdrawalObservedTxIds (..)
    , GovernanceWithdrawalInitFailureStep (..)
    , GovernanceWithdrawalInitFailure (..)

      -- * Runner
    , runDevnetGovernanceWithdrawalInit

      -- * Construction cores

    --
    -- \^ Pure-IO transaction builders for the two flat
    -- @governance-withdrawal-init-*@ sub-actions. Each
    -- core mirrors the 'TxBuild' program a corresponding
    -- step of @runDevnetGovernanceWithdrawalInit@ uses
    -- under the hood, so the unified @tx-build@
    -- dispatcher and the live DevNet submitter produce
    -- byte-identical unsigned transactions for each
    -- sub-action.
    , GovernanceWithdrawalCoreEvaluator
    , buildGovernanceWithdrawalProposalCore
    , buildGovernanceWithdrawalMaterializationCore

      -- * Artifacts
    , governanceWithdrawalInitDirectory
    , governanceWithdrawalInitSummaryPath
    , governanceWithdrawalInitGovernancePath
    , governanceWithdrawalInitWithdrawalPath
    , governanceWithdrawalInitMaterializationPath
    , governanceWithdrawalInitProvenancePath
    , governanceWithdrawalInitFailurePath
    , governanceWithdrawalInitIntentPath
    , governanceWithdrawalInitTxBodyPath
    , governanceWithdrawalInitReportJsonPath
    , governanceWithdrawalInitReportMarkdownPath
    , governanceWithdrawalInitTxBuildLogPath
    , governanceWithdrawalInitSignedTxPath
    , governanceWithdrawalInitSubmitLogPath
    , governanceWithdrawalInitSummaryValue
    , governanceWithdrawalInitGovernanceValue
    , governanceWithdrawalInitWithdrawalValue
    , governanceWithdrawalInitMaterializationValue
    , governanceWithdrawalInitProvenanceValue
    , governanceWithdrawalInitFailureValue
    , governanceWithdrawalInitCommandLines
    , governanceWithdrawalInitFailureLines
    , writeGovernanceWithdrawalInitArtifactsWithLines
    , writeGovernanceWithdrawalInitFailure
    , renderAddr
    ) where

import Cardano.Crypto.DSIGN.Class
    ( SignKeyDSIGN
    , deriveVerKeyDSIGN
    , rawDeserialiseSignKeyDSIGN
    )
import Cardano.Crypto.Hash.Class
    ( Hash
    , HashAlgorithm
    , hashFromBytes
    )
import Cardano.Ledger.Address
    ( AccountAddress (..)
    , AccountId (..)
    , Addr (..)
    , getNetwork
    , serialiseAddr
    )
import Cardano.Ledger.Api.Tx (txIdTx)
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , addrTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.BaseTypes
    ( Network (..)
    , StrictMaybe (..)
    , mkTxIxPartial
    , textToUrl
    )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Conway.Governance (Anchor (..))
import Cardano.Ledger.Core (PParams)
import Cardano.Ledger.Credential
    ( Credential (..)
    , StakeReference (..)
    )
import Cardano.Ledger.Hashes
    ( KeyHash
    , ScriptHash
    , unsafeMakeSafeHash
    )
import Cardano.Ledger.Keys
    ( DSIGN
    , KeyRole (DRepRole, Payment, Staking)
    , VKey (..)
    , hashKey
    )
import Cardano.Ledger.Mary.Value
    ( MaryValue (..)
    , MultiAsset (..)
    )
import Cardano.Ledger.TxIn (TxId, TxIn (..))
import Cardano.Node.Client.Provider
    ( EpochNo (..)
    , LedgerSnapshot (..)
    , Provider (..)
    )
import Cardano.Node.Client.Submitter
    ( SubmitResult (..)
    , Submitter (..)
    )
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Tx.Build
    ( GovActionId (..)
    , GovActionIx (..)
    , InterpretIO (..)
    , TxBuild
    , Vote (..)
    , Voter (..)
    , build
    , mkPParamsBound
    , spend
    , validTo
    , vote
    )
import Codec.Binary.Bech32 qualified as Bech32
import Control.Concurrent (threadDelay)
import Control.Exception
    ( try
    )
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
import Data.Maybe (fromJust)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Data.Void (Void)
import Data.Word (Word64, Word8)
import Lens.Micro ((^.))
import System.Directory
    ( createDirectoryIfMissing
    , doesFileExist
    , removeFile
    )
import System.Exit (ExitCode (..))
import System.FilePath ((</>))

import Amaru.Treasury.Cli.TxBuild qualified as TxBuild
import Amaru.Treasury.Devnet.GovernanceWithdrawalInit.Core
    ( GovernanceWithdrawalCoreEvaluator
    , NoCtx
    , buildGovernanceWithdrawalMaterializationCore
    , buildGovernanceWithdrawalProposalCore
    , governanceWithdrawalProposalProgramAnchored
    )
import Amaru.Treasury.IntentJSON
    ( SAction (..)
    , SomeTreasuryIntent (..)
    , TreasuryIntent (..)
    , WithdrawInputs (..)
    , decodeTreasuryIntentFile
    , encodeSomeTreasuryIntent
    )
import Amaru.Treasury.IntentJSON.Common
    ( parseAddr
    )
import Amaru.Treasury.LedgerParse
    ( scriptHashFromHex
    , txInFromText
    )
import Amaru.Treasury.Report qualified as Report
import Amaru.Treasury.Report.Render qualified as ReportRender
import Amaru.Treasury.Scope
    ( ScopeId (CoreDevelopment)
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
    ( RegistryView (..)
    , ScopeOwners (..)
    , TreasuryRefs (..)
    , txInToText
    )
import Amaru.Treasury.Tx.WithdrawWizard qualified as Withdraw
import Amaru.Treasury.Tx.Witness
    ( addCardanoCliPaymentKeyWitness
    )

-- | Live inputs supplied by the shipped CLI runner after DevNet gating.
data DevnetGovernanceWithdrawalInitConfig = DevnetGovernanceWithdrawalInitConfig
    { dgwicNetworkMagic :: !Int
    , dgwicSocketPath :: !FilePath
    , dgwicFundingAddress :: !Addr
    , dgwicSigningKey :: !(SignKeyDSIGN DSIGN)
    , dgwicRunDir :: !FilePath
    , dgwicAmountLovelace :: !Integer
    , dgwicRewardTimeoutSeconds :: !Int
    }

-- | Projection consumed from #147 @registry-init/registry.json@.
data DevnetGovernanceWithdrawalRegistry = DevnetGovernanceWithdrawalRegistry
    { dgwrScopesRef :: !TxIn
    , dgwrRegistryRef :: !TxIn
    , dgwrPermissionsRef :: !TxIn
    , dgwrTreasuryRef :: !TxIn
    , dgwrRegistryPolicyId :: !T.Text
    , dgwrPermissionsScriptHashText :: !T.Text
    , dgwrPermissionsScriptHash :: !ScriptHash
    , dgwrTreasuryScriptHashText :: !T.Text
    , dgwrTreasuryScriptHash :: !ScriptHash
    , dgwrTreasuryAddressText :: !T.Text
    , dgwrTreasuryAddress :: !Addr
    , dgwrOwnerKeyHash :: !T.Text
    }
    deriving stock (Eq, Show)

instance FromJSON DevnetGovernanceWithdrawalRegistry where
    parseJSON = withObject "DevnetGovernanceWithdrawalRegistry" $ \o -> do
        phase <- o .: "phase"
        network <- o .: "network"
        unless (phase == ("registry-init" :: T.Text)) $
            fail "expected registry-init phase"
        unless (network == ("devnet" :: T.Text)) $
            fail "expected devnet registry"
        anchors <- o .: "anchors"
        policies <- o .: "policies"
        scripts <- o .: "scripts"
        addresses <- o .: "addresses"
        owners <- o .: "owners"
        scopesRefText <- anchors .: "scopesDeployedAt"
        registryRefText <- anchors .: "registryDeployedAt"
        permissionsRefText <- anchors .: "permissionsDeployedAt"
        treasuryRefText <- anchors .: "treasuryDeployedAt"
        registryPolicyId <- policies .: "registryPolicyId"
        permissionsHashText <- scripts .: "permissionsScriptHash"
        treasuryHashText <- scripts .: "treasuryScriptHash"
        treasuryAddressText <- addresses .: "treasuryAddress"
        ownerKeyHash <- owners .: "scopeOwnerKeyHash"
        treasuryAddress <-
            parseEitherText "treasuryAddress" parseAddr treasuryAddressText
        unless (getNetwork treasuryAddress == Testnet) $
            fail "treasuryAddress: expected testnet address"
        DevnetGovernanceWithdrawalRegistry
            <$> parseEitherText "scopesDeployedAt" txInFromText scopesRefText
            <*> parseEitherText
                "registryDeployedAt"
                txInFromText
                registryRefText
            <*> parseEitherText
                "permissionsDeployedAt"
                txInFromText
                permissionsRefText
            <*> parseEitherText
                "treasuryDeployedAt"
                txInFromText
                treasuryRefText
            <*> pure registryPolicyId
            <*> pure permissionsHashText
            <*> parseEitherText
                "permissionsScriptHash"
                scriptHashFromHex
                permissionsHashText
            <*> pure treasuryHashText
            <*> parseEitherText
                "treasuryScriptHash"
                scriptHashFromHex
                treasuryHashText
            <*> pure treasuryAddressText
            <*> pure treasuryAddress
            <*> pure ownerKeyHash

readDevnetGovernanceWithdrawalRegistry
    :: FilePath -> IO (Either String DevnetGovernanceWithdrawalRegistry)
readDevnetGovernanceWithdrawalRegistry =
    eitherDecodeFileStrict

-- | One account projection from #148 @stake-reward-init/accounts.json@.
data DevnetGovernanceStakeRewardAccount = DevnetGovernanceStakeRewardAccount
    { dgsraScriptHash :: !T.Text
    , dgsraRewardAccount :: !T.Text
    , dgsraLedgerNetwork :: !T.Text
    , dgsraRegistered :: !Bool
    , dgsraRewardsLovelace :: !Integer
    }
    deriving stock (Eq, Show)

instance FromJSON DevnetGovernanceStakeRewardAccount where
    parseJSON = withObject "DevnetGovernanceStakeRewardAccount" $ \o ->
        DevnetGovernanceStakeRewardAccount
            <$> o .: "scriptHash"
            <*> o .: "rewardAccount"
            <*> o .: "ledgerNetwork"
            <*> o .: "registered"
            <*> o .: "rewardsLovelace"

-- | Account set consumed from #148 @stake-reward-init/accounts.json@.
data DevnetGovernanceStakeRewardAccounts = DevnetGovernanceStakeRewardAccounts
    { dgsrasTreasury :: !DevnetGovernanceStakeRewardAccount
    , dgsrasPermissions :: !DevnetGovernanceStakeRewardAccount
    }
    deriving stock (Eq, Show)

instance FromJSON DevnetGovernanceStakeRewardAccounts where
    parseJSON = withObject "DevnetGovernanceStakeRewardAccounts" $ \o -> do
        phase <- o .: "phase"
        network <- o .: "network"
        unless (phase == ("stake-reward-init" :: T.Text)) $
            fail "expected stake-reward-init phase"
        unless (network == ("devnet" :: T.Text)) $
            fail "expected devnet stake-reward accounts"
        accounts <- o .: "accounts"
        DevnetGovernanceStakeRewardAccounts
            <$> accounts .: "treasury"
            <*> accounts .: "permissions"

readDevnetGovernanceStakeRewardAccounts
    :: FilePath -> IO (Either String DevnetGovernanceStakeRewardAccounts)
readDevnetGovernanceStakeRewardAccounts =
    eitherDecodeFileStrict

data GovernanceWithdrawalPrerequisites = GovernanceWithdrawalPrerequisites
    { gwpRegistry :: !DevnetGovernanceWithdrawalRegistry
    , gwpAccounts :: !DevnetGovernanceStakeRewardAccounts
    }
    deriving stock (Eq, Show)

-- | Validate that #149 consumes the exact #147/#148 DevNet handoff.
validateGovernanceWithdrawalPrerequisites
    :: DevnetGovernanceWithdrawalRegistry
    -> DevnetGovernanceStakeRewardAccounts
    -> Either
        GovernanceWithdrawalInitFailure
        GovernanceWithdrawalPrerequisites
validateGovernanceWithdrawalPrerequisites registry accounts = do
    let treasury =
            dgsrasTreasury accounts
        inputFailure code message =
            Left
                GovernanceWithdrawalInitFailure
                    { gwifCode = code
                    , gwifMessage = message
                    , gwifFailedStep = GovernanceWithdrawalValidateInputs
                    , gwifObservedTxIds = emptyObservedTxIds
                    , gwifLastObservedRewardLovelace = Nothing
                    , gwifEpoch = Nothing
                    , gwifTipSlot = Nothing
                    }
    when (dgsraLedgerNetwork treasury /= "Testnet") $
        inputFailure
            "stake-reward-network-mismatch"
            "stake-reward treasury account is not marked Testnet"
    unless (dgsraRegistered treasury) $
        inputFailure
            "treasury-reward-not-registered"
            "stake-reward treasury account is not registered"
    when (dgsraRewardAccount treasury /= dgsraScriptHash treasury) $
        inputFailure
            "treasury-reward-account-mismatch"
            "stake-reward treasury reward account does not match script hash"
    when
        (dgsraScriptHash treasury /= dgwrTreasuryScriptHashText registry)
        $ inputFailure
            "treasury-script-hash-mismatch"
            "registry treasury script hash does not match stake-reward treasury account"
    Right
        GovernanceWithdrawalPrerequisites
            { gwpRegistry = registry
            , gwpAccounts = accounts
            }

-- | Validate command scalar inputs before reading signing keys or sockets.
validateGovernanceWithdrawalInitInputs
    :: Integer -> Int -> Either GovernanceWithdrawalInitFailure ()
validateGovernanceWithdrawalInitInputs amountLovelace rewardTimeoutSeconds
    | amountLovelace <= 0 =
        Left
            ( inputValidationFailure
                "amount-lovelace-non-positive"
                "--amount-lovelace must be greater than 0"
            )
    | rewardTimeoutSeconds <= 0 =
        Left
            ( inputValidationFailure
                "reward-timeout-seconds-non-positive"
                "--reward-timeout-seconds must be greater than 0"
            )
    | otherwise =
        Right ()

inputValidationFailure
    :: T.Text -> T.Text -> GovernanceWithdrawalInitFailure
inputValidationFailure code message =
    GovernanceWithdrawalInitFailure
        { gwifCode = code
        , gwifMessage = message
        , gwifFailedStep = GovernanceWithdrawalValidateInputs
        , gwifObservedTxIds = emptyObservedTxIds
        , gwifLastObservedRewardLovelace = Nothing
        , gwifEpoch = Nothing
        , gwifTipSlot = Nothing
        }

data GovernanceWithdrawalGovernanceEvidence = GovernanceWithdrawalGovernanceEvidence
    { gwgeProposalTxId :: !T.Text
    , gwgeGovernanceActionId :: !T.Text
    , gwgeVoteTxId :: !T.Text
    , gwgeTreasuryRewardAccount :: !T.Text
    , gwgeTreasuryScriptHash :: !T.Text
    , gwgeAmountLovelace :: !Integer
    , gwgeRewardBeforeLovelace :: !Integer
    , gwgeRewardAfterGovernanceLovelace :: !Integer
    , gwgeSetupEpoch :: !Word64
    , gwgeVoteEpoch :: !Word64
    , gwgeFinalEpoch :: !Word64
    }
    deriving stock (Eq, Show)

data GovernanceWithdrawalWithdrawalEvidence = GovernanceWithdrawalWithdrawalEvidence
    { gwweIntentPath :: !FilePath
    , gwweTxBodyPath :: !FilePath
    , gwweReportJsonPath :: !FilePath
    , gwweReportMarkdownPath :: !FilePath
    , gwweTxBuildLogPath :: !FilePath
    , gwweSignedTxPath :: !FilePath
    , gwweSubmitLogPath :: !FilePath
    , gwweTxId :: !T.Text
    , gwweSubmittedTxId :: !T.Text
    , gwweFeeLovelace :: !Integer
    , gwweRewardBeforeSubmitLovelace :: !Integer
    , gwweRewardAfterSubmitLovelace :: !Integer
    }
    deriving stock (Eq, Show)

data GovernanceWithdrawalMaterializationEvidence = GovernanceWithdrawalMaterializationEvidence
    { gwmeGovernanceActionId :: !T.Text
    , gwmeTreasuryRewardAccount :: !T.Text
    , gwmeSubmittedTxId :: !T.Text
    , gwmeTreasuryMaterializedTxIn :: !T.Text
    , gwmeTreasuryAddress :: !T.Text
    , gwmeMaterializedAdaLovelace :: !Integer
    , gwmeRewardBeforeSubmitLovelace :: !Integer
    , gwmeRewardAfterSubmitLovelace :: !Integer
    , gwmeTreasuryUtxoLovelaceBefore :: !Integer
    , gwmeTreasuryUtxoLovelaceAfter :: !Integer
    }
    deriving stock (Eq, Show)

data GovernanceWithdrawalInitResult = GovernanceWithdrawalInitResult
    { gwirRegistryPath :: !FilePath
    , gwirStakeRewardPath :: !FilePath
    , gwirGovernance :: !GovernanceWithdrawalGovernanceEvidence
    , gwirWithdrawal :: !GovernanceWithdrawalWithdrawalEvidence
    , gwirMaterialization :: !GovernanceWithdrawalMaterializationEvidence
    }
    deriving stock (Eq, Show)

data GovernanceWithdrawalObservedTxIds = GovernanceWithdrawalObservedTxIds
    { gwoProposal :: !(Maybe T.Text)
    , gwoVote :: !(Maybe T.Text)
    , gwoWithdrawal :: !(Maybe T.Text)
    }
    deriving stock (Eq, Show)

data GovernanceWithdrawalInitFailureStep
    = GovernanceWithdrawalValidateInputs
    | GovernanceWithdrawalGovernanceBuild
    | GovernanceWithdrawalGovernanceSubmit
    | GovernanceWithdrawalVoteSubmit
    | GovernanceWithdrawalRewardWait
    | GovernanceWithdrawalWithdrawIntent
    | GovernanceWithdrawalWithdrawBuild
    | GovernanceWithdrawalWithdrawSubmit
    | GovernanceWithdrawalMaterializationVerify
    deriving stock (Eq, Show)

data GovernanceWithdrawalInitFailure = GovernanceWithdrawalInitFailure
    { gwifCode :: !T.Text
    , gwifMessage :: !T.Text
    , gwifFailedStep :: !GovernanceWithdrawalInitFailureStep
    , gwifObservedTxIds :: !GovernanceWithdrawalObservedTxIds
    , gwifLastObservedRewardLovelace :: !(Maybe Integer)
    , gwifEpoch :: !(Maybe Word64)
    , gwifTipSlot :: !(Maybe Word64)
    }
    deriving stock (Eq, Show)

-- | Execute the full command-owned DevNet flow and write artifacts.
runDevnetGovernanceWithdrawalInit
    :: DevnetGovernanceWithdrawalInitConfig
    -> FilePath
    -> FilePath
    -> GovernanceWithdrawalPrerequisites
    -> Provider IO
    -> Submitter IO
    -> IO
        ( Either GovernanceWithdrawalInitFailure GovernanceWithdrawalInitResult
        )
runDevnetGovernanceWithdrawalInit
    config@DevnetGovernanceWithdrawalInitConfig{..}
    registryPath
    stakeRewardPath
    prereqs
    provider
    submitter = do
        createDirectoryIfMissing
            True
            (governanceWithdrawalInitDirectory dgwicRunDir)
        pp <- queryProtocolParams provider
        utxos <- queryUTxOs provider dgwicFundingAddress
        submitGovernanceWithdrawal
            config
            prereqs
            provider
            submitter
            pp
            utxos
            >>= \case
                Left runFailure -> failAndReturn runFailure
                Right governance ->
                    buildSubmitAndMaterializeWithdrawal
                        config
                        prereqs
                        governance
                        provider
                        submitter
                        >>= \case
                            Left runFailure -> failAndReturn runFailure
                            Right (withdrawal, materialization) -> do
                                let result =
                                        GovernanceWithdrawalInitResult
                                            { gwirRegistryPath = registryPath
                                            , gwirStakeRewardPath =
                                                stakeRewardPath
                                            , gwirGovernance = governance
                                            , gwirWithdrawal = withdrawal
                                            , gwirMaterialization =
                                                materialization
                                            }
                                    linesOut =
                                        governanceWithdrawalInitCommandLines
                                            dgwicNetworkMagic
                                            dgwicRunDir
                                            result
                                writeGovernanceWithdrawalInitArtifactsWithLines
                                    dgwicNetworkMagic
                                    dgwicRunDir
                                    result
                                    linesOut
                                pure (Right result)
      where
        failAndReturn runFailure = do
            writeGovernanceWithdrawalInitFailure dgwicRunDir runFailure
            pure (Left runFailure)

submitGovernanceWithdrawal
    :: DevnetGovernanceWithdrawalInitConfig
    -> GovernanceWithdrawalPrerequisites
    -> Provider IO
    -> Submitter IO
    -> PParams ConwayEra
    -> [(TxIn, TxOut ConwayEra)]
    -> IO
        ( Either
            GovernanceWithdrawalInitFailure
            GovernanceWithdrawalGovernanceEvidence
        )
submitGovernanceWithdrawal
    DevnetGovernanceWithdrawalInitConfig{..}
    GovernanceWithdrawalPrerequisites{gwpRegistry = registry}
    provider
    submitter
    pp
    utxos = do
        seed@(seedIn, _) <- selectLargestAdaUtxo "governance withdrawal" utxos
        buildSnapshot <- queryLedgerSnapshot provider
        let amount =
                Coin dgwicAmountLovelace
            upperSlot =
                addSlots 20 (ledgerTipSlot buildSnapshot)
            treasuryCredential =
                ScriptHashObj (dgwrTreasuryScriptHash registry)
            treasuryAccount =
                AccountAddress Testnet (AccountId treasuryCredential)
            fundingCredential =
                stakeCredentialFromSignKey dgwicSigningKey
            returnAccount =
                AccountAddress Testnet (AccountId fundingCredential)
            voterCredential =
                stakeCredentialFromSignKey voterSignKey
            drepCredential =
                drepCredentialFromSignKey voterSignKey
            drepKey =
                drepKeyHashFromSignKey voterSignKey
            voterBaseAddr =
                baseAddrFromSignKey voterSignKey voterCredential
            interpret :: InterpretIO NoCtx
            interpret =
                InterpretIO $ \case {}
            eval tx =
                fmap
                    (Map.map (either (Left . show) Right))
                    (evaluateTx provider tx)
            prog :: TxBuild NoCtx Void ()
            prog =
                governanceWithdrawalProposalProgram
                    seedIn
                    fundingCredential
                    voterCredential
                    drepCredential
                    drepKey
                    voterBaseAddr
                    returnAccount
                    treasuryAccount
                    amount
                    upperSlot
        rewardBefore <- rewardBalance provider treasuryAccount
        build
            (mkPParamsBound pp)
            interpret
            eval
            [seed]
            []
            dgwicFundingAddress
            prog
            >>= \case
                Left err ->
                    pure . Left $
                        failureFromSnapshot
                            "governance-build-failed"
                            ( "governance proposal build failed: "
                                <> T.pack (show err)
                            )
                            GovernanceWithdrawalGovernanceBuild
                            emptyObservedTxIds
                            (Just (coinLovelace rewardBefore))
                            buildSnapshot
                Right tx -> do
                    let signed =
                            addCardanoCliPaymentKeyWitness voterSignKey $
                                addCardanoCliPaymentKeyWitness
                                    dgwicSigningKey
                                    tx
                        proposalTxId =
                            txIdTx signed
                        proposalTxIdText =
                            renderTxId proposalTxId
                    submitTx submitter signed >>= \case
                        Rejected reason ->
                            pure . Left $
                                failureFromSnapshot
                                    "governance-submit-rejected"
                                    ( "governance proposal rejected: "
                                        <> decodeUtf8Lenient reason
                                    )
                                    GovernanceWithdrawalGovernanceSubmit
                                    ( observedTxIds
                                        (Just proposalTxIdText)
                                        Nothing
                                        Nothing
                                    )
                                    (Just (coinLovelace rewardBefore))
                                    buildSnapshot
                        Submitted _ -> do
                            waitForTxChange
                                provider
                                proposalTxId
                                dgwicFundingAddress
                                60
                            setupSnapshot <- queryLedgerSnapshot provider
                            governanceState <- queryGovernanceState provider
                            governanceState `seq` pure ()
                            waitForEpochAfter
                                provider
                                (ledgerEpoch setupSnapshot)
                                60
                            voteUtxos <-
                                waitForUtxos provider voterBaseAddr 60
                            case voteUtxos of
                                [] ->
                                    pure . Left $
                                        failureFromSnapshot
                                            "vote-seed-missing"
                                            "voter base UTxO disappeared before vote"
                                            GovernanceWithdrawalVoteSubmit
                                            ( observedTxIds
                                                (Just proposalTxIdText)
                                                Nothing
                                                Nothing
                                            )
                                            (Just (coinLovelace rewardBefore))
                                            setupSnapshot
                                voteSeed : _ -> do
                                    let actionIx = 0
                                        actionId =
                                            GovActionId
                                                proposalTxId
                                                (GovActionIx actionIx)
                                        actionIdText =
                                            proposalTxIdText
                                                <> "#"
                                                <> T.pack (show actionIx)
                                    submitVoteTx
                                        provider
                                        submitter
                                        pp
                                        voterBaseAddr
                                        voteSeed
                                        drepCredential
                                        actionId
                                        >>= \case
                                            Left voteFailure ->
                                                pure . Left $
                                                    voteFailure
                                                        proposalTxIdText
                                                        rewardBefore
                                                        setupSnapshot
                                            Right voteTxId -> do
                                                let voteTxIdText =
                                                        renderTxId voteTxId
                                                    observed =
                                                        observedTxIds
                                                            ( Just
                                                                proposalTxIdText
                                                            )
                                                            (Just voteTxIdText)
                                                            Nothing
                                                voteSnapshot <-
                                                    queryLedgerSnapshot
                                                        provider
                                                waitForRewardIncrease
                                                    provider
                                                    treasuryAccount
                                                    (ledgerEpoch voteSnapshot)
                                                    rewardBefore
                                                    amount
                                                    (rewardWaitAttempts dgwicRewardTimeoutSeconds)
                                                    >>= \case
                                                        Left
                                                            ( lastReward
                                                                , epoch
                                                                , tipSlot
                                                                ) ->
                                                                pure . Left $
                                                                    GovernanceWithdrawalInitFailure
                                                                        { gwifCode =
                                                                            "reward-timeout"
                                                                        , gwifMessage =
                                                                            "timed out waiting for reward account "
                                                                                <> dgwrTreasuryScriptHashText registry
                                                                                <> " to increase by "
                                                                                <> T.pack
                                                                                    ( show
                                                                                        ( coinLovelace
                                                                                            amount
                                                                                        )
                                                                                    )
                                                                        , gwifFailedStep =
                                                                            GovernanceWithdrawalRewardWait
                                                                        , gwifObservedTxIds =
                                                                            observed
                                                                        , gwifLastObservedRewardLovelace =
                                                                            Just
                                                                                ( coinLovelace
                                                                                    lastReward
                                                                                )
                                                                        , gwifEpoch =
                                                                            epoch
                                                                        , gwifTipSlot =
                                                                            tipSlot
                                                                        }
                                                        Right rewardAfter -> do
                                                            finalSnapshot <-
                                                                queryLedgerSnapshot
                                                                    provider
                                                            pure . Right $
                                                                GovernanceWithdrawalGovernanceEvidence
                                                                    { gwgeProposalTxId =
                                                                        proposalTxIdText
                                                                    , gwgeGovernanceActionId =
                                                                        actionIdText
                                                                    , gwgeVoteTxId =
                                                                        voteTxIdText
                                                                    , gwgeTreasuryRewardAccount =
                                                                        dgwrTreasuryScriptHashText
                                                                            registry
                                                                    , gwgeTreasuryScriptHash =
                                                                        dgwrTreasuryScriptHashText
                                                                            registry
                                                                    , gwgeAmountLovelace =
                                                                        coinLovelace
                                                                            amount
                                                                    , gwgeRewardBeforeLovelace =
                                                                        coinLovelace
                                                                            rewardBefore
                                                                    , gwgeRewardAfterGovernanceLovelace =
                                                                        coinLovelace
                                                                            rewardAfter
                                                                    , gwgeSetupEpoch =
                                                                        epochNumber
                                                                            ( ledgerEpoch
                                                                                setupSnapshot
                                                                            )
                                                                    , gwgeVoteEpoch =
                                                                        epochNumber
                                                                            ( ledgerEpoch
                                                                                voteSnapshot
                                                                            )
                                                                    , gwgeFinalEpoch =
                                                                        epochNumber
                                                                            ( ledgerEpoch
                                                                                finalSnapshot
                                                                            )
                                                                    }

{- | Public surface wrapping
'governanceWithdrawalProposalProgramAnchored' with the
fixed module-level 'governanceAnchor' the production
DevNet submitter uses.
-}
governanceWithdrawalProposalProgram
    :: TxIn
    -> Credential Staking
    -> Credential Staking
    -> Credential DRepRole
    -> KeyHash DRepRole
    -> Addr
    -> AccountAddress
    -> AccountAddress
    -> Coin
    -> SlotNo
    -> TxBuild NoCtx Void ()
governanceWithdrawalProposalProgram
    seedIn
    fundingCredential
    voterCredential
    drepCredential
    drepKey
    voterBaseAddr
    returnAccount
    treasuryAccount
    amount
    upperSlot =
        governanceWithdrawalProposalProgramAnchored
            seedIn
            fundingCredential
            voterCredential
            drepCredential
            drepKey
            voterBaseAddr
            returnAccount
            treasuryAccount
            amount
            upperSlot
            governanceAnchor

submitVoteTx
    :: Provider IO
    -> Submitter IO
    -> PParams ConwayEra
    -> Addr
    -> (TxIn, TxOut ConwayEra)
    -> Credential DRepRole
    -> GovActionId
    -> IO
        ( Either
            ( T.Text
              -> Coin
              -> LedgerSnapshot
              -> GovernanceWithdrawalInitFailure
            )
            TxId
        )
submitVoteTx
    provider
    submitter
    pp
    voterBaseAddr
    seed@(seedIn, _)
    drepCredential
    actionId = do
        snapshot <- queryLedgerSnapshot provider
        let interpret :: InterpretIO NoCtx
            interpret =
                InterpretIO $ \case {}
            upperSlot =
                addSlots 20 (ledgerTipSlot snapshot)
            eval tx =
                fmap
                    (Map.map (either (Left . show) Right))
                    (evaluateTx provider tx)
            prog :: TxBuild NoCtx Void ()
            prog = do
                _ <- spend seedIn
                vote
                    (DRepVoter drepCredential)
                    actionId
                    VoteYes
                    SNothing
                validTo upperSlot
        build
            (mkPParamsBound pp)
            interpret
            eval
            [seed]
            []
            voterBaseAddr
            prog
            >>= \case
                Left err ->
                    pure . Left $ \proposalTxIdText rewardBefore setupSnapshot ->
                        failureFromSnapshot
                            "vote-build-failed"
                            ("vote build failed: " <> T.pack (show err))
                            GovernanceWithdrawalVoteSubmit
                            ( observedTxIds
                                (Just proposalTxIdText)
                                Nothing
                                Nothing
                            )
                            (Just (coinLovelace rewardBefore))
                            setupSnapshot
                Right tx -> do
                    let signed =
                            addCardanoCliPaymentKeyWitness voterSignKey tx
                        txId =
                            txIdTx signed
                    submitTx submitter signed >>= \case
                        Rejected reason ->
                            pure . Left $ \proposalTxIdText rewardBefore setupSnapshot ->
                                failureFromSnapshot
                                    "vote-submit-rejected"
                                    ( "vote rejected: "
                                        <> decodeUtf8Lenient reason
                                    )
                                    GovernanceWithdrawalVoteSubmit
                                    ( observedTxIds
                                        (Just proposalTxIdText)
                                        (Just (renderTxId txId))
                                        Nothing
                                    )
                                    (Just (coinLovelace rewardBefore))
                                    setupSnapshot
                        Submitted _ -> do
                            waitForTxChange provider txId voterBaseAddr 60
                            pure (Right txId)

buildSubmitAndMaterializeWithdrawal
    :: DevnetGovernanceWithdrawalInitConfig
    -> GovernanceWithdrawalPrerequisites
    -> GovernanceWithdrawalGovernanceEvidence
    -> Provider IO
    -> Submitter IO
    -> IO
        ( Either
            GovernanceWithdrawalInitFailure
            ( GovernanceWithdrawalWithdrawalEvidence
            , GovernanceWithdrawalMaterializationEvidence
            )
        )
buildSubmitAndMaterializeWithdrawal
    config@DevnetGovernanceWithdrawalInitConfig{..}
    prereqs@GovernanceWithdrawalPrerequisites{gwpRegistry = registry}
    governance
    provider
    submitter = do
        removeStaleWithdrawalArtifacts dgwicRunDir
        buildWithdrawalIntent
            config
            prereqs
            governance
            provider
            >>= \case
                Left withdrawalFailure -> pure (Left withdrawalFailure)
                Right rewardBeforeSubmit -> do
                    buildWithdrawalTransaction config governance >>= \case
                        Left withdrawalFailure -> pure (Left withdrawalFailure)
                        Right success ->
                            signSubmitAndMaterializeWithdrawal
                                config
                                registry
                                governance
                                provider
                                submitter
                                rewardBeforeSubmit
                                success

buildWithdrawalIntent
    :: DevnetGovernanceWithdrawalInitConfig
    -> GovernanceWithdrawalPrerequisites
    -> GovernanceWithdrawalGovernanceEvidence
    -> Provider IO
    -> IO (Either GovernanceWithdrawalInitFailure Coin)
buildWithdrawalIntent
    DevnetGovernanceWithdrawalInitConfig{..}
    GovernanceWithdrawalPrerequisites{gwpRegistry = registry}
    governance
    provider = do
        let treasuryAccount =
                registryTreasuryAccount registry
            walletAddress =
                renderAddr dgwicFundingAddress
            registryView =
                registryViewFromArtifact registry
            resolver =
                Withdraw.WithdrawResolverEnv
                    { Withdraw.wreQueryWalletUtxos =
                        queryWalletUtxosForWithdraw provider dgwicFundingAddress
                    , Withdraw.wreQueryRewardsLovelace = \account -> do
                        unless (account == gwgeTreasuryRewardAccount governance) $
                            fail "withdraw resolver requested unexpected reward account"
                        coinLovelace <$> rewardBalance provider treasuryAccount
                    , Withdraw.wreComputeUpperBound = \_ -> do
                        snapshot <- queryLedgerSnapshot provider
                        pure . Right . slotNumber $
                            addSlots 20 (ledgerTipSlot snapshot)
                    }
            input =
                Withdraw.WithdrawResolverInput
                    { Withdraw.wriNetwork = "devnet"
                    , Withdraw.wriWalletAddrBech32 = walletAddress
                    , Withdraw.wriScope = CoreDevelopment
                    , Withdraw.wriRegistry = registryView
                    , Withdraw.wriValidityHours = Nothing
                    }
        observedRewards <- rewardBalance provider treasuryAccount
        if observedRewards <= Coin 0
            then do
                (epoch, tipSlot) <- epochTip provider
                pure . Left $
                    failureWithoutSnapshot
                        "zero-rewards"
                        ( "reward account "
                            <> gwgeTreasuryRewardAccount governance
                            <> " has zero rewards"
                        )
                        GovernanceWithdrawalWithdrawIntent
                        (observedFromGovernance governance Nothing)
                        (Just (coinLovelace observedRewards))
                        epoch
                        tipSlot
            else do
                resolved <- Withdraw.resolveWithdrawEnv resolver input
                case resolved of
                    Left err -> do
                        (epoch, tipSlot) <- epochTip provider
                        pure . Left $
                            withdrawResolverFailure
                                governance
                                observedRewards
                                epoch
                                tipSlot
                                err
                    Right env -> do
                        let answers =
                                Withdraw.WithdrawAnswers
                                    { Withdraw.waScope = CoreDevelopment
                                    , Withdraw.waValidityHours = Nothing
                                    , Withdraw.waDescription = Nothing
                                    , Withdraw.waJustification = Nothing
                                    , Withdraw.waDestinationLabel = Nothing
                                    , Withdraw.waEvent = Nothing
                                    , Withdraw.waLabel = Nothing
                                    }
                        case Withdraw.withdrawToTreasuryResult env answers of
                            Left err -> do
                                (epoch, tipSlot) <- epochTip provider
                                pure . Left $
                                    withdrawIntentFailure
                                        governance
                                        observedRewards
                                        epoch
                                        tipSlot
                                        err
                            Right (Withdraw.WithdrawNoRewards account) -> do
                                (epoch, tipSlot) <- epochTip provider
                                pure . Left $
                                    failureWithoutSnapshot
                                        "zero-rewards"
                                        ( "reward account "
                                            <> account
                                            <> " has zero rewards"
                                        )
                                        GovernanceWithdrawalWithdrawIntent
                                        ( observedFromGovernance
                                            governance
                                            Nothing
                                        )
                                        (Just (coinLovelace observedRewards))
                                        epoch
                                        tipSlot
                            Right (Withdraw.WithdrawIntentReady intent) -> do
                                BSL.writeFile
                                    ( governanceWithdrawalInitIntentPath
                                        dgwicRunDir
                                    )
                                    ( encodeSomeTreasuryIntent
                                        (SomeTreasuryIntent SWithdraw intent)
                                    )
                                decoded <-
                                    decodeTreasuryIntentFile
                                        ( governanceWithdrawalInitIntentPath
                                            dgwicRunDir
                                        )
                                case decoded of
                                    Right (SomeTreasuryIntent SWithdraw parsed)
                                        | wdiTreasuryRewardAccount
                                            (tiPayload parsed)
                                            == gwgeTreasuryRewardAccount
                                                governance
                                        , wdiRewardsLovelace (tiPayload parsed)
                                            == coinLovelace observedRewards ->
                                            pure (Right observedRewards)
                                    Right{} -> do
                                        (epoch, tipSlot) <- epochTip provider
                                        pure . Left $
                                            failureWithoutSnapshot
                                                "intent-roundtrip-failed"
                                                "withdraw intent roundtrip did not preserve reward account and amount"
                                                GovernanceWithdrawalWithdrawIntent
                                                ( observedFromGovernance
                                                    governance
                                                    Nothing
                                                )
                                                ( Just
                                                    ( coinLovelace
                                                        observedRewards
                                                    )
                                                )
                                                epoch
                                                tipSlot
                                    Left err -> do
                                        (epoch, tipSlot) <- epochTip provider
                                        pure . Left $
                                            failureWithoutSnapshot
                                                "intent-roundtrip-failed"
                                                ( "withdraw intent failed to decode: "
                                                    <> T.pack err
                                                )
                                                GovernanceWithdrawalWithdrawIntent
                                                ( observedFromGovernance
                                                    governance
                                                    Nothing
                                                )
                                                ( Just
                                                    ( coinLovelace
                                                        observedRewards
                                                    )
                                                )
                                                epoch
                                                tipSlot

buildWithdrawalTransaction
    :: DevnetGovernanceWithdrawalInitConfig
    -> GovernanceWithdrawalGovernanceEvidence
    -> IO (Either GovernanceWithdrawalInitFailure Report.TxBuildSuccess)
buildWithdrawalTransaction
    DevnetGovernanceWithdrawalInitConfig{..}
    governance = do
        buildExit <-
            try @ExitCode $
                TxBuild.runTxBuild
                    dgwicSocketPath
                    TxBuild.TxBuildOpts
                        { TxBuild.tboIntentPath =
                            Just
                                (governanceWithdrawalInitIntentPath dgwicRunDir)
                        , TxBuild.tboOutPath =
                            Just (governanceWithdrawalInitTxBodyPath dgwicRunDir)
                        , TxBuild.tboLog =
                            Just
                                ( governanceWithdrawalInitTxBuildLogPath
                                    dgwicRunDir
                                )
                        , TxBuild.tboReportPath =
                            Just
                                ( governanceWithdrawalInitReportJsonPath
                                    dgwicRunDir
                                )
                        }
        case buildExit of
            Left exitCode -> do
                txBuildFailure <- readWithdrawalTxBuildFailure dgwicRunDir
                pure . Left $
                    GovernanceWithdrawalInitFailure
                        { gwifCode = "tx-build-failed"
                        , gwifMessage =
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
                        , gwifFailedStep = GovernanceWithdrawalWithdrawBuild
                        , gwifObservedTxIds =
                            observedFromGovernance governance Nothing
                        , gwifLastObservedRewardLovelace = Nothing
                        , gwifEpoch = Nothing
                        , gwifTipSlot = Nothing
                        }
            Right () -> do
                buildOutput <-
                    eitherDecodeFileStrict
                        @Report.TxBuildOutput
                        (governanceWithdrawalInitReportJsonPath dgwicRunDir)
                case buildOutput of
                    Left err ->
                        pure . Left $
                            GovernanceWithdrawalInitFailure
                                { gwifCode = "tx-build-report-decode-failed"
                                , gwifMessage =
                                    "failed to decode tx-build report: "
                                        <> T.pack err
                                , gwifFailedStep =
                                    GovernanceWithdrawalWithdrawBuild
                                , gwifObservedTxIds =
                                    observedFromGovernance governance Nothing
                                , gwifLastObservedRewardLovelace = Nothing
                                , gwifEpoch = Nothing
                                , gwifTipSlot = Nothing
                                }
                    Right output ->
                        case Report.txoResult output of
                            Report.TxBuildOutputFailure failureReport ->
                                pure . Left $
                                    GovernanceWithdrawalInitFailure
                                        { gwifCode = "tx-build-failed"
                                        , gwifMessage =
                                            Report.bfCode failureReport
                                                <> ": "
                                                <> Report.bfMessage
                                                    failureReport
                                        , gwifFailedStep =
                                            GovernanceWithdrawalWithdrawBuild
                                        , gwifObservedTxIds =
                                            observedFromGovernance
                                                governance
                                                Nothing
                                        , gwifLastObservedRewardLovelace =
                                            Nothing
                                        , gwifEpoch = Nothing
                                        , gwifTipSlot = Nothing
                                        }
                            Report.TxBuildOutputSuccess success -> do
                                case ReportRender.renderBuildOutput output of
                                    Left err ->
                                        pure . Left $
                                            GovernanceWithdrawalInitFailure
                                                { gwifCode =
                                                    "report-render-failed"
                                                , gwifMessage =
                                                    "failed to render withdraw report: "
                                                        <> T.pack (show err)
                                                , gwifFailedStep =
                                                    GovernanceWithdrawalWithdrawBuild
                                                , gwifObservedTxIds =
                                                    observedFromGovernance
                                                        governance
                                                        Nothing
                                                , gwifLastObservedRewardLovelace =
                                                    Nothing
                                                , gwifEpoch = Nothing
                                                , gwifTipSlot = Nothing
                                                }
                                    Right render -> do
                                        TIO.writeFile
                                            ( governanceWithdrawalInitReportMarkdownPath
                                                dgwicRunDir
                                            )
                                            (ReportRender.unRenderOutput render)
                                        pure (Right success)

signSubmitAndMaterializeWithdrawal
    :: DevnetGovernanceWithdrawalInitConfig
    -> DevnetGovernanceWithdrawalRegistry
    -> GovernanceWithdrawalGovernanceEvidence
    -> Provider IO
    -> Submitter IO
    -> Coin
    -> Report.TxBuildSuccess
    -> IO
        ( Either
            GovernanceWithdrawalInitFailure
            ( GovernanceWithdrawalWithdrawalEvidence
            , GovernanceWithdrawalMaterializationEvidence
            )
        )
signSubmitAndMaterializeWithdrawal
    DevnetGovernanceWithdrawalInitConfig{..}
    registry
    governance
    provider
    submitter
    rewardBeforeSubmit
    success = do
        txHex <- BS.readFile (governanceWithdrawalInitTxBodyPath dgwicRunDir)
        case decodeUnsignedTxHex txHex of
            Left err ->
                pure . Left $
                    GovernanceWithdrawalInitFailure
                        { gwifCode = "withdraw-tx-decode-failed"
                        , gwifMessage =
                            "decode withdrawal tx before signing: "
                                <> renderAttachError err
                        , gwifFailedStep = GovernanceWithdrawalWithdrawSubmit
                        , gwifObservedTxIds =
                            observedFromGovernance governance Nothing
                        , gwifLastObservedRewardLovelace =
                            Just (coinLovelace rewardBeforeSubmit)
                        , gwifEpoch = Nothing
                        , gwifTipSlot = Nothing
                        }
            Right tx -> do
                let signed =
                        addCardanoCliPaymentKeyWitness dgwicSigningKey tx
                    submittedTxId =
                        txIdTx signed
                    submittedTxIdText =
                        renderTxId submittedTxId
                    identity =
                        Report.trIdentity (Report.tbsReport success)
                    txIdText =
                        Report.tiTxId identity
                    observed =
                        observedFromGovernance
                            governance
                            (Just submittedTxIdText)
                if txIdText /= submittedTxIdText
                    then
                        pure . Left $
                            GovernanceWithdrawalInitFailure
                                { gwifCode = "withdraw-tx-id-mismatch"
                                , gwifMessage =
                                    "signed withdrawal tx id "
                                        <> submittedTxIdText
                                        <> " does not match tx-build report "
                                        <> txIdText
                                , gwifFailedStep =
                                    GovernanceWithdrawalWithdrawSubmit
                                , gwifObservedTxIds = observed
                                , gwifLastObservedRewardLovelace =
                                    Just (coinLovelace rewardBeforeSubmit)
                                , gwifEpoch = Nothing
                                , gwifTipSlot = Nothing
                                }
                    else do
                        rewardBefore <-
                            rewardBalance provider (registryTreasuryAccount registry)
                        if rewardBefore /= rewardBeforeSubmit
                            then
                                pure . Left $
                                    GovernanceWithdrawalInitFailure
                                        { gwifCode =
                                            "withdraw-reward-before-mismatch"
                                        , gwifMessage =
                                            "reward before submit changed from "
                                                <> T.pack
                                                    ( show
                                                        ( coinLovelace
                                                            rewardBeforeSubmit
                                                        )
                                                    )
                                                <> " to "
                                                <> T.pack
                                                    ( show
                                                        ( coinLovelace
                                                            rewardBefore
                                                        )
                                                    )
                                        , gwifFailedStep =
                                            GovernanceWithdrawalWithdrawSubmit
                                        , gwifObservedTxIds = observed
                                        , gwifLastObservedRewardLovelace =
                                            Just (coinLovelace rewardBefore)
                                        , gwifEpoch = Nothing
                                        , gwifTipSlot = Nothing
                                        }
                            else do
                                treasuryBefore <-
                                    queryUTxOs
                                        provider
                                        (dgwrTreasuryAddress registry)
                                let treasuryBeforeLovelace =
                                        sumUtxoLovelace treasuryBefore
                                BS.writeFile
                                    ( governanceWithdrawalInitSignedTxPath
                                        dgwicRunDir
                                    )
                                    (encodeSignedTxHex signed)
                                submitTx submitter signed >>= \case
                                    Rejected reason ->
                                        pure . Left $
                                            GovernanceWithdrawalInitFailure
                                                { gwifCode =
                                                    "withdraw-submit-rejected"
                                                , gwifMessage =
                                                    "withdrawal submit rejected: "
                                                        <> decodeUtf8Lenient
                                                            reason
                                                , gwifFailedStep =
                                                    GovernanceWithdrawalWithdrawSubmit
                                                , gwifObservedTxIds = observed
                                                , gwifLastObservedRewardLovelace =
                                                    Just
                                                        ( coinLovelace
                                                            rewardBefore
                                                        )
                                                , gwifEpoch = Nothing
                                                , gwifTipSlot = Nothing
                                                }
                                    Submitted _ -> do
                                        writeFile
                                            ( governanceWithdrawalInitSubmitLogPath
                                                dgwicRunDir
                                            )
                                            ( "submit: accepted "
                                                <> T.unpack submittedTxIdText
                                                <> "\n"
                                            )
                                        verifyMaterialization
                                            dgwicRunDir
                                            registry
                                            governance
                                            success
                                            provider
                                            submittedTxId
                                            submittedTxIdText
                                            rewardBefore
                                            treasuryBeforeLovelace

verifyMaterialization
    :: FilePath
    -> DevnetGovernanceWithdrawalRegistry
    -> GovernanceWithdrawalGovernanceEvidence
    -> Report.TxBuildSuccess
    -> Provider IO
    -> TxId
    -> T.Text
    -> Coin
    -> Integer
    -> IO
        ( Either
            GovernanceWithdrawalInitFailure
            ( GovernanceWithdrawalWithdrawalEvidence
            , GovernanceWithdrawalMaterializationEvidence
            )
        )
verifyMaterialization
    runDir
    registry
    governance
    success
    provider
    submittedTxId
    submittedTxIdText
    rewardBeforeSubmit
    treasuryBeforeLovelace = do
        let materializedRef =
                txOutRef submittedTxId 0
            observed =
                observedFromGovernance governance (Just submittedTxIdText)
            failMaterialization code message lastReward =
                Left
                    GovernanceWithdrawalInitFailure
                        { gwifCode = code
                        , gwifMessage = message
                        , gwifFailedStep =
                            GovernanceWithdrawalMaterializationVerify
                        , gwifObservedTxIds = observed
                        , gwifLastObservedRewardLovelace = lastReward
                        , gwifEpoch = Nothing
                        , gwifTipSlot = Nothing
                        }
        materialized <- waitForMaterializedTxOut provider materializedRef 60
        case materialized of
            Nothing ->
                pure $
                    failMaterialization
                        "materialization-timeout"
                        ( "timed out waiting for materialized treasury UTxO "
                            <> txInToText materializedRef
                        )
                        (Just (coinLovelace rewardBeforeSubmit))
            Just (_, txOut)
                | txOut ^. addrTxOutL /= dgwrTreasuryAddress registry ->
                    pure $
                        failMaterialization
                            "materialization-address-mismatch"
                            "materialized withdrawal output is not at the treasury address"
                            (Just (coinLovelace rewardBeforeSubmit))
                | txOutLovelace txOut /= coinLovelace rewardBeforeSubmit ->
                    pure $
                        failMaterialization
                            "materialization-amount-mismatch"
                            "materialized withdrawal output lovelace does not match submitted reward"
                            (Just (coinLovelace rewardBeforeSubmit))
                | txOutHasAssets txOut ->
                    pure $
                        failMaterialization
                            "materialization-assets-present"
                            "materialized withdrawal output unexpectedly contains native assets"
                            (Just (coinLovelace rewardBeforeSubmit))
                | otherwise -> do
                    rewardAfterSubmit <-
                        rewardBalance provider (registryTreasuryAccount registry)
                    if rewardAfterSubmit /= Coin 0
                        then
                            pure $
                                failMaterialization
                                    "reward-not-drained"
                                    "treasury reward account was not drained after withdrawal submit"
                                    (Just (coinLovelace rewardAfterSubmit))
                        else do
                            treasuryAfter <-
                                queryUTxOs provider (dgwrTreasuryAddress registry)
                            let treasuryAfterLovelace =
                                    sumUtxoLovelace treasuryAfter
                                materializedAda =
                                    txOutLovelace txOut
                            case validateTreasuryMaterializationDelta
                                observed
                                treasuryBeforeLovelace
                                treasuryAfterLovelace
                                materializedAda of
                                Left deltaFailure ->
                                    pure (Left deltaFailure)
                                Right () -> do
                                    let withdrawal =
                                            GovernanceWithdrawalWithdrawalEvidence
                                                { gwweIntentPath =
                                                    governanceWithdrawalInitIntentPath
                                                        runDir
                                                , gwweTxBodyPath =
                                                    governanceWithdrawalInitTxBodyPath
                                                        runDir
                                                , gwweReportJsonPath =
                                                    governanceWithdrawalInitReportJsonPath
                                                        runDir
                                                , gwweReportMarkdownPath =
                                                    governanceWithdrawalInitReportMarkdownPath
                                                        runDir
                                                , gwweTxBuildLogPath =
                                                    governanceWithdrawalInitTxBuildLogPath
                                                        runDir
                                                , gwweSignedTxPath =
                                                    governanceWithdrawalInitSignedTxPath
                                                        runDir
                                                , gwweSubmitLogPath =
                                                    governanceWithdrawalInitSubmitLogPath
                                                        runDir
                                                , gwweTxId =
                                                    Report.tiTxId identity
                                                , gwweSubmittedTxId =
                                                    submittedTxIdText
                                                , gwweFeeLovelace =
                                                    Report.tiFeeLovelace identity
                                                , gwweRewardBeforeSubmitLovelace =
                                                    coinLovelace
                                                        rewardBeforeSubmit
                                                , gwweRewardAfterSubmitLovelace =
                                                    coinLovelace
                                                        rewardAfterSubmit
                                                }
                                        materialization =
                                            GovernanceWithdrawalMaterializationEvidence
                                                { gwmeGovernanceActionId =
                                                    gwgeGovernanceActionId
                                                        governance
                                                , gwmeTreasuryRewardAccount =
                                                    gwgeTreasuryRewardAccount
                                                        governance
                                                , gwmeSubmittedTxId =
                                                    submittedTxIdText
                                                , gwmeTreasuryMaterializedTxIn =
                                                    txInToText materializedRef
                                                , gwmeTreasuryAddress =
                                                    dgwrTreasuryAddressText
                                                        registry
                                                , gwmeMaterializedAdaLovelace =
                                                    materializedAda
                                                , gwmeRewardBeforeSubmitLovelace =
                                                    coinLovelace
                                                        rewardBeforeSubmit
                                                , gwmeRewardAfterSubmitLovelace =
                                                    coinLovelace
                                                        rewardAfterSubmit
                                                , gwmeTreasuryUtxoLovelaceBefore =
                                                    treasuryBeforeLovelace
                                                , gwmeTreasuryUtxoLovelaceAfter =
                                                    treasuryAfterLovelace
                                                }
                                    pure (Right (withdrawal, materialization))
      where
        identity =
            Report.trIdentity (Report.tbsReport success)

governanceWithdrawalInitDirectory :: FilePath -> FilePath
governanceWithdrawalInitDirectory runDir =
    runDir </> "governance-withdrawal-init"

governanceWithdrawalInitSummaryPath :: FilePath -> FilePath
governanceWithdrawalInitSummaryPath runDir =
    governanceWithdrawalInitDirectory runDir </> "summary.json"

governanceWithdrawalInitGovernancePath :: FilePath -> FilePath
governanceWithdrawalInitGovernancePath runDir =
    governanceWithdrawalInitDirectory runDir </> "governance.json"

governanceWithdrawalInitWithdrawalPath :: FilePath -> FilePath
governanceWithdrawalInitWithdrawalPath runDir =
    governanceWithdrawalInitDirectory runDir </> "withdrawal.json"

governanceWithdrawalInitMaterializationPath :: FilePath -> FilePath
governanceWithdrawalInitMaterializationPath runDir =
    governanceWithdrawalInitDirectory runDir </> "materialized.json"

governanceWithdrawalInitProvenancePath :: FilePath -> FilePath
governanceWithdrawalInitProvenancePath runDir =
    governanceWithdrawalInitDirectory runDir </> "provenance.json"

governanceWithdrawalInitFailurePath :: FilePath -> FilePath
governanceWithdrawalInitFailurePath runDir =
    governanceWithdrawalInitDirectory runDir </> "failure.json"

governanceWithdrawalInitIntentPath :: FilePath -> FilePath
governanceWithdrawalInitIntentPath runDir =
    governanceWithdrawalInitDirectory runDir </> "intent.json"

governanceWithdrawalInitTxBodyPath :: FilePath -> FilePath
governanceWithdrawalInitTxBodyPath runDir =
    governanceWithdrawalInitDirectory runDir </> "tx-body.cbor.hex"

governanceWithdrawalInitReportJsonPath :: FilePath -> FilePath
governanceWithdrawalInitReportJsonPath runDir =
    governanceWithdrawalInitDirectory runDir </> "report.json"

governanceWithdrawalInitReportMarkdownPath :: FilePath -> FilePath
governanceWithdrawalInitReportMarkdownPath runDir =
    governanceWithdrawalInitDirectory runDir </> "report.md"

governanceWithdrawalInitTxBuildLogPath :: FilePath -> FilePath
governanceWithdrawalInitTxBuildLogPath runDir =
    governanceWithdrawalInitDirectory runDir </> "tx-build.log"

governanceWithdrawalInitSignedTxPath :: FilePath -> FilePath
governanceWithdrawalInitSignedTxPath runDir =
    governanceWithdrawalInitDirectory runDir </> "signed-tx.cbor.hex"

governanceWithdrawalInitSubmitLogPath :: FilePath -> FilePath
governanceWithdrawalInitSubmitLogPath runDir =
    governanceWithdrawalInitDirectory runDir </> "submit.log"

governanceWithdrawalInitSummaryValue
    :: Int -> FilePath -> GovernanceWithdrawalInitResult -> Value
governanceWithdrawalInitSummaryValue networkMagic runDir result =
    object
        [ "phase" .= ("governance-withdrawal-init" :: T.Text)
        , "status" .= ("passed" :: T.Text)
        , "network" .= ("devnet" :: T.Text)
        , "networkMagic" .= networkMagic
        , "runDirectory" .= runDir
        , "registryPath" .= gwirRegistryPath result
        , "stakeRewardPath" .= gwirStakeRewardPath result
        , "amountLovelace"
            .= gwgeAmountLovelace (gwirGovernance result)
        , "governancePath" .= governanceWithdrawalInitGovernancePath runDir
        , "withdrawalPath" .= governanceWithdrawalInitWithdrawalPath runDir
        , "materializationPath"
            .= governanceWithdrawalInitMaterializationPath runDir
        , "provenancePath" .= governanceWithdrawalInitProvenancePath runDir
        ]

governanceWithdrawalInitGovernanceValue
    :: GovernanceWithdrawalInitResult -> Value
governanceWithdrawalInitGovernanceValue result =
    let g = gwirGovernance result
    in  object
            [ "phase" .= ("governance-withdrawal-init" :: T.Text)
            , "network" .= ("devnet" :: T.Text)
            , "proposalTxId" .= gwgeProposalTxId g
            , "governanceActionId" .= gwgeGovernanceActionId g
            , "voteTxId" .= gwgeVoteTxId g
            , "treasuryRewardAccount" .= gwgeTreasuryRewardAccount g
            , "treasuryScriptHash" .= gwgeTreasuryScriptHash g
            , "amountLovelace" .= gwgeAmountLovelace g
            , "rewardBeforeLovelace" .= gwgeRewardBeforeLovelace g
            , "rewardAfterGovernanceLovelace"
                .= gwgeRewardAfterGovernanceLovelace g
            , "setupEpoch" .= gwgeSetupEpoch g
            , "voteEpoch" .= gwgeVoteEpoch g
            , "finalEpoch" .= gwgeFinalEpoch g
            ]

governanceWithdrawalInitWithdrawalValue
    :: GovernanceWithdrawalInitResult -> Value
governanceWithdrawalInitWithdrawalValue result =
    let w = gwirWithdrawal result
    in  object
            [ "phase" .= ("governance-withdrawal-init" :: T.Text)
            , "network" .= ("devnet" :: T.Text)
            , "intentPath" .= gwweIntentPath w
            , "txBodyPath" .= gwweTxBodyPath w
            , "reportJsonPath" .= gwweReportJsonPath w
            , "reportMarkdownPath" .= gwweReportMarkdownPath w
            , "txBuildLogPath" .= gwweTxBuildLogPath w
            , "signedTxPath" .= gwweSignedTxPath w
            , "submitLogPath" .= gwweSubmitLogPath w
            , "txId" .= gwweTxId w
            , "submittedTxId" .= gwweSubmittedTxId w
            , "feeLovelace" .= gwweFeeLovelace w
            , "rewardBeforeSubmitLovelace"
                .= gwweRewardBeforeSubmitLovelace w
            , "rewardAfterSubmitLovelace"
                .= gwweRewardAfterSubmitLovelace w
            ]

governanceWithdrawalInitMaterializationValue
    :: GovernanceWithdrawalInitResult -> Value
governanceWithdrawalInitMaterializationValue result =
    let m = gwirMaterialization result
    in  object
            [ "phase" .= ("governance-withdrawal-init" :: T.Text)
            , "network" .= ("devnet" :: T.Text)
            , "governanceActionId" .= gwmeGovernanceActionId m
            , "treasuryRewardAccount" .= gwmeTreasuryRewardAccount m
            , "submittedTxId" .= gwmeSubmittedTxId m
            , "treasuryMaterializedTxIn"
                .= gwmeTreasuryMaterializedTxIn m
            , "treasuryAddress" .= gwmeTreasuryAddress m
            , "materializedAdaLovelace" .= gwmeMaterializedAdaLovelace m
            , "rewardBeforeSubmitLovelace"
                .= gwmeRewardBeforeSubmitLovelace m
            , "rewardAfterSubmitLovelace"
                .= gwmeRewardAfterSubmitLovelace m
            , "treasuryUtxoLovelaceBefore"
                .= gwmeTreasuryUtxoLovelaceBefore m
            , "treasuryUtxoLovelaceAfter"
                .= gwmeTreasuryUtxoLovelaceAfter m
            , "registryPath" .= gwirRegistryPath result
            , "stakeRewardPath" .= gwirStakeRewardPath result
            ]

governanceWithdrawalInitProvenanceValue :: Value
governanceWithdrawalInitProvenanceValue =
    object
        [ "phase" .= ("governance-withdrawal-init" :: T.Text)
        , "source" .= ("amaru-treasury-tx" :: T.Text)
        , "issue" .= (149 :: Int)
        , "parentIssue" .= (151 :: Int)
        , "dependsOnIssues" .= ([147, 148] :: [Int])
        ]

governanceWithdrawalInitFailureValue
    :: FilePath -> GovernanceWithdrawalInitFailure -> Value
governanceWithdrawalInitFailureValue runDir failure' =
    object
        [ "phase" .= ("governance-withdrawal-init" :: T.Text)
        , "status" .= ("failed" :: T.Text)
        , "code" .= gwifCode failure'
        , "message" .= gwifMessage failure'
        , "failedStep" .= failureStepText (gwifFailedStep failure')
        , "observedTxIds"
            .= object
                [ "proposal" .= gwoProposal observed
                , "vote" .= gwoVote observed
                , "withdrawal" .= gwoWithdrawal observed
                ]
        , "lastObservedRewardLovelace"
            .= gwifLastObservedRewardLovelace failure'
        , "epoch" .= gwifEpoch failure'
        , "tipSlot" .= gwifTipSlot failure'
        , "summaryPath" .= governanceWithdrawalInitFailurePath runDir
        ]
  where
    observed =
        gwifObservedTxIds failure'

governanceWithdrawalInitCommandLines
    :: Int -> FilePath -> GovernanceWithdrawalInitResult -> [String]
governanceWithdrawalInitCommandLines networkMagic runDir result =
    [ "governance-withdrawal-init: run-dir " <> runDir
    , "governance-withdrawal-init: network devnet magic "
        <> show networkMagic
    , "governance-withdrawal-init: phase governance-withdrawal-init passed"
    , "governance-withdrawal-init: governance-proposal-tx-id "
        <> T.unpack (gwgeProposalTxId governance)
    , "governance-withdrawal-init: governance-action-id "
        <> T.unpack (gwgeGovernanceActionId governance)
    , "governance-withdrawal-init: vote-tx-id "
        <> T.unpack (gwgeVoteTxId governance)
    , "governance-withdrawal-init: treasury-reward-account "
        <> T.unpack (gwgeTreasuryRewardAccount governance)
    , "governance-withdrawal-init: reward-before-lovelace "
        <> show (gwgeRewardBeforeLovelace governance)
    , "governance-withdrawal-init: reward-after-governance-lovelace "
        <> show (gwgeRewardAfterGovernanceLovelace governance)
    , "governance-withdrawal-init: withdraw-tx-id "
        <> T.unpack (gwweTxId withdrawal)
    , "governance-withdrawal-init: withdraw-submitted-tx-id "
        <> T.unpack (gwweSubmittedTxId withdrawal)
    , "governance-withdrawal-init: treasury-materialized-tx-in "
        <> T.unpack (gwmeTreasuryMaterializedTxIn materialization)
    , "governance-withdrawal-init: treasury-materialized-ada "
        <> show (gwmeMaterializedAdaLovelace materialization)
    , "governance-withdrawal-init: summary "
        <> governanceWithdrawalInitSummaryPath runDir
    , "governance-withdrawal-init: materialization "
        <> governanceWithdrawalInitMaterializationPath runDir
    ]
  where
    governance =
        gwirGovernance result
    withdrawal =
        gwirWithdrawal result
    materialization =
        gwirMaterialization result

governanceWithdrawalInitFailureLines
    :: FilePath -> GovernanceWithdrawalInitFailure -> [String]
governanceWithdrawalInitFailureLines runDir failure' =
    [ "governance-withdrawal-init: run-dir " <> runDir
    , "governance-withdrawal-init: phase governance-withdrawal-init failed"
    , "governance-withdrawal-init: "
        <> T.unpack (gwifCode failure')
        <> ": "
        <> T.unpack (gwifMessage failure')
    , "governance-withdrawal-init: failure "
        <> governanceWithdrawalInitFailurePath runDir
    ]

writeGovernanceWithdrawalInitArtifactsWithLines
    :: Int
    -> FilePath
    -> GovernanceWithdrawalInitResult
    -> [String]
    -> IO ()
writeGovernanceWithdrawalInitArtifactsWithLines
    networkMagic
    runDir
    result
    linesOut = do
        let summary =
                governanceWithdrawalInitSummaryValue
                    networkMagic
                    runDir
                    result
        createDirectoryIfMissing
            True
            (governanceWithdrawalInitDirectory runDir)
        removeIfExists (governanceWithdrawalInitFailurePath runDir)
        BSL.writeFile
            (governanceWithdrawalInitSummaryPath runDir)
            (encode summary)
        BSL.writeFile
            (governanceWithdrawalInitGovernancePath runDir)
            (encode (governanceWithdrawalInitGovernanceValue result))
        BSL.writeFile
            (governanceWithdrawalInitWithdrawalPath runDir)
            (encode (governanceWithdrawalInitWithdrawalValue result))
        BSL.writeFile
            (governanceWithdrawalInitMaterializationPath runDir)
            (encode (governanceWithdrawalInitMaterializationValue result))
        BSL.writeFile
            (governanceWithdrawalInitProvenancePath runDir)
            (encode governanceWithdrawalInitProvenanceValue)
        BSL.writeFile (runDir </> "summary.json") (encode summary)
        writeFile (runDir </> "summary.log") (unlines linesOut)

writeGovernanceWithdrawalInitFailure
    :: FilePath -> GovernanceWithdrawalInitFailure -> IO ()
writeGovernanceWithdrawalInitFailure runDir failure' = do
    let value =
            governanceWithdrawalInitFailureValue runDir failure'
        linesOut =
            governanceWithdrawalInitFailureLines runDir failure'
    createDirectoryIfMissing
        True
        (governanceWithdrawalInitDirectory runDir)
    removeSuccessSummaries runDir
    BSL.writeFile
        (governanceWithdrawalInitFailurePath runDir)
        (encode value)
    BSL.writeFile (runDir </> "summary.json") (encode value)
    writeFile (runDir </> "summary.log") (unlines linesOut)

failureStepText :: GovernanceWithdrawalInitFailureStep -> T.Text
failureStepText = \case
    GovernanceWithdrawalValidateInputs -> "validate-inputs"
    GovernanceWithdrawalGovernanceBuild -> "governance-build"
    GovernanceWithdrawalGovernanceSubmit -> "governance-submit"
    GovernanceWithdrawalVoteSubmit -> "vote-submit"
    GovernanceWithdrawalRewardWait -> "reward-wait"
    GovernanceWithdrawalWithdrawIntent -> "withdraw-intent"
    GovernanceWithdrawalWithdrawBuild -> "withdraw-build"
    GovernanceWithdrawalWithdrawSubmit -> "withdraw-submit"
    GovernanceWithdrawalMaterializationVerify -> "materialization-verify"

registryViewFromArtifact
    :: DevnetGovernanceWithdrawalRegistry -> RegistryView
registryViewFromArtifact registry =
    RegistryView
        { rvScopesDeployedAt = txInToText (dgwrScopesRef registry)
        , rvPermissionsDeployedAt = txInToText (dgwrPermissionsRef registry)
        , rvTreasuryDeployedAt = txInToText (dgwrTreasuryRef registry)
        , rvRegistryDeployedAt = txInToText (dgwrRegistryRef registry)
        , rvRegistryPolicyId = dgwrRegistryPolicyId registry
        , rvOwners =
            ScopeOwners
                { soCore = owner
                , soOps = owner
                , soNetworkCompliance = owner
                , soMiddleware = owner
                }
        , rvTreasuryByScope =
            Map.singleton
                CoreDevelopment
                TreasuryRefs
                    { trAddress = dgwrTreasuryAddressText registry
                    , trScriptHash = dgwrTreasuryScriptHashText registry
                    , trPermissionsRewardAccount =
                        dgwrPermissionsScriptHashText registry
                    }
        }
  where
    owner =
        dgwrOwnerKeyHash registry

registryTreasuryAccount
    :: DevnetGovernanceWithdrawalRegistry -> AccountAddress
registryTreasuryAccount registry =
    AccountAddress
        Testnet
        (AccountId (ScriptHashObj (dgwrTreasuryScriptHash registry)))

queryWalletUtxosForWithdraw
    :: Provider IO
    -> Addr
    -> T.Text
    -> IO [(T.Text, Integer, Bool)]
queryWalletUtxosForWithdraw provider fundingAddress _requestedWallet = do
    utxos <- queryUTxOs provider fundingAddress
    pure
        [ (txInToText txIn, lovelace, not (Map.null assets))
        | (txIn, txOut) <- utxos
        , let MaryValue (Coin lovelace) (MultiAsset assets) =
                txOut ^. valueTxOutL
        ]

readWithdrawalTxBuildFailure
    :: FilePath -> IO (Maybe Report.BuildFailure)
readWithdrawalTxBuildFailure runDir = do
    let path = governanceWithdrawalInitReportJsonPath runDir
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
    :: String
    -> [(TxIn, TxOut ConwayEra)]
    -> IO (TxIn, TxOut ConwayEra)
selectLargestAdaUtxo label utxos =
    case foldr choose Nothing utxos of
        Just (_, selected) -> pure selected
        Nothing -> fail ("no pure-ADA UTxO for " <> label)
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

waitForTxChange :: Provider IO -> TxId -> Addr -> Int -> IO ()
waitForTxChange _ txId _ attempts
    | attempts <= 0 =
        fail $
            "timed out waiting for tx change output: " <> show txId
waitForTxChange provider txId addr attempts = do
    utxos <- queryUTxOs provider addr
    if any (hasTxId txId . fst) utxos
        then pure ()
        else do
            threadDelay 500_000
            waitForTxChange provider txId addr (attempts - 1)

waitForUtxos
    :: Provider IO
    -> Addr
    -> Int
    -> IO [(TxIn, TxOut ConwayEra)]
waitForUtxos _ _ attempts
    | attempts <= 0 = pure []
waitForUtxos provider addr attempts = do
    utxos <- queryUTxOs provider addr
    if null utxos
        then do
            threadDelay 500_000
            waitForUtxos provider addr (attempts - 1)
        else pure utxos

waitForEpochAfter :: Provider IO -> EpochNo -> Int -> IO ()
waitForEpochAfter _ epoch attempts
    | attempts <= 0 =
        fail ("timed out waiting for epoch after " <> show epoch)
waitForEpochAfter provider epoch attempts = do
    snapshot <- queryLedgerSnapshot provider
    if epochNumber (ledgerEpoch snapshot) > epochNumber epoch
        then pure ()
        else do
            threadDelay 500_000
            waitForEpochAfter provider epoch (attempts - 1)

waitForRewardIncrease
    :: Provider IO
    -> AccountAddress
    -> EpochNo
    -> Coin
    -> Coin
    -> Int
    -> IO (Either (Coin, Maybe Word64, Maybe Word64) Coin)
waitForRewardIncrease provider account submittedEpoch before expected =
    go
  where
    go attempts
        | attempts <= 0 = do
            snapshot <- queryLedgerSnapshot provider
            lastReward <- rewardBalance provider account
            pure $
                Left
                    ( lastReward
                    , Just (epochNumber (ledgerEpoch snapshot))
                    , Just (slotNumber (ledgerTipSlot snapshot))
                    )
        | otherwise = do
            snapshot <- queryLedgerSnapshot provider
            after <- rewardBalance provider account
            if epochNumber (ledgerEpoch snapshot)
                > epochNumber submittedEpoch
                && after == addCoin before expected
                then pure (Right after)
                else do
                    threadDelay 500_000
                    go (attempts - 1)

waitForMaterializedTxOut
    :: Provider IO
    -> TxIn
    -> Int
    -> IO (Maybe (TxIn, TxOut ConwayEra))
waitForMaterializedTxOut _ _ attempts
    | attempts <= 0 = pure Nothing
waitForMaterializedTxOut provider ref attempts = do
    found <- queryUTxOByTxIn provider (Set.singleton ref)
    case Map.lookup ref found of
        Just txOut -> pure (Just (ref, txOut))
        Nothing -> do
            threadDelay 500_000
            waitForMaterializedTxOut provider ref (attempts - 1)

rewardBalance :: Provider IO -> AccountAddress -> IO Coin
rewardBalance provider account =
    Map.findWithDefault (Coin 0) account
        <$> queryRewardAccounts provider (Set.singleton account)

epochTip :: Provider IO -> IO (Maybe Word64, Maybe Word64)
epochTip provider = do
    snapshot <- queryLedgerSnapshot provider
    pure
        ( Just (epochNumber (ledgerEpoch snapshot))
        , Just (slotNumber (ledgerTipSlot snapshot))
        )

failureFromSnapshot
    :: T.Text
    -> T.Text
    -> GovernanceWithdrawalInitFailureStep
    -> GovernanceWithdrawalObservedTxIds
    -> Maybe Integer
    -> LedgerSnapshot
    -> GovernanceWithdrawalInitFailure
failureFromSnapshot code message failedStep txIds lastReward snapshot =
    GovernanceWithdrawalInitFailure
        { gwifCode = code
        , gwifMessage = message
        , gwifFailedStep = failedStep
        , gwifObservedTxIds = txIds
        , gwifLastObservedRewardLovelace = lastReward
        , gwifEpoch = Just (epochNumber (ledgerEpoch snapshot))
        , gwifTipSlot = Just (slotNumber (ledgerTipSlot snapshot))
        }

failureWithoutSnapshot
    :: T.Text
    -> T.Text
    -> GovernanceWithdrawalInitFailureStep
    -> GovernanceWithdrawalObservedTxIds
    -> Maybe Integer
    -> Maybe Word64
    -> Maybe Word64
    -> GovernanceWithdrawalInitFailure
failureWithoutSnapshot code message failedStep txIds lastReward epoch tipSlot =
    GovernanceWithdrawalInitFailure
        { gwifCode = code
        , gwifMessage = message
        , gwifFailedStep = failedStep
        , gwifObservedTxIds = txIds
        , gwifLastObservedRewardLovelace = lastReward
        , gwifEpoch = epoch
        , gwifTipSlot = tipSlot
        }

withdrawResolverFailure
    :: GovernanceWithdrawalGovernanceEvidence
    -> Coin
    -> Maybe Word64
    -> Maybe Word64
    -> Withdraw.WithdrawResolverError
    -> GovernanceWithdrawalInitFailure
withdrawResolverFailure governance rewards epoch tipSlot err =
    case err of
        Withdraw.WithdrawResolverNetworkMismatch expected observed ->
            failureWithoutSnapshot
                "network-mismatch"
                ( "withdraw intent network "
                    <> expected
                    <> " does not match observed "
                    <> observed
                )
                GovernanceWithdrawalWithdrawIntent
                (observedFromGovernance governance Nothing)
                (Just (coinLovelace rewards))
                epoch
                tipSlot
        _ ->
            failureWithoutSnapshot
                "resolver-failed"
                ("withdraw resolver failed: " <> T.pack (show err))
                GovernanceWithdrawalWithdrawIntent
                (observedFromGovernance governance Nothing)
                (Just (coinLovelace rewards))
                epoch
                tipSlot

withdrawIntentFailure
    :: GovernanceWithdrawalGovernanceEvidence
    -> Coin
    -> Maybe Word64
    -> Maybe Word64
    -> Withdraw.WithdrawError
    -> GovernanceWithdrawalInitFailure
withdrawIntentFailure governance rewards epoch tipSlot err =
    case err of
        Withdraw.WithdrawNetworkMismatch expected observed ->
            failureWithoutSnapshot
                "network-mismatch"
                ( "withdraw intent network "
                    <> expected
                    <> " does not match observed "
                    <> observed
                )
                GovernanceWithdrawalWithdrawIntent
                (observedFromGovernance governance Nothing)
                (Just (coinLovelace rewards))
                epoch
                tipSlot
        _ ->
            failureWithoutSnapshot
                "intent-failed"
                ("withdraw intent translation failed: " <> T.pack (show err))
                GovernanceWithdrawalWithdrawIntent
                (observedFromGovernance governance Nothing)
                (Just (coinLovelace rewards))
                epoch
                tipSlot

observedFromGovernance
    :: GovernanceWithdrawalGovernanceEvidence
    -> Maybe T.Text
    -> GovernanceWithdrawalObservedTxIds
observedFromGovernance governance =
    observedTxIds
        (Just (gwgeProposalTxId governance))
        (Just (gwgeVoteTxId governance))

observedTxIds
    :: Maybe T.Text
    -> Maybe T.Text
    -> Maybe T.Text
    -> GovernanceWithdrawalObservedTxIds
observedTxIds proposal voteTx withdrawal =
    GovernanceWithdrawalObservedTxIds
        { gwoProposal = proposal
        , gwoVote = voteTx
        , gwoWithdrawal = withdrawal
        }

emptyObservedTxIds :: GovernanceWithdrawalObservedTxIds
emptyObservedTxIds =
    observedTxIds Nothing Nothing Nothing

removeStaleWithdrawalArtifacts :: FilePath -> IO ()
removeStaleWithdrawalArtifacts runDir =
    mapM_
        removeIfExists
        [ governanceWithdrawalInitTxBodyPath runDir
        , governanceWithdrawalInitReportJsonPath runDir
        , governanceWithdrawalInitReportMarkdownPath runDir
        , governanceWithdrawalInitTxBuildLogPath runDir
        , governanceWithdrawalInitSignedTxPath runDir
        , governanceWithdrawalInitSubmitLogPath runDir
        , governanceWithdrawalInitMaterializationPath runDir
        ]

removeSuccessSummaries :: FilePath -> IO ()
removeSuccessSummaries runDir =
    mapM_
        removeIfExists
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

validateTreasuryMaterializationDelta
    :: GovernanceWithdrawalObservedTxIds
    -> Integer
    -> Integer
    -> Integer
    -> Either GovernanceWithdrawalInitFailure ()
validateTreasuryMaterializationDelta
    observed
    treasuryBeforeLovelace
    treasuryAfterLovelace
    expectedDelta
        | observedDelta == expectedDelta =
            Right ()
        | otherwise =
            Left
                GovernanceWithdrawalInitFailure
                    { gwifCode = "materialization-treasury-delta-mismatch"
                    , gwifMessage =
                        "treasury UTxO lovelace delta "
                            <> T.pack (show observedDelta)
                            <> " does not match materialized ADA "
                            <> T.pack (show expectedDelta)
                    , gwifFailedStep = GovernanceWithdrawalMaterializationVerify
                    , gwifObservedTxIds = observed
                    , gwifLastObservedRewardLovelace = Just 0
                    , gwifEpoch = Nothing
                    , gwifTipSlot = Nothing
                    }
      where
        observedDelta =
            treasuryAfterLovelace - treasuryBeforeLovelace

removeIfExists :: FilePath -> IO ()
removeIfExists path = do
    exists <- doesFileExist path
    when exists (removeFile path)

governanceAnchor :: Anchor
governanceAnchor =
    Anchor
        ( fromJust $
            textToUrl
                128
                "https://example.invalid/amaru-devnet-governance.json"
        )
        (unsafeMakeSafeHash (mkHash32 42))

voterSignKey :: SignKeyDSIGN DSIGN
voterSignKey =
    fromJust $
        rawDeserialiseSignKeyDSIGN @DSIGN
            (BS8.pack "amaru-governance-voter-key-00001")

stakeCredentialFromSignKey
    :: SignKeyDSIGN DSIGN
    -> Credential Staking
stakeCredentialFromSignKey =
    KeyHashObj . stakeKeyHashFromSignKey

stakeKeyHashFromSignKey
    :: SignKeyDSIGN DSIGN
    -> KeyHash Staking
stakeKeyHashFromSignKey =
    hashKey
        . VKey
        . deriveVerKeyDSIGN

drepCredentialFromSignKey
    :: SignKeyDSIGN DSIGN
    -> Credential DRepRole
drepCredentialFromSignKey =
    KeyHashObj . drepKeyHashFromSignKey

drepKeyHashFromSignKey
    :: SignKeyDSIGN DSIGN
    -> KeyHash DRepRole
drepKeyHashFromSignKey =
    hashKey
        . VKey
        . deriveVerKeyDSIGN

paymentKeyHashFromSignKey
    :: SignKeyDSIGN DSIGN
    -> KeyHash Payment
paymentKeyHashFromSignKey =
    hashKey
        . VKey
        . deriveVerKeyDSIGN

baseAddrFromSignKey
    :: SignKeyDSIGN DSIGN
    -> Credential Staking
    -> Addr
baseAddrFromSignKey sk stakeCredential =
    Addr
        Testnet
        (KeyHashObj (paymentKeyHashFromSignKey sk))
        (StakeRefBase stakeCredential)

txOutRef :: TxId -> Integer -> TxIn
txOutRef txId ix =
    TxIn txId (mkTxIxPartial ix)

hasTxId :: TxId -> TxIn -> Bool
hasTxId txId (TxIn utxoTxId _) =
    txId == utxoTxId

addCoin :: Coin -> Coin -> Coin
addCoin (Coin a) (Coin b) =
    Coin (a + b)

coinLovelace :: Coin -> Integer
coinLovelace (Coin lovelace) =
    lovelace

sumUtxoLovelace :: [(TxIn, TxOut ConwayEra)] -> Integer
sumUtxoLovelace =
    sum . fmap (txOutLovelace . snd)

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

epochNumber :: EpochNo -> Word64
epochNumber (EpochNo epoch) =
    epoch

rewardWaitAttempts :: Int -> Int
rewardWaitAttempts seconds =
    max 1 (seconds * 2)

renderAddr :: Addr -> T.Text
renderAddr addr =
    Bech32.encodeLenient
        hrp
        (Bech32.dataPartFromBytes (serialiseAddr addr))
  where
    hrp =
        either
            (error . ("renderAddr: " <>) . show)
            id
            (Bech32.humanReadablePartFromText (addressHrp addr))
    addressHrp target =
        case getNetwork target of
            Mainnet -> "addr"
            Testnet -> "addr_test"

decodeUtf8Lenient :: BS8.ByteString -> T.Text
decodeUtf8Lenient =
    TE.decodeUtf8With (\_ _ -> Just '?')

parseEitherText
    :: (MonadFail m)
    => String
    -> (T.Text -> Either String a)
    -> T.Text
    -> m a
parseEitherText label parser input =
    case parser input of
        Left err -> fail (label <> ": " <> err)
        Right ok -> pure ok

mkHash32 :: (HashAlgorithm h) => Word8 -> Hash h a
mkHash32 n =
    fromJust . hashFromBytes . BS.pack $
        replicate 31 0 ++ [n]
