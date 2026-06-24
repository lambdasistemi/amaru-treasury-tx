{-# LANGUAGE DataKinds #-}
{-# LANGUAGE EmptyCase #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

{- |
Module      : Amaru.Treasury.Devnet.SmokeSpec
Description : Opt-in local cardano-node-clients devnet smoke
License     : Apache-2.0

This suite is intentionally not part of @just ci@. It starts a real
local @cardano-node@ through @cardano-node-clients:devnet@ and records
release-evidence artifacts for manual verification.
-}
module Amaru.Treasury.Devnet.SmokeSpec (spec) where

import Cardano.Crypto.DSIGN
    ( Ed25519DSIGN
    , SignKeyDSIGN
    , deriveVerKeyDSIGN
    , rawSerialiseSignKeyDSIGN
    )
import Cardano.Crypto.Hash
    ( Hash
    , HashAlgorithm
    , hashFromBytes
    )
import Cardano.Crypto.Hash.Blake2b (Blake2b_256)
import Cardano.Crypto.Hash.Class (hashToBytes, hashWith)
import Cardano.Ledger.Address
    ( AccountAddress (..)
    , AccountId (..)
    , Addr (..)
    , getNetwork
    , serialiseAddr
    )
import Cardano.Ledger.Alonzo.Scripts
    ( AsIx
    , fromPlutusScript
    , mkPlutusScript
    )
import Cardano.Ledger.Api.Tx (txIdTx)
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , addrTxOutL
    , datumTxOutL
    , mkBasicTxOut
    , referenceScriptTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.BaseTypes
    ( Inject (..)
    , Network (..)
    , StrictMaybe (SJust, SNothing)
    , mkTxIxPartial
    , textToUrl
    , txIxToInt
    )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Conway.Governance (Anchor (..))
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose)
import Cardano.Ledger.Core (PParams, Script)
import Cardano.Ledger.Core qualified as Core
import Cardano.Ledger.Credential
    ( Credential (..)
    , StakeReference (..)
    )
import Cardano.Ledger.Hashes
    ( KeyHash (..)
    , ScriptHash (..)
    , extractHash
    , unsafeMakeSafeHash
    )
import Cardano.Ledger.Keys
    ( KeyRole (DRepRole, Guard, Payment, Staking)
    , VKey (..)
    , hashKey
    )
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.Plutus.Data (mkInlineDatum)
import Cardano.Ledger.Plutus.ExUnits (ExUnits)
import Cardano.Ledger.Plutus.Language
    ( Language (PlutusV3)
    , Plutus (..)
    , PlutusBinary (..)
    )
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Cardano.Node.Client.E2E.Devnet
    ( withCardanoNode
    )
import Cardano.Node.Client.E2E.Setup
    ( addKeyWitness
    , devnetMagic
    , genesisAddr
    , genesisDir
    , genesisSignKey
    , mkSignKey
    )
import Cardano.Node.Client.N2C.Connection
    ( newLSQChannel
    , newLTxSChannel
    , runNodeClient
    )
import Cardano.Node.Client.N2C.Provider (mkN2CProvider)
import Cardano.Node.Client.N2C.Submitter (mkN2CSubmitter)
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
    ( CertWitness (..)
    , ConwayDelegCert (..)
    , ConwayGovCert (..)
    , ConwayTxCert (..)
    , DRep (..)
    , Delegatee (..)
    , GovActionId (..)
    , GovActionIx (..)
    , InterpretIO (..)
    , ProposalWitness (..)
    , TxBuild
    , TxInstr (..)
    , Vote (..)
    , Voter (..)
    , attachScript
    , build
    , certify
    , checkMinUtxo
    , collateral
    , mint
    , mkPParamsBound
    , output
    , payTo
    , proposeTreasuryWithdrawal
    , reference
    , registerAndVoteAbstain
    , spend
    , spendScript
    , validFrom
    , validTo
    , vote
    , withdrawScript
    )
import Cardano.Tx.Ledger (ConwayTx)
import Codec.Binary.Bech32 qualified as Bech32
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (poll, withAsync)
import Control.Exception (SomeException, try)
import Control.Monad (unless, when)
import Control.Monad.Operational (singleton)
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
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as BSL
import Data.ByteString.Short qualified as SBS
import Data.Foldable (traverse_)
import Data.Function ((&))
import Data.Map.Strict qualified as Map
import Data.Maybe (fromJust, fromMaybe)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Data.Void (Void)
import Data.Word (Word64, Word8)
import Lens.Micro
    ( (.~)
    , (^.)
    )
import PlutusCore.Data (Data (..))
import System.Directory
    ( copyFile
    , createDirectoryIfMissing
    , doesDirectoryExist
    , doesFileExist
    , getCurrentDirectory
    , getTemporaryDirectory
    , listDirectory
    , makeAbsolute
    , removeFile
    , removePathForcibly
    , withCurrentDirectory
    )
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath
    ( takeDirectory
    , (</>)
    )
import System.Posix.Files
    ( ownerReadMode
    , setFileMode
    )
import System.Process (readProcessWithExitCode)
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    , shouldSatisfy
    )
import Text.Read (readMaybe)

import Amaru.Treasury.Backend.N2C
    ( probeNetworkMagic
    )
import Amaru.Treasury.Cli.Common
    ( GlobalOpts (..)
    )
import Amaru.Treasury.Devnet.DisburseSubmit qualified as DisburseSubmit
import Amaru.Treasury.Devnet.GovernanceWithdrawalInit qualified as GovernanceWithdrawalInit
import Amaru.Treasury.Devnet.MixedUtxoSmoke (mixedUtxoSmoke)
import Amaru.Treasury.Devnet.RegistryInit
    ( DevnetRegistryAnchors (..)
    , DevnetRegistryPublication (..)
    , TreasuryTarget (..)
    )
import Amaru.Treasury.Devnet.RegistryInit qualified as RegistryInit
import Amaru.Treasury.Devnet.Runner
    ( DevnetDisburseSubmitOpts (..)
    , DevnetGovernanceWithdrawalInitOpts (..)
    , DevnetRegistryInitOpts (..)
    , DevnetStakeRewardInitOpts (..)
    , runDevnetDisburseSubmit
    , runDevnetGovernanceWithdrawalInit
    , runDevnetRegistryInit
    , runDevnetStakeRewardInit
    )
import Amaru.Treasury.Devnet.StakeRewardInit qualified as StakeRewardInit
import Amaru.Treasury.Devnet.SwapSubmit
    ( FullSwapInputs (..)
    , TreasuryFullSwapEvidence (..)
    , mkFullSwapIntent
    , permissionsRewardAccount
    , treasuryFullSwapLines
    , treasuryFullSwapValue
    )
import Amaru.Treasury.Redeemer
    ( RawPlutusData (..)
    , emptyListRedeemer
    )
import Amaru.Treasury.Registry.Derive
    ( ScriptParam (..)
    , applyScriptParams
    , derivedTreasuryScriptBlob
    , scriptHashOfBlob
    , scriptHashToHex
    )
import Amaru.Treasury.Report qualified as Report
import Amaru.Treasury.Scope
    ( ScopeId (CoreDevelopment)
    )
import Amaru.Treasury.Sundae.Contracts
    ( sundaeOrderValidatorBlob
    , sundaeOrderValidatorScriptHashHex
    , sundaeOrderValidatorSourceCommit
    , sundaeOrderValidatorSourceRepository
    , sundaeOrderValidatorTitle
    )
import Amaru.Treasury.Tx.Submit
    ( renderTxId
    )
import Amaru.Treasury.Tx.Swap
    ( SwapOrderDatumParams (..)
    , SwapOrderOut (..)
    , swapOrderDatum
    , swapProgram
    )
import Amaru.Treasury.Tx.SwapWizard
    ( txInToText
    )
import Amaru.Treasury.Tx.WithdrawWizard qualified as Withdraw

data ShelleyGenesisTiming = ShelleyGenesisTiming
    { sgtEpochLength :: !Int
    , sgtNetworkMagic :: !Int
    , sgtSlotLength :: !Double
    }
    deriving stock (Eq, Show)

instance FromJSON ShelleyGenesisTiming where
    parseJSON =
        withObject "ShelleyGenesisTiming" $ \o ->
            ShelleyGenesisTiming
                <$> o .: "epochLength"
                <*> o .: "networkMagic"
                <*> o .: "slotLength"

data StakeRewardInitSummary = StakeRewardInitSummary
    { srisPhase :: !T.Text
    , srisNetwork :: !T.Text
    , srisNetworkMagic :: !Int
    , srisRegistryPath :: !FilePath
    , srisAccountsPath :: !FilePath
    , srisProvenancePath :: !FilePath
    }
    deriving stock (Eq, Show)

instance FromJSON StakeRewardInitSummary where
    parseJSON =
        withObject "StakeRewardInitSummary" $ \o ->
            StakeRewardInitSummary
                <$> o .: "phase"
                <*> o .: "network"
                <*> o .: "networkMagic"
                <*> o .: "registryPath"
                <*> o .: "accountsPath"
                <*> o .: "provenancePath"

data StakeRewardInitAccounts = StakeRewardInitAccounts
    { sriaPhase :: !T.Text
    , sriaNetwork :: !T.Text
    , sriaTreasury :: !StakeRewardInitAccount
    , sriaPermissions :: !StakeRewardInitAccount
    }
    deriving stock (Eq, Show)

instance FromJSON StakeRewardInitAccounts where
    parseJSON =
        withObject "StakeRewardInitAccounts" $ \o -> do
            accounts <- o .: "accounts"
            StakeRewardInitAccounts
                <$> o .: "phase"
                <*> o .: "network"
                <*> accounts .: "treasury"
                <*> accounts .: "permissions"

data StakeRewardInitAccount = StakeRewardInitAccount
    { sriaScriptHash :: !T.Text
    , sriaRewardAccount :: !T.Text
    , sriaLedgerNetwork :: !T.Text
    , sriaRegistered :: !Bool
    , sriaRewardsLovelace :: !Integer
    }
    deriving stock (Eq, Show)

instance FromJSON StakeRewardInitAccount where
    parseJSON =
        withObject "StakeRewardInitAccount" $ \o ->
            StakeRewardInitAccount
                <$> o .: "scriptHash"
                <*> o .: "rewardAccount"
                <*> o .: "ledgerNetwork"
                <*> o .: "registered"
                <*> o .: "rewardsLovelace"

data StakeRewardInitProvenance = StakeRewardInitProvenance
    { sripPhase :: !T.Text
    , sripSource :: !T.Text
    , sripIssue :: !Int
    }
    deriving stock (Eq, Show)

instance FromJSON StakeRewardInitProvenance where
    parseJSON =
        withObject "StakeRewardInitProvenance" $ \o ->
            StakeRewardInitProvenance
                <$> o .: "phase"
                <*> o .: "source"
                <*> o .: "issue"

data GovernanceWithdrawalInitSummary = GovernanceWithdrawalInitSummary
    { gwisPhase :: !T.Text
    , gwisStatus :: !T.Text
    , gwisNetwork :: !T.Text
    , gwisNetworkMagic :: !Int
    , gwisRunDirectory :: !FilePath
    , gwisRegistryPath :: !FilePath
    , gwisStakeRewardPath :: !FilePath
    , gwisAmountLovelace :: !Integer
    , gwisGovernancePath :: !FilePath
    , gwisWithdrawalPath :: !FilePath
    , gwisMaterializationPath :: !FilePath
    , gwisProvenancePath :: !FilePath
    }
    deriving stock (Eq, Show)

instance FromJSON GovernanceWithdrawalInitSummary where
    parseJSON =
        withObject "GovernanceWithdrawalInitSummary" $ \o ->
            GovernanceWithdrawalInitSummary
                <$> o .: "phase"
                <*> o .: "status"
                <*> o .: "network"
                <*> o .: "networkMagic"
                <*> o .: "runDirectory"
                <*> o .: "registryPath"
                <*> o .: "stakeRewardPath"
                <*> o .: "amountLovelace"
                <*> o .: "governancePath"
                <*> o .: "withdrawalPath"
                <*> o .: "materializationPath"
                <*> o .: "provenancePath"

data GovernanceWithdrawalInitGovernance = GovernanceWithdrawalInitGovernance
    { gwigPhase :: !T.Text
    , gwigNetwork :: !T.Text
    , gwigProposalTxId :: !T.Text
    , gwigGovernanceActionId :: !T.Text
    , gwigVoteTxId :: !T.Text
    , gwigTreasuryRewardAccount :: !T.Text
    , gwigTreasuryScriptHash :: !T.Text
    , gwigAmountLovelace :: !Integer
    , gwigRewardBeforeLovelace :: !Integer
    , gwigRewardAfterGovernanceLovelace :: !Integer
    , gwigSetupEpoch :: !Word64
    , gwigVoteEpoch :: !Word64
    , gwigFinalEpoch :: !Word64
    }
    deriving stock (Eq, Show)

instance FromJSON GovernanceWithdrawalInitGovernance where
    parseJSON =
        withObject "GovernanceWithdrawalInitGovernance" $ \o ->
            GovernanceWithdrawalInitGovernance
                <$> o .: "phase"
                <*> o .: "network"
                <*> o .: "proposalTxId"
                <*> o .: "governanceActionId"
                <*> o .: "voteTxId"
                <*> o .: "treasuryRewardAccount"
                <*> o .: "treasuryScriptHash"
                <*> o .: "amountLovelace"
                <*> o .: "rewardBeforeLovelace"
                <*> o .: "rewardAfterGovernanceLovelace"
                <*> o .: "setupEpoch"
                <*> o .: "voteEpoch"
                <*> o .: "finalEpoch"

data GovernanceWithdrawalInitWithdrawal = GovernanceWithdrawalInitWithdrawal
    { gwiwPhase :: !T.Text
    , gwiwNetwork :: !T.Text
    , gwiwIntentPath :: !FilePath
    , gwiwTxBodyPath :: !FilePath
    , gwiwReportJsonPath :: !FilePath
    , gwiwReportMarkdownPath :: !FilePath
    , gwiwTxBuildLogPath :: !FilePath
    , gwiwSignedTxPath :: !FilePath
    , gwiwSubmitLogPath :: !FilePath
    , gwiwTxId :: !T.Text
    , gwiwSubmittedTxId :: !T.Text
    , gwiwFeeLovelace :: !Integer
    , gwiwRewardBeforeSubmitLovelace :: !Integer
    , gwiwRewardAfterSubmitLovelace :: !Integer
    }
    deriving stock (Eq, Show)

instance FromJSON GovernanceWithdrawalInitWithdrawal where
    parseJSON =
        withObject "GovernanceWithdrawalInitWithdrawal" $ \o ->
            GovernanceWithdrawalInitWithdrawal
                <$> o .: "phase"
                <*> o .: "network"
                <*> o .: "intentPath"
                <*> o .: "txBodyPath"
                <*> o .: "reportJsonPath"
                <*> o .: "reportMarkdownPath"
                <*> o .: "txBuildLogPath"
                <*> o .: "signedTxPath"
                <*> o .: "submitLogPath"
                <*> o .: "txId"
                <*> o .: "submittedTxId"
                <*> o .: "feeLovelace"
                <*> o .: "rewardBeforeSubmitLovelace"
                <*> o .: "rewardAfterSubmitLovelace"

data GovernanceWithdrawalInitMaterialization
    = GovernanceWithdrawalInitMaterialization
    { gwimPhase :: !T.Text
    , gwimNetwork :: !T.Text
    , gwimGovernanceActionId :: !T.Text
    , gwimTreasuryRewardAccount :: !T.Text
    , gwimSubmittedTxId :: !T.Text
    , gwimTreasuryMaterializedTxIn :: !T.Text
    , gwimTreasuryAddress :: !T.Text
    , gwimMaterializedAdaLovelace :: !Integer
    , gwimRewardBeforeSubmitLovelace :: !Integer
    , gwimRewardAfterSubmitLovelace :: !Integer
    , gwimTreasuryUtxoLovelaceBefore :: !Integer
    , gwimTreasuryUtxoLovelaceAfter :: !Integer
    , gwimRegistryPath :: !FilePath
    , gwimStakeRewardPath :: !FilePath
    }
    deriving stock (Eq, Show)

instance FromJSON GovernanceWithdrawalInitMaterialization where
    parseJSON =
        withObject "GovernanceWithdrawalInitMaterialization" $ \o ->
            GovernanceWithdrawalInitMaterialization
                <$> o .: "phase"
                <*> o .: "network"
                <*> o .: "governanceActionId"
                <*> o .: "treasuryRewardAccount"
                <*> o .: "submittedTxId"
                <*> o .: "treasuryMaterializedTxIn"
                <*> o .: "treasuryAddress"
                <*> o .: "materializedAdaLovelace"
                <*> o .: "rewardBeforeSubmitLovelace"
                <*> o .: "rewardAfterSubmitLovelace"
                <*> o .: "treasuryUtxoLovelaceBefore"
                <*> o .: "treasuryUtxoLovelaceAfter"
                <*> o .: "registryPath"
                <*> o .: "stakeRewardPath"

data GovernanceWithdrawalInitProvenance = GovernanceWithdrawalInitProvenance
    { gwipPhase :: !T.Text
    , gwipSource :: !T.Text
    , gwipIssue :: !Int
    , gwipParentIssue :: !Int
    , gwipDependsOnIssues :: ![Int]
    }
    deriving stock (Eq, Show)

instance FromJSON GovernanceWithdrawalInitProvenance where
    parseJSON =
        withObject "GovernanceWithdrawalInitProvenance" $ \o ->
            GovernanceWithdrawalInitProvenance
                <$> o .: "phase"
                <*> o .: "source"
                <*> o .: "issue"
                <*> o .: "parentIssue"
                <*> o .: "dependsOnIssues"

data DisburseSubmitSummary = DisburseSubmitSummary
    { dsssPhase :: !T.Text
    , dsssStatus :: !T.Text
    , dsssNetwork :: !T.Text
    , dsssNetworkMagic :: !Int
    , dsssRunDirectory :: !FilePath
    , dsssRegistryPath :: !FilePath
    , dsssMaterializedPath :: !FilePath
    , dsssAmountLovelace :: !Integer
    , dsssDisbursePath :: !FilePath
    , dsssBeneficiaryPath :: !FilePath
    , dsssTreasuryPath :: !FilePath
    , dsssProvenancePath :: !FilePath
    }
    deriving stock (Eq, Show)

instance FromJSON DisburseSubmitSummary where
    parseJSON =
        withObject "DisburseSubmitSummary" $ \o ->
            DisburseSubmitSummary
                <$> o .: "phase"
                <*> o .: "status"
                <*> o .: "network"
                <*> o .: "networkMagic"
                <*> o .: "runDirectory"
                <*> o .: "registryPath"
                <*> o .: "materializedPath"
                <*> o .: "amountLovelace"
                <*> o .: "disbursePath"
                <*> o .: "beneficiaryPath"
                <*> o .: "treasuryPath"
                <*> o .: "provenancePath"

data DisburseSubmitDisburse = DisburseSubmitDisburse
    { dssdPhase :: !T.Text
    , dssdNetwork :: !T.Text
    , dssdIntentPath :: !FilePath
    , dssdTxBodyPath :: !FilePath
    , dssdReportJsonPath :: !FilePath
    , dssdReportMarkdownPath :: !FilePath
    , dssdSignedTxPath :: !FilePath
    , dssdSubmitLogPath :: !FilePath
    , dssdTxId :: !T.Text
    , dssdSubmittedTxId :: !T.Text
    , dssdAmountLovelace :: !Integer
    , dssdFeeLovelace :: !Integer
    }
    deriving stock (Eq, Show)

instance FromJSON DisburseSubmitDisburse where
    parseJSON =
        withObject "DisburseSubmitDisburse" $ \o ->
            DisburseSubmitDisburse
                <$> o .: "phase"
                <*> o .: "network"
                <*> o .: "intentPath"
                <*> o .: "txBodyPath"
                <*> o .: "reportJsonPath"
                <*> o .: "reportMarkdownPath"
                <*> o .: "signedTxPath"
                <*> o .: "submitLogPath"
                <*> o .: "txId"
                <*> o .: "submittedTxId"
                <*> o .: "amountLovelace"
                <*> o .: "feeLovelace"

data DisburseSubmitBeneficiary = DisburseSubmitBeneficiary
    { dsbPhase :: !T.Text
    , dsbNetwork :: !T.Text
    , dsbAddress :: !T.Text
    , dsbTxIn :: !T.Text
    , dsbLovelace :: !Integer
    }
    deriving stock (Eq, Show)

instance FromJSON DisburseSubmitBeneficiary where
    parseJSON =
        withObject "DisburseSubmitBeneficiary" $ \o ->
            DisburseSubmitBeneficiary
                <$> o .: "phase"
                <*> o .: "network"
                <*> o .: "address"
                <*> o .: "txIn"
                <*> o .: "lovelace"

data DisburseSubmitTreasury = DisburseSubmitTreasury
    { dstPhase :: !T.Text
    , dstNetwork :: !T.Text
    , dstInput :: !T.Text
    , dstOutput :: !T.Text
    , dstAddress :: !T.Text
    , dstLovelaceBefore :: !Integer
    , dstLovelaceAfter :: !Integer
    , dstConsumed :: !Bool
    }
    deriving stock (Eq, Show)

instance FromJSON DisburseSubmitTreasury where
    parseJSON =
        withObject "DisburseSubmitTreasury" $ \o ->
            DisburseSubmitTreasury
                <$> o .: "phase"
                <*> o .: "network"
                <*> o .: "input"
                <*> o .: "output"
                <*> o .: "address"
                <*> o .: "lovelaceBefore"
                <*> o .: "lovelaceAfter"
                <*> o .: "consumed"

data DisburseSubmitProvenance = DisburseSubmitProvenance
    { dspPhase :: !T.Text
    , dspSource :: !T.Text
    , dspIssue :: !Int
    , dspParentIssue :: !Int
    , dspDependsOnIssues :: ![Int]
    }
    deriving stock (Eq, Show)

instance FromJSON DisburseSubmitProvenance where
    parseJSON =
        withObject "DisburseSubmitProvenance" $ \o ->
            DisburseSubmitProvenance
                <$> o .: "phase"
                <*> o .: "source"
                <*> o .: "issue"
                <*> o .: "parentIssue"
                <*> o .: "dependsOnIssues"

spec :: Spec
spec =
    describe "local devnet smoke" $ do
        describe "swap-ready readiness" $ do
            it "records order-validator reference handoff metadata" $
                swapReadinessRegistryValue
                    sampleRunDir
                    sampleSocket
                    sampleTiming
                    sampleSwapReadinessEvidence
                    `shouldBe` object
                        [ "schemaVersion" .= (1 :: Int)
                        , "phase" .= ("swap-ready" :: String)
                        , "status" .= ("passed" :: String)
                        , "runDirectory" .= sampleRunDir
                        , "socket" .= sampleSocket
                        , "network" .= ("devnet" :: String)
                        , "networkMagic" .= sgtNetworkMagic sampleTiming
                        , "epochDurationSeconds"
                            .= epochDurationSeconds sampleTiming
                        , "orderValidator"
                            .= object
                                [ "sourceRepository"
                                    .= ( "https://github.com/SundaeSwap-finance/sundae-contracts"
                                            :: String
                                       )
                                , "sourceCommit"
                                    .= ( "be33466b7dbe0f8e6c0e0f46ff23737897f45835"
                                            :: String
                                       )
                                , "validatorTitle"
                                    .= ("order.spend" :: String)
                                , "scriptHash"
                                    .= ( "02eee6c4d128c9700c178922163645f1fdb381bbdce071acbbd49465"
                                            :: String
                                       )
                                , "fixtureOnly" .= False
                                ]
                        , "orderReference"
                            .= object
                                [ "referenceTxIn"
                                    .= ( "4c945c6b2d9d8df841f7079d20d32e7bc4eb1f3b0873a134b9dca7c95d22afad#0"
                                            :: String
                                       )
                                , "address"
                                    .= ("addr_test1wzsampleorder" :: String)
                                , "scriptHash"
                                    .= ( "02eee6c4d128c9700c178922163645f1fdb381bbdce071acbbd49465"
                                            :: String
                                       )
                                ]
                        , "orderBuildInputs"
                            .= object
                                [ "swapOrderAddress"
                                    .= ("addr_test1wzsampleorder" :: String)
                                , "orderScriptRef"
                                    .= ( "4c945c6b2d9d8df841f7079d20d32e7bc4eb1f3b0873a134b9dca7c95d22afad#0"
                                            :: String
                                       )
                                ]
                        , "registryPath"
                            .= ( sampleRunDir
                                    </> "swap-ready"
                                    </> "registry.json"
                               )
                        , "summaryPath"
                            .= ( sampleRunDir
                                    </> "swap-ready"
                                    </> "summary.json"
                               )
                        , "provenancePath"
                            .= ( sampleRunDir
                                    </> "swap-ready"
                                    </> "provenance.json"
                               )
                        ]
        describe "registry-init diagnostics" $ do
            it "records registry-init summary and registry artifact fields" $ do
                publication <- sampleRegistryPublication
                let registry =
                        drpAnchors publication
                    target =
                        draTreasuryTarget registry
                RegistryInit.registryInitSummaryValue
                    (sgtNetworkMagic sampleTiming)
                    sampleRunDir
                    publication
                    `shouldBe` object
                        [ "phase" .= ("registry-init" :: String)
                        , "network" .= ("devnet" :: String)
                        , "networkMagic" .= sgtNetworkMagic sampleTiming
                        , "seedSplitTxId"
                            .= renderTxId (drpSeedSplitTxId publication)
                        , "registryMintTxId"
                            .= renderTxId
                                (drpRegistryMintTxId publication)
                        , "referenceScriptsTxId"
                            .= renderTxId
                                (drpReferenceScriptsTxId publication)
                        , "registryPath"
                            .= RegistryInit.registryInitRegistryPath
                                sampleRunDir
                        , "provenancePath"
                            .= RegistryInit.registryInitProvenancePath
                                sampleRunDir
                        ]
                RegistryInit.registryInitRegistryValue publication
                    `shouldBe` object
                        [ "phase" .= ("registry-init" :: String)
                        , "network" .= ("devnet" :: String)
                        , "anchors"
                            .= object
                                [ "scopesDeployedAt"
                                    .= txInToText (draScopesRef registry)
                                , "registryDeployedAt"
                                    .= txInToText (draRegistryRef registry)
                                , "permissionsDeployedAt"
                                    .= txInToText
                                        (draPermissionsRef registry)
                                , "treasuryDeployedAt"
                                    .= txInToText (draTreasuryRef registry)
                                ]
                        , "policies"
                            .= object
                                [ "scopesPolicyId"
                                    .= draScopesPolicyId registry
                                , "registryPolicyId"
                                    .= draRegistryPolicyId registry
                                ]
                        , "scripts"
                            .= object
                                [ "permissionsScriptHash"
                                    .= scriptHashToHex
                                        (draPermissionsHash registry)
                                , "treasuryScriptHash"
                                    .= ttScriptHashText target
                                ]
                        , "addresses"
                            .= object
                                [ "treasuryAddress"
                                    .= renderAddr (ttAddress target)
                                ]
                        , "owners"
                            .= object
                                [ "scopeOwnerKeyHash"
                                    .= draOwnerKeyHash registry
                                ]
                        , "submittedTxIds"
                            .= object
                                [ "seedSplit"
                                    .= renderTxId
                                        (drpSeedSplitTxId publication)
                                , "registryMint"
                                    .= renderTxId
                                        (drpRegistryMintTxId publication)
                                , "referenceScripts"
                                    .= renderTxId
                                        (drpReferenceScriptsTxId publication)
                                ]
                        ]
        describe "governance-withdrawal-init diagnostics" $ do
            it "records command artifact fields for the #150 handoff" $ do
                let result = sampleGovernanceWithdrawalInitResult
                GovernanceWithdrawalInit.governanceWithdrawalInitSummaryValue
                    (sgtNetworkMagic sampleTiming)
                    sampleRunDir
                    result
                    `shouldBe` object
                        [ "phase"
                            .= ("governance-withdrawal-init" :: T.Text)
                        , "status" .= ("passed" :: T.Text)
                        , "network" .= ("devnet" :: T.Text)
                        , "networkMagic" .= sgtNetworkMagic sampleTiming
                        , "runDirectory" .= sampleRunDir
                        , "registryPath" .= sampleRegistryPath
                        , "stakeRewardPath" .= sampleStakeRewardPath
                        , "amountLovelace" .= (2_000_000 :: Integer)
                        , "governancePath"
                            .= GovernanceWithdrawalInit.governanceWithdrawalInitGovernancePath
                                sampleRunDir
                        , "withdrawalPath"
                            .= GovernanceWithdrawalInit.governanceWithdrawalInitWithdrawalPath
                                sampleRunDir
                        , "materializationPath"
                            .= GovernanceWithdrawalInit.governanceWithdrawalInitMaterializationPath
                                sampleRunDir
                        , "provenancePath"
                            .= GovernanceWithdrawalInit.governanceWithdrawalInitProvenancePath
                                sampleRunDir
                        ]
                GovernanceWithdrawalInit.governanceWithdrawalInitGovernanceValue
                    result
                    `shouldBe` object
                        [ "phase"
                            .= ("governance-withdrawal-init" :: T.Text)
                        , "network" .= ("devnet" :: T.Text)
                        , "proposalTxId"
                            .= sampleGovernanceProposalTxId
                        , "governanceActionId"
                            .= sampleGovernanceActionId
                        , "voteTxId" .= sampleGovernanceVoteTxId
                        , "treasuryRewardAccount"
                            .= sampleGovernanceTreasuryHash
                        , "treasuryScriptHash"
                            .= sampleGovernanceTreasuryHash
                        , "amountLovelace" .= (2_000_000 :: Integer)
                        , "rewardBeforeLovelace" .= (0 :: Integer)
                        , "rewardAfterGovernanceLovelace"
                            .= (2_000_000 :: Integer)
                        , "setupEpoch" .= (2 :: Word64)
                        , "voteEpoch" .= (3 :: Word64)
                        , "finalEpoch" .= (4 :: Word64)
                        ]
                GovernanceWithdrawalInit.governanceWithdrawalInitWithdrawalValue
                    result
                    `shouldBe` object
                        [ "phase"
                            .= ("governance-withdrawal-init" :: T.Text)
                        , "network" .= ("devnet" :: T.Text)
                        , "intentPath"
                            .= GovernanceWithdrawalInit.governanceWithdrawalInitIntentPath
                                sampleRunDir
                        , "txBodyPath"
                            .= GovernanceWithdrawalInit.governanceWithdrawalInitTxBodyPath
                                sampleRunDir
                        , "reportJsonPath"
                            .= GovernanceWithdrawalInit.governanceWithdrawalInitReportJsonPath
                                sampleRunDir
                        , "reportMarkdownPath"
                            .= GovernanceWithdrawalInit.governanceWithdrawalInitReportMarkdownPath
                                sampleRunDir
                        , "txBuildLogPath"
                            .= GovernanceWithdrawalInit.governanceWithdrawalInitTxBuildLogPath
                                sampleRunDir
                        , "signedTxPath"
                            .= GovernanceWithdrawalInit.governanceWithdrawalInitSignedTxPath
                                sampleRunDir
                        , "submitLogPath"
                            .= GovernanceWithdrawalInit.governanceWithdrawalInitSubmitLogPath
                                sampleRunDir
                        , "txId" .= sampleGovernanceWithdrawTxId
                        , "submittedTxId"
                            .= sampleGovernanceWithdrawTxId
                        , "feeLovelace" .= (173_000 :: Integer)
                        , "rewardBeforeSubmitLovelace"
                            .= (2_000_000 :: Integer)
                        , "rewardAfterSubmitLovelace"
                            .= (0 :: Integer)
                        ]
                GovernanceWithdrawalInit.governanceWithdrawalInitMaterializationValue
                    result
                    `shouldBe` object
                        [ "phase"
                            .= ("governance-withdrawal-init" :: T.Text)
                        , "network" .= ("devnet" :: T.Text)
                        , "governanceActionId"
                            .= sampleGovernanceActionId
                        , "treasuryRewardAccount"
                            .= sampleGovernanceTreasuryHash
                        , "submittedTxId"
                            .= sampleGovernanceWithdrawTxId
                        , "treasuryMaterializedTxIn"
                            .= sampleGovernanceMaterializedTxIn
                        , "treasuryAddress"
                            .= sampleGovernanceTreasuryAddress
                        , "materializedAdaLovelace"
                            .= (2_000_000 :: Integer)
                        , "rewardBeforeSubmitLovelace"
                            .= (2_000_000 :: Integer)
                        , "rewardAfterSubmitLovelace"
                            .= (0 :: Integer)
                        , "treasuryUtxoLovelaceBefore"
                            .= (0 :: Integer)
                        , "treasuryUtxoLovelaceAfter"
                            .= (2_000_000 :: Integer)
                        , "registryPath" .= sampleRegistryPath
                        , "stakeRewardPath" .= sampleStakeRewardPath
                        ]
        describe "disburse-submit diagnostics" $ do
            it "records command artifact fields and ledger effects" $ do
                let result = sampleDisburseSubmitResult
                DisburseSubmit.disburseSubmitSummaryValue
                    (sgtNetworkMagic sampleTiming)
                    sampleRunDir
                    result
                    `shouldBe` object
                        [ "phase" .= ("disburse-submit" :: T.Text)
                        , "status" .= ("passed" :: T.Text)
                        , "network" .= ("devnet" :: T.Text)
                        , "networkMagic" .= sgtNetworkMagic sampleTiming
                        , "runDirectory" .= sampleRunDir
                        , "registryPath" .= sampleRegistryPath
                        , "materializedPath"
                            .= sampleDisburseSubmitMaterializedPath
                        , "amountLovelace" .= (1_000_000 :: Integer)
                        , "disbursePath"
                            .= DisburseSubmit.disburseSubmitDisbursePath
                                sampleRunDir
                        , "beneficiaryPath"
                            .= DisburseSubmit.disburseSubmitBeneficiaryPath
                                sampleRunDir
                        , "treasuryPath"
                            .= DisburseSubmit.disburseSubmitTreasuryPath
                                sampleRunDir
                        , "provenancePath"
                            .= DisburseSubmit.disburseSubmitProvenancePath
                                sampleRunDir
                        ]
                DisburseSubmit.disburseSubmitDisburseValue result
                    `shouldBe` object
                        [ "phase" .= ("disburse-submit" :: T.Text)
                        , "network" .= ("devnet" :: T.Text)
                        , "intentPath"
                            .= DisburseSubmit.disburseSubmitIntentPath
                                sampleRunDir
                        , "txBodyPath"
                            .= DisburseSubmit.disburseSubmitTxBodyPath
                                sampleRunDir
                        , "reportJsonPath"
                            .= DisburseSubmit.disburseSubmitReportJsonPath
                                sampleRunDir
                        , "reportMarkdownPath"
                            .= DisburseSubmit.disburseSubmitReportMarkdownPath
                                sampleRunDir
                        , "signedTxPath"
                            .= DisburseSubmit.disburseSubmitSignedTxPath
                                sampleRunDir
                        , "submitLogPath"
                            .= DisburseSubmit.disburseSubmitSubmitLogPath
                                sampleRunDir
                        , "txId" .= sampleDisburseSubmitTxId
                        , "submittedTxId" .= sampleDisburseSubmitTxId
                        , "amountLovelace" .= (1_000_000 :: Integer)
                        , "feeLovelace" .= (171_000 :: Integer)
                        ]
                DisburseSubmit.disburseSubmitBeneficiaryValue result
                    `shouldBe` object
                        [ "phase" .= ("disburse-submit" :: T.Text)
                        , "network" .= ("devnet" :: T.Text)
                        , "address" .= sampleDisburseSubmitBeneficiaryAddress
                        , "txIn" .= sampleDisburseSubmitBeneficiaryTxIn
                        , "lovelace" .= (1_000_000 :: Integer)
                        ]
                DisburseSubmit.disburseSubmitTreasuryValue result
                    `shouldBe` object
                        [ "phase" .= ("disburse-submit" :: T.Text)
                        , "network" .= ("devnet" :: T.Text)
                        , "input" .= sampleGovernanceMaterializedTxIn
                        , "output" .= sampleDisburseSubmitTreasuryOutput
                        , "address" .= sampleGovernanceTreasuryAddress
                        , "lovelaceBefore" .= (2_000_000 :: Integer)
                        , "lovelaceAfter" .= (1_000_000 :: Integer)
                        , "consumed" .= True
                        ]
                DisburseSubmit.disburseSubmitProvenanceValue
                    `shouldBe` object
                        [ "phase" .= ("disburse-submit" :: T.Text)
                        , "source" .= ("amaru-treasury-tx" :: T.Text)
                        , "issue" .= (150 :: Int)
                        , "parentIssue" .= (151 :: Int)
                        , "dependsOnIssues" .= ([147, 149] :: [Int])
                        ]
        describe "withdraw diagnostics" $ do
            it "records submitted withdrawal materialization proof" $ do
                let submitted =
                        WithdrawalSubmissionEvidence
                            { wseSubmittedTxId =
                                "4c945c6b2d9d8df841f7079d20d32e7bc4eb1f3b0873a134b9dca7c95d22afad"
                            , wseSignedTxPath =
                                sampleRunDir
                                    </> "withdraw"
                                    </> "signed-tx.cbor.hex"
                            , wseSubmitLogPath =
                                sampleRunDir
                                    </> "withdraw"
                                    </> "submit.log"
                            , wseMaterializationPath =
                                sampleRunDir
                                    </> "withdraw"
                                    </> "materialized.json"
                            , wseTreasuryMaterializedTxIn =
                                "4c945c6b2d9d8df841f7079d20d32e7bc4eb1f3b0873a134b9dca7c95d22afad#0"
                            , wseTreasuryAddress =
                                "addr_test1wzsampletreasury"
                            , wseMaterializedLovelace =
                                2_000_000
                            , wseRewardBeforeSubmit =
                                2_000_000
                            , wseRewardAfterSubmit =
                                0
                            , wseTreasuryLovelaceBefore =
                                200_000_000
                            , wseTreasuryLovelaceAfter =
                                202_000_000
                            }
                withdrawalMaterializationValue sampleEvidence submitted
                    `shouldBe` object
                        [ "governanceActionId"
                            .= geActionId sampleEvidence
                        , "rewardAccount"
                            .= geRewardAccount sampleEvidence
                        , "submittedTxId"
                            .= wseSubmittedTxId submitted
                        , "signedTxPath"
                            .= wseSignedTxPath submitted
                        , "submitLogPath"
                            .= wseSubmitLogPath submitted
                        , "materializationPath"
                            .= wseMaterializationPath submitted
                        , "treasuryMaterializedTxIn"
                            .= wseTreasuryMaterializedTxIn submitted
                        , "treasuryAddress"
                            .= wseTreasuryAddress submitted
                        , "materializedAdaLovelace"
                            .= wseMaterializedLovelace submitted
                        , "rewardBeforeSubmitLovelace"
                            .= wseRewardBeforeSubmit submitted
                        , "rewardAfterSubmitLovelace"
                            .= wseRewardAfterSubmit submitted
                        , "treasuryUtxoLovelaceBefore"
                            .= wseTreasuryLovelaceBefore submitted
                        , "treasuryUtxoLovelaceAfter"
                            .= wseTreasuryLovelaceAfter submitted
                        ]
            it "records reward timeout with last reward and epoch/tip context" $ do
                let failure =
                        WithdrawalRewardTimeout
                            sampleRewardAccount
                            (Coin 0)
                            (Just 3)
                            (Just 44)
                withdrawalFailureValue
                    sampleRunDir
                    sampleSocket
                    sampleTiming
                    (Just sampleEvidence)
                    failure
                    `shouldBe` object
                        [ "phase" .= ("withdraw" :: String)
                        , "status" .= ("failed" :: String)
                        , "code" .= ("reward-timeout" :: String)
                        , "message"
                            .= ( "timed out waiting for reward account "
                                    <> sampleRewardAccount
                                    <> " to become positive"
                               )
                        , "runDirectory" .= sampleRunDir
                        , "socket" .= sampleSocket
                        , "network" .= ("devnet" :: String)
                        , "networkMagic" .= sgtNetworkMagic sampleTiming
                        , "epochDurationSeconds"
                            .= epochDurationSeconds sampleTiming
                        , "rewardAccount" .= Just sampleRewardAccount
                        , "rewardBeforeLovelace"
                            .= Just (0 :: Integer)
                        , "rewardAfterGovernanceLovelace"
                            .= Just (2_000_000 :: Integer)
                        , "lastObservedRewardLovelace"
                            .= Just (0 :: Integer)
                        , "epoch" .= Just (3 :: Word64)
                        , "tipSlot" .= Just (44 :: Word64)
                        , "governancePrerequisitePath"
                            .= ( sampleRunDir
                                    </> "withdraw"
                                    </> "governance-prerequisite.json"
                               )
                        , "intentPath" .= withdrawIntentPath sampleRunDir
                        , "txBodyPath" .= withdrawTxBodyPath sampleRunDir
                        , "reportJsonPath"
                            .= withdrawReportJsonPath sampleRunDir
                        , "reportMarkdownPath"
                            .= withdrawReportMarkdownPath sampleRunDir
                        , "txBuildLogPath"
                            .= withdrawTxBuildLogPath sampleRunDir
                        , "upstreamCardanoNodeClientsMain"
                            .= upstreamCardanoNodeClientsMain
                        , "txBuildExitCode" .= (Nothing :: Maybe Int)
                        , "txBuildFailureCode" .= (Nothing :: Maybe T.Text)
                        , "txBuildFailureMessage"
                            .= (Nothing :: Maybe T.Text)
                        ]
            it "classifies network mismatch before writing an intent" $ do
                let failure =
                        withdrawalResolverFailure
                            ( Withdraw.WithdrawResolverNetworkMismatch
                                "mainnet"
                                "testnet"
                            )
                            (Coin 2_000_000)
                            (Just 3)
                            (Just 44)
                withdrawalFailureCode failure `shouldBe` "network-mismatch"
                withdrawalFailureMessage failure
                    `shouldBe` "withdraw intent network mainnet does not match observed testnet"
                withdrawalFailureRemovesIntent failure `shouldBe` True
            it "removes stale success artifacts before a zero-rewards diagnostic" $
                withTempRunDir "amaru-withdraw-zero-diagnostic" $ \runDir -> do
                    createDirectoryIfMissing True (runDir </> "withdraw")
                    writeFile (withdrawIntentPath runDir) "stale intent"
                    writeFile (withdrawTxBodyPath runDir) "stale cbor"
                    _ <-
                        writeWithdrawalFailure
                            runDir
                            sampleSocket
                            sampleTiming
                            (Just sampleEvidence)
                            ( WithdrawalZeroRewards
                                sampleRewardAccount
                                (Coin 0)
                                (Just 3)
                                (Just 44)
                            )
                    doesFileExist (withdrawIntentPath runDir)
                        >>= (`shouldBe` False)
                    doesFileExist (withdrawTxBodyPath runDir)
                        >>= (`shouldBe` False)
                    doesFileExist (runDir </> "withdraw" </> "failure.json")
                        >>= (`shouldBe` True)
            it "preserves intent but removes tx body when tx-build fails" $
                withTempRunDir "amaru-withdraw-tx-build-diagnostic" $ \runDir -> do
                    createDirectoryIfMissing True (runDir </> "withdraw")
                    writeFile (withdrawIntentPath runDir) "intent"
                    writeFile (withdrawTxBodyPath runDir) "stale cbor"
                    _ <-
                        writeWithdrawalFailure
                            runDir
                            sampleSocket
                            sampleTiming
                            (Just sampleEvidence)
                            ( WithdrawalTxBuildFailed
                                (ExitFailure 6)
                                ( Just
                                    Report.BuildFailure
                                        { Report.bfCode =
                                            "network-mismatch"
                                        , Report.bfMessage =
                                            "socket is on the wrong network"
                                        }
                                )
                            )
                    doesFileExist (withdrawIntentPath runDir)
                        >>= (`shouldBe` True)
                    doesFileExist (withdrawTxBodyPath runDir)
                        >>= (`shouldBe` False)
                    doesFileExist (runDir </> "withdraw" </> "failure.json")
                        >>= (`shouldBe` True)
        it
            "node: starts cardano-node-clients devnet and records short-epoch timing evidence"
            (runForPhases ["node", "all"] nodeSmoke)
        it
            "governance: funds the treasury script reward account"
            (runForPhases ["governance", "all"] governanceSmoke)
        it
            "governance-withdrawal-init / withdraw: proves the production command runner"
            ( runForPhases
                ["governance-withdrawal-init", "withdraw", "all"]
                withdrawSmoke
            )
        it
            "swap-ready: publishes SundaeSwap V3 order validator readiness"
            (runForPhases ["swap-ready"] swapReadySmoke)
        it
            "scoop-m2: builds and funds a SundaeSwap V3 order UTxO"
            (runForPhases ["scoop-m2"] scoopM2Smoke)
        it
            "scoop-e2e: bootstraps a fresh Sundae pool and scoops one order"
            (runForPhases ["scoop-e2e"] scoopE2ESmoke)
        it
            "treasury-swap-e2e: scoops a treasury-destination Sundae order"
            (runForPhases ["treasury-swap-e2e"] treasurySwapE2ESmoke)
        it
            "treasury-swap-full-e2e: deployed treasury funds a swapProgram order, scooped"
            ( runForPhases
                ["treasury-swap-full-e2e"]
                treasurySwapFullE2ESmoke
            )
        it
            "mixed-utxo: validates mixed treasury swap and reorganize through phase-2"
            (runForPhases ["mixed-utxo"] mixedUtxoSmoke)
        it
            "registry-init: publishes registry artifacts"
            (runForPhases ["registry-init"] registryInitSmoke)
        it
            "stake-reward-init: prepares treasury and permissions reward accounts"
            (runForPhases ["stake-reward-init"] stakeRewardInitSmoke)
        it
            "disburse-submit: proves the shipped command runner"
            (runForPhases ["disburse-submit"] disburseSubmitSmoke)

runForPhases :: [String] -> IO () -> IO ()
runForPhases accepted action = do
    phase <- fromMaybe "node" <$> lookupEnv "DEVNET_SMOKE_PHASE"
    when (phase `elem` accepted) action

governanceSmoke :: IO ()
governanceSmoke = do
    runDir <- resolveRunDir
    withFundedGovernanceReward runDir preparePinnedTreasuryTarget $
        \socket timing _provider _submitter () evidence -> do
            writeGovernanceArtifacts runDir socket timing evidence
            putGovernanceSummaryLines runDir socket timing evidence

nodeSmoke :: IO ()
nodeSmoke = do
    runDir <- resolveRunDir
    prepareRunDir runDir

    gDir <- genesisDir
    assertGenesisDir gDir
    timing <- readShelleyTiming gDir
    let epochDuration = epochDurationSeconds timing
    sgtNetworkMagic timing `shouldBe` 42
    epochDuration `shouldSatisfy` (<= 60)

    withCardanoNode gDir $ \socket startMs -> do
        accepted <- probeNetworkMagic devnetMagic socket
        accepted `shouldBe` True

        copyNodeLog socket runDir
        writeTiming runDir startMs socket timing
        writeSummary runDir socket timing "passed"
        putSummaryLines runDir socket timing "passed"

governanceWithdrawalInitSmoke :: IO ()
governanceWithdrawalInitSmoke = do
    runDir <- resolveRunDir
    prepareRunDir runDir

    sourceGenesis <- genesisDir
    assertGenesisDir sourceGenesis
    let smokeGenesis = runDir </> "genesis"
    copyGovernanceGenesis sourceGenesis smokeGenesis
    patchGovernanceGenesis smokeGenesis
    timing <- readShelleyTiming smokeGenesis
    let epochDuration = epochDurationSeconds timing
    sgtNetworkMagic timing `shouldBe` 42
    epochDuration `shouldSatisfy` (<= 10)

    rewardTimeoutSeconds <- resolveRewardTimeoutSeconds

    withCardanoNode smokeGenesis $ \socket startMs -> do
        accepted <- probeNetworkMagic devnetMagic socket
        accepted `shouldBe` True

        copyNodeLog socket runDir
        writeTiming runDir startMs socket timing
        signingKeyFile <- writeGenesisPaymentSigningKey runDir
        let globals =
                GlobalOpts
                    { goSocketPath = Just socket
                    , goNetworkMagic = devnetMagic
                    , goNetworkName = Just "devnet"
                    }
            fundingAddress =
                T.unpack (renderAddr genesisAddr)
            registryPath =
                RegistryInit.registryInitRegistryPath runDir
            stakeRewardPath =
                StakeRewardInit.stakeRewardInitAccountsPath runDir
        runDevnetRegistryInit
            globals
            DevnetRegistryInitOpts
                { drioFundingAddress = fundingAddress
                , drioSigningKeyFile = signingKeyFile
                , drioRunDir = runDir
                }
        runDevnetStakeRewardInit
            globals
            DevnetStakeRewardInitOpts
                { dsrioRegistryFile = registryPath
                , dsrioFundingAddress = fundingAddress
                , dsrioSigningKeyFile = signingKeyFile
                , dsrioRunDir = runDir
                }
        assertStakeRewardInitArtifacts runDir registryPath timing
        runDevnetGovernanceWithdrawalInit
            globals
            DevnetGovernanceWithdrawalInitOpts
                { dgwioRegistryFile = registryPath
                , dgwioStakeRewardFile = stakeRewardPath
                , dgwioFundingAddress = fundingAddress
                , dgwioSigningKeyFile = signingKeyFile
                , dgwioRunDir = runDir
                , dgwioAmountLovelace = coinLovelace withdrawalAmount
                , dgwioRewardTimeoutSeconds = rewardTimeoutSeconds
                }
        assertGovernanceWithdrawalInitArtifacts
            runDir
            registryPath
            stakeRewardPath
            timing

disburseSubmitSmoke :: IO ()
disburseSubmitSmoke = do
    runDir <- resolveRunDir
    prepareRunDir runDir

    sourceGenesis <- genesisDir
    assertGenesisDir sourceGenesis
    let smokeGenesis = runDir </> "genesis"
    copyGovernanceGenesis sourceGenesis smokeGenesis
    patchGovernanceGenesis smokeGenesis
    timing <- readShelleyTiming smokeGenesis
    let epochDuration = epochDurationSeconds timing
    sgtNetworkMagic timing `shouldBe` 42
    epochDuration `shouldSatisfy` (<= 10)

    rewardTimeoutSeconds <- resolveRewardTimeoutSeconds

    withCardanoNode smokeGenesis $ \socket startMs -> do
        accepted <- probeNetworkMagic devnetMagic socket
        accepted `shouldBe` True

        copyNodeLog socket runDir
        writeTiming runDir startMs socket timing
        signingKeyFile <- writeGenesisPaymentSigningKey runDir
        let globals =
                GlobalOpts
                    { goSocketPath = Just socket
                    , goNetworkMagic = devnetMagic
                    , goNetworkName = Just "devnet"
                    }
            fundingAddress =
                T.unpack (renderAddr genesisAddr)
            registryPath =
                RegistryInit.registryInitRegistryPath runDir
            stakeRewardPath =
                StakeRewardInit.stakeRewardInitAccountsPath runDir
            materializedPath =
                GovernanceWithdrawalInit.governanceWithdrawalInitMaterializationPath
                    runDir
        runDevnetRegistryInit
            globals
            DevnetRegistryInitOpts
                { drioFundingAddress = fundingAddress
                , drioSigningKeyFile = signingKeyFile
                , drioRunDir = runDir
                }
        runDevnetStakeRewardInit
            globals
            DevnetStakeRewardInitOpts
                { dsrioRegistryFile = registryPath
                , dsrioFundingAddress = fundingAddress
                , dsrioSigningKeyFile = signingKeyFile
                , dsrioRunDir = runDir
                }
        assertStakeRewardInitArtifacts runDir registryPath timing
        runDevnetGovernanceWithdrawalInit
            globals
            DevnetGovernanceWithdrawalInitOpts
                { dgwioRegistryFile = registryPath
                , dgwioStakeRewardFile = stakeRewardPath
                , dgwioFundingAddress = fundingAddress
                , dgwioSigningKeyFile = signingKeyFile
                , dgwioRunDir = runDir
                , dgwioAmountLovelace = coinLovelace withdrawalAmount
                , dgwioRewardTimeoutSeconds = rewardTimeoutSeconds
                }
        assertGovernanceWithdrawalInitArtifacts
            runDir
            registryPath
            stakeRewardPath
            timing
        runDevnetDisburseSubmit
            globals
            DevnetDisburseSubmitOpts
                { ddsioRegistryFile = registryPath
                , ddsioMaterializedFile = materializedPath
                , ddsioFundingAddress = fundingAddress
                , ddsioSigningKeyFile = signingKeyFile
                , ddsioBeneficiaryAddress = fundingAddress
                , ddsioRunDir = runDir
                , ddsioAmountLovelace = 1_000_000
                }
        assertDisburseSubmitArtifacts
            runDir
            registryPath
            materializedPath
            (T.pack fundingAddress)
            timing

withdrawSmoke :: IO ()
withdrawSmoke =
    governanceWithdrawalInitSmoke

registryInitSmoke :: IO ()
registryInitSmoke = do
    runDir <- resolveRunDir
    prepareRunDir runDir

    gDir <- genesisDir
    assertGenesisDir gDir
    timing <- readShelleyTiming gDir
    sgtNetworkMagic timing `shouldBe` 42

    withCardanoNode gDir $ \socket startMs -> do
        accepted <- probeNetworkMagic devnetMagic socket
        accepted `shouldBe` True

        copyNodeLog socket runDir
        writeTiming runDir startMs socket timing
        signingKeyFile <- writeGenesisPaymentSigningKey runDir
        runDevnetRegistryInit
            GlobalOpts
                { goSocketPath = Just socket
                , goNetworkMagic = devnetMagic
                , goNetworkName = Just "devnet"
                }
            DevnetRegistryInitOpts
                { drioFundingAddress =
                    T.unpack (renderAddr genesisAddr)
                , drioSigningKeyFile = signingKeyFile
                , drioRunDir = runDir
                }

stakeRewardInitSmoke :: IO ()
stakeRewardInitSmoke = do
    runDir <- resolveRunDir
    prepareRunDir runDir

    gDir <- genesisDir
    assertGenesisDir gDir
    timing <- readShelleyTiming gDir
    sgtNetworkMagic timing `shouldBe` 42

    withCardanoNode gDir $ \socket startMs -> do
        accepted <- probeNetworkMagic devnetMagic socket
        accepted `shouldBe` True

        copyNodeLog socket runDir
        writeTiming runDir startMs socket timing
        signingKeyFile <- writeGenesisPaymentSigningKey runDir
        let globals =
                GlobalOpts
                    { goSocketPath = Just socket
                    , goNetworkMagic = devnetMagic
                    , goNetworkName = Just "devnet"
                    }
            fundingAddress =
                T.unpack (renderAddr genesisAddr)
            registryPath =
                RegistryInit.registryInitRegistryPath runDir
        runDevnetRegistryInit
            globals
            DevnetRegistryInitOpts
                { drioFundingAddress = fundingAddress
                , drioSigningKeyFile = signingKeyFile
                , drioRunDir = runDir
                }
        runDevnetStakeRewardInit
            globals
            DevnetStakeRewardInitOpts
                { dsrioRegistryFile = registryPath
                , dsrioFundingAddress = fundingAddress
                , dsrioSigningKeyFile = signingKeyFile
                , dsrioRunDir = runDir
                }
        assertStakeRewardInitArtifacts runDir registryPath timing

swapReadySmoke :: IO ()
swapReadySmoke = do
    runDir <- resolveRunDir
    prepareRunDir runDir
    createDirectoryIfMissing True (runDir </> "swap-ready")

    gDir <- genesisDir
    assertGenesisDir gDir
    timing <- readShelleyTiming gDir
    sgtNetworkMagic timing `shouldBe` 42

    withCardanoNode gDir $ \socket startMs -> do
        accepted <- probeNetworkMagic devnetMagic socket
        accepted `shouldBe` True

        copyNodeLog socket runDir
        writeTiming runDir startMs socket timing
        withGovernanceNode socket $ \provider submitter -> do
            pp <- queryProtocolParams provider
            utxos <- queryUTxOs provider genesisAddr
            evidence <-
                publishSwapReadiness
                    provider
                    submitter
                    pp
                    utxos
            writeSwapReadinessArtifacts runDir socket timing evidence
            putSwapReadinessLines runDir evidence

scoopM2Smoke :: IO ()
scoopM2Smoke = do
    runDir <- resolveRunDir
    prepareRunDir runDir
    createDirectoryIfMissing True (runDir </> "scoop-m2")

    gDir <- genesisDir
    assertGenesisDir gDir
    timing <- readShelleyTiming gDir
    sgtNetworkMagic timing `shouldBe` 42

    withCardanoNode gDir $ \socket startMs -> do
        accepted <- probeNetworkMagic devnetMagic socket
        accepted `shouldBe` True

        copyNodeLog socket runDir
        writeTiming runDir startMs socket timing
        withGovernanceNode socket $ \provider submitter -> do
            pp <- queryProtocolParams provider
            utxos <- queryUTxOs provider genesisAddr
            readiness <-
                publishSwapReadiness
                    provider
                    submitter
                    pp
                    utxos
            writeSwapReadinessArtifacts runDir socket timing readiness

            freshUtxos <- queryUTxOs provider genesisAddr
            orderEvidence <-
                publishScoopM2Order
                    provider
                    submitter
                    pp
                    freshUtxos
                    readiness
            writeScoopM2Artifacts runDir socket timing readiness orderEvidence
            putScoopM2Lines runDir orderEvidence

scoopE2ESmoke :: IO ()
scoopE2ESmoke = do
    runDir <- resolveRunDir
    prepareRunDir runDir
    createDirectoryIfMissing True (runDir </> "scoop-e2e")
    statusNote "M3 scoop-e2e starting one persistent devnet run"

    gDir <- genesisDir
    assertGenesisDir gDir
    timing <- readShelleyTiming gDir
    sgtNetworkMagic timing `shouldBe` 42

    withCardanoNode gDir $ \socket startMs -> do
        accepted <- probeNetworkMagic devnetMagic socket
        accepted `shouldBe` True

        copyNodeLog socket runDir
        writeTiming runDir startMs socket timing
        withGovernanceNode socket $ \provider submitter -> do
            pp <- queryProtocolParams provider
            walletUtxos <- queryUTxOs provider genesisAddr
            boot <-
                selectLargestAdaUtxo
                    "fresh Sundae settings protocol boot"
                    walletUtxos
            scripts <- deriveFreshSundaeScripts runDir (fst boot)

            statusNote "M3 bootstrap settings NFT and settings datum UTxO"
            settings <- bootstrapSundaeSettings provider submitter pp boot scripts

            statusNote "M3 mint fresh test token for minimal ADA/token pool"
            freshUtxos <- queryUTxOs provider genesisAddr
            token <- mintScoopTestToken provider submitter pp freshUtxos

            statusNote "M3 create minimal Sundae ADA/test-token pool"
            pool <- createSundaePool provider submitter pp settings token scripts
            statusMilestone $
                "M3 DONE pool live settings="
                    <> T.unpack (txInToText (ssuTxIn settings))
                    <> " pool="
                    <> T.unpack (txInToText (spuTxIn pool))
                    <> " poolIdent="
                    <> T.unpack (hexText (spuIdent pool))

            statusNote "M3 publish fresh Sundae reference scripts for scoop"
            scriptRefs <-
                publishSundaeReferenceScripts
                    provider
                    submitter
                    pp
                    scripts
            settingsForScoop <-
                refreshSettingsBeforeReferenceScripts
                    provider
                    submitter
                    pp
                    settings
                    scripts
                    scriptRefs
            statusNote "M3 register fresh pool_stake reward account"
            registerFreshPoolStakeRewardAccount
                provider
                submitter
                pp
                settingsForScoop
                scripts

            statusNote "M3 place generic Fixed-destination wallet order"
            orderFuel <- queryUTxOs provider genesisAddr
            order <-
                placeGenericSundaeOrder
                    provider
                    submitter
                    pp
                    orderFuel
                    token
                    scripts

            statusNote "M4 scoop order with pool_stake withdraw-zero"
            scoopFuel <- queryUTxOs provider genesisAddr
            evidence <-
                scoopSundaeOrder
                    provider
                    submitter
                    pp
                    scoopFuel
                    settingsForScoop
                    token
                    pool
                    order
                    scripts
                    scriptRefs
            writeScoopE2EArtifacts runDir socket timing evidence
            putScoopE2ELines runDir evidence
            statusMilestone "M4 DONE scoop-e2e passed"

treasurySwapE2ESmoke :: IO ()
treasurySwapE2ESmoke = do
    runDir <- resolveRunDir
    prepareRunDir runDir
    createDirectoryIfMissing True (runDir </> "scoop-e2e")
    createDirectoryIfMissing True (runDir </> "treasury-swap-e2e")
    statusNote "M3 treasury-swap-e2e starting one persistent devnet run"

    treasuryTarget <-
        RegistryInit.treasuryTargetFromBlob Testnet
            =<< expectEither
                "derive #409 treasury script"
                (derivedTreasuryScriptBlob CoreDevelopment)
    let treasuryHash =
            ttScriptHash treasuryTarget
        treasuryAddress =
            stakedScriptAddr treasuryHash

    gDir <- genesisDir
    assertGenesisDir gDir
    timing <- readShelleyTiming gDir
    sgtNetworkMagic timing `shouldBe` 42

    withCardanoNode gDir $ \socket startMs -> do
        accepted <- probeNetworkMagic devnetMagic socket
        accepted `shouldBe` True

        copyNodeLog socket runDir
        writeTiming runDir startMs socket timing
        withGovernanceNode socket $ \provider submitter -> do
            pp <- queryProtocolParams provider
            walletUtxos <- queryUTxOs provider genesisAddr
            boot <-
                selectLargestAdaUtxo
                    "fresh treasury swap settings protocol boot"
                    walletUtxos
            scripts <- deriveFreshSundaeScripts runDir (fst boot)

            statusNote "M3 bootstrap settings NFT and settings datum UTxO"
            settings <- bootstrapSundaeSettings provider submitter pp boot scripts

            statusNote "M3 mint fresh test token for minimal ADA/token pool"
            freshUtxos <- queryUTxOs provider genesisAddr
            token <- mintScoopTestToken provider submitter pp freshUtxos

            statusNote "M3 create minimal Sundae ADA/test-token pool"
            pool <- createSundaePool provider submitter pp settings token scripts
            statusMilestone $
                "M3 DONE treasury pool live settings="
                    <> T.unpack (txInToText (ssuTxIn settings))
                    <> " pool="
                    <> T.unpack (txInToText (spuTxIn pool))
                    <> " poolIdent="
                    <> T.unpack (hexText (spuIdent pool))

            statusNote "M3 publish fresh Sundae reference scripts for scoop"
            scriptRefs <-
                publishSundaeReferenceScripts
                    provider
                    submitter
                    pp
                    scripts
            settingsForScoop <-
                refreshSettingsBeforeReferenceScripts
                    provider
                    submitter
                    pp
                    settings
                    scripts
                    scriptRefs
            statusNote "M3 register fresh pool_stake reward account"
            registerFreshPoolStakeRewardAccount
                provider
                submitter
                pp
                settingsForScoop
                scripts

            statusNote "M3 place treasury-destination Fixed order"
            orderFuel <- queryUTxOs provider genesisAddr
            order <-
                placeTreasurySwapOrder
                    provider
                    submitter
                    pp
                    orderFuel
                    treasuryHash
                    token
                    pool
                    scripts

            statusNote "M4 scoop treasury order with pool_stake withdraw-zero"
            scoopFuel <- queryUTxOs provider genesisAddr
            evidence <-
                scoopTreasurySwapOrder
                    provider
                    submitter
                    pp
                    scoopFuel
                    settingsForScoop
                    treasuryHash
                    treasuryAddress
                    token
                    pool
                    order
                    scripts
                    scriptRefs
            writeTreasurySwapArtifacts runDir socket timing evidence
            putTreasurySwapLines runDir evidence
            statusMilestone "M4 DONE treasury-swap-e2e passed"

{- | Design-B full e2e: deploy + fund a re-rooted treasury
(cloning the disburse-submit scaffold), then debit it through
the shipped 'swapProgram' to emit one Sundae order, and scoop
that order back to the treasury (#409). Proof is the emitted
'TreasuryFullSwapEvidence' / @summary.json@.
-}
treasurySwapFullE2ESmoke :: IO ()
treasurySwapFullE2ESmoke = do
    runDir <- resolveRunDir
    prepareRunDir runDir
    createDirectoryIfMissing
        True
        (runDir </> "treasury-swap-full-e2e")
    statusNote
        "S2 treasury-swap-full-e2e deploy+fund re-rooted treasury"

    sourceGenesis <- genesisDir
    assertGenesisDir sourceGenesis
    let smokeGenesis = runDir </> "genesis"
    copyGovernanceGenesis sourceGenesis smokeGenesis
    patchGovernanceGenesis smokeGenesis
    timing <- readShelleyTiming smokeGenesis
    sgtNetworkMagic timing `shouldBe` 42

    rewardTimeoutSeconds <- resolveRewardTimeoutSeconds

    withCardanoNode smokeGenesis $ \socket startMs -> do
        accepted <- probeNetworkMagic devnetMagic socket
        accepted `shouldBe` True
        copyNodeLog socket runDir
        writeTiming runDir startMs socket timing
        signingKeyFile <- writeGenesisPaymentSigningKey runDir
        let globals =
                GlobalOpts
                    { goSocketPath = Just socket
                    , goNetworkMagic = devnetMagic
                    , goNetworkName = Just "devnet"
                    }
            fundingAddress =
                T.unpack (renderAddr genesisAddr)
            registryPath =
                RegistryInit.registryInitRegistryPath runDir
            stakeRewardPath =
                StakeRewardInit.stakeRewardInitAccountsPath runDir
            materializedPath =
                GovernanceWithdrawalInit.governanceWithdrawalInitMaterializationPath
                    runDir

        -- 1) clone the disburse-submit deploy+fund scaffold
        --    (registry-init -> stake-reward-init ->
        --    governance-withdrawal-init), stopping BEFORE the
        --    disburse so the funded treasury UTxO is left
        --    unspent for our swapProgram debit.
        runDevnetRegistryInit
            globals
            DevnetRegistryInitOpts
                { drioFundingAddress = fundingAddress
                , drioSigningKeyFile = signingKeyFile
                , drioRunDir = runDir
                }
        runDevnetStakeRewardInit
            globals
            DevnetStakeRewardInitOpts
                { dsrioRegistryFile = registryPath
                , dsrioFundingAddress = fundingAddress
                , dsrioSigningKeyFile = signingKeyFile
                , dsrioRunDir = runDir
                }
        assertStakeRewardInitArtifacts runDir registryPath timing
        runDevnetGovernanceWithdrawalInit
            globals
            DevnetGovernanceWithdrawalInitOpts
                { dgwioRegistryFile = registryPath
                , dgwioStakeRewardFile = stakeRewardPath
                , dgwioFundingAddress = fundingAddress
                , dgwioSigningKeyFile = signingKeyFile
                , dgwioRunDir = runDir
                , dgwioAmountLovelace =
                    coinLovelace withdrawalAmount
                , dgwioRewardTimeoutSeconds = rewardTimeoutSeconds
                }
        assertGovernanceWithdrawalInitArtifacts
            runDir
            registryPath
            stakeRewardPath
            timing

        -- 2) recover the deployed anchors + funded treasury UTxO
        registry <-
            expectEither "read deployed registry anchors"
                =<< DisburseSubmit.readDevnetDisburseSubmitRegistry
                    registryPath
        materialized <-
            expectEither "read materialized treasury UTxO"
                =<< DisburseSubmit.readDevnetDisburseSubmitMaterialized
                    materializedPath
        let treasuryHash =
                GovernanceWithdrawalInit.dgwrTreasuryScriptHash
                    registry
            treasuryAddress =
                GovernanceWithdrawalInit.dgwrTreasuryAddress registry
            treasuryBefore =
                DisburseSubmit.ddsmMaterializedAdaLovelace
                    materialized

        -- 3) bootstrap a fresh Sundae pool (#409) on the same node
        withGovernanceNode socket $ \provider submitter -> do
            pp <- queryProtocolParams provider
            walletUtxos <- queryUTxOs provider genesisAddr
            boot <-
                selectLargestAdaUtxo
                    "full-swap settings protocol boot"
                    walletUtxos
            scripts <- deriveFreshSundaeScripts runDir (fst boot)
            settings <-
                bootstrapSundaeSettings provider submitter pp boot scripts
            freshUtxos <- queryUTxOs provider genesisAddr
            token <- mintScoopTestToken provider submitter pp freshUtxos
            pool <-
                createSundaePool provider submitter pp settings token scripts
            scriptRefs <-
                publishSundaeReferenceScripts provider submitter pp scripts
            settingsForScoop <-
                refreshSettingsBeforeReferenceScripts
                    provider
                    submitter
                    pp
                    settings
                    scripts
                    scriptRefs
            registerFreshPoolStakeRewardAccount
                provider
                submitter
                pp
                settingsForScoop
                scripts

            -- 4) assemble the SwapIntent (S1) and place the order
            --    via the shipped swapProgram, debiting the treasury.
            statusNote "S2 swapProgram debits the deployed treasury"
            deployRefs <-
                waitForTxIns
                    provider
                    [ GovernanceWithdrawalInit.dgwrScopesRef registry
                    , GovernanceWithdrawalInit.dgwrPermissionsRef
                        registry
                    , GovernanceWithdrawalInit.dgwrTreasuryRef registry
                    , GovernanceWithdrawalInit.dgwrRegistryRef registry
                    ]
                    60
            treasuryFound <-
                waitForTxIns
                    provider
                    [DisburseSubmit.ddsmTreasuryInput materialized]
                    60
            treasuryUtxo@(treasuryIn, _) <-
                case treasuryFound of
                    [u] -> pure u
                    _ ->
                        expectationFailure
                            "deployed treasury UTxO was not found"
                            *> error "unreachable"
            swapFuelUtxos <- queryUTxOs provider genesisAddr
            fuel@(fuelIn, _) <-
                selectLargestAdaUtxo
                    "swapProgram order fuel"
                    swapFuelUtxos
            snapshot <- queryLedgerSnapshot provider
            let ownerBytes =
                    keyHashBytes genesisPaymentKeyHash
                offerLovelace :: Integer
                offerLovelace = 1_000_000
                datumParams =
                    SwapOrderDatumParams
                        { sodPoolId = spuIdent pool
                        , sodCoreOwner = ownerBytes
                        , sodOpsOwner = ownerBytes
                        , sodNetworkComplianceOwner = ownerBytes
                        , sodMiddlewareOwner = ownerBytes
                        , sodSundaeProtocolFeeLovelace = 2_500_000
                        , sodTreasuryScriptHash =
                            scriptHashBytes treasuryHash
                        , sodUsdmPolicy = policyIdBytes (sttPolicy token)
                        , sodUsdmToken =
                            assetNameRawBytes (sttAssetName token)
                        }
                orderOut =
                    SwapOrderOut
                        { soLovelace = Coin offerLovelace
                        , soDatum =
                            swapOrderDatum datumParams offerLovelace 1
                        }
                swapInputs =
                    FullSwapInputs
                        { fsiScopesRef =
                            GovernanceWithdrawalInit.dgwrScopesRef
                                registry
                        , fsiPermissionsRef =
                            GovernanceWithdrawalInit.dgwrPermissionsRef
                                registry
                        , fsiTreasuryRef =
                            GovernanceWithdrawalInit.dgwrTreasuryRef
                                registry
                        , fsiRegistryRef =
                            GovernanceWithdrawalInit.dgwrRegistryRef
                                registry
                        , fsiPermissionsRewardAccount =
                            permissionsRewardAccount
                                Testnet
                                ( GovernanceWithdrawalInit.dgwrPermissionsScriptHash
                                    registry
                                )
                        , fsiTreasuryAddress = treasuryAddress
                        , fsiSigners = [genesisGuardKeyHash]
                        , fsiWalletUtxo = fuelIn
                        , fsiExtraWalletInputs = []
                        , fsiSwapOrderAddress =
                            scriptAddr Testnet (ssbOrderHash scripts)
                        , fsiSwapOrders = [orderOut]
                        , fsiSwapOrderExtraLovelace = Coin 4_500_000
                        , fsiTreasuryUtxos = [treasuryIn]
                        , fsiTreasuryLeftoverLovelace =
                            Coin (treasuryBefore - offerLovelace)
                        , fsiTreasuryLeftoverAssets = mempty
                        , fsiUpperBound =
                            addSlots 20 (ledgerTipSlot snapshot)
                        }
            swapTxId <-
                buildSubmitAndWait
                    "swapProgram deployed-treasury order"
                    provider
                    submitter
                    pp
                    emptyInterpret
                    (evalWith provider)
                    [fuel, treasuryUtxo]
                    deployRefs
                    genesisAddr
                    (swapProgram (mkFullSwapIntent swapInputs))

            -- 5) locate the emitted order output and scoop it (#409)
            let orderRef = txOutRef swapTxId 0
            foundOrder <- waitForTxIns provider [orderRef] 60
            order <-
                case foundOrder of
                    [(ref, txOut)] ->
                        pure
                            SundaeOrderUtxo
                                { souTxIn = ref
                                , souTxOut = txOut
                                }
                    _ ->
                        expectationFailure
                            "swapProgram order output was not found"
                            *> error "unreachable"
            statusNote "S2 scoop the swapProgram order to the treasury"
            scoopFuel <- queryUTxOs provider genesisAddr
            swapEvidence <-
                scoopTreasurySwapOrder
                    provider
                    submitter
                    pp
                    scoopFuel
                    settingsForScoop
                    treasuryHash
                    treasuryAddress
                    token
                    pool
                    order
                    scripts
                    scriptRefs

            -- 6) full evidence: scoop proof (#409) + the debit,
            --    the swapProgram tx id, and the deploy anchors.
            let fullEvidence =
                    TreasuryFullSwapEvidence
                        { tfseScoopTxId = tseScoopTxId swapEvidence
                        , tfseOrderConsumed =
                            tseOrderConsumed swapEvidence
                        , tfseTreasuryTokenQuantity =
                            tseTreasuryTokenQuantity swapEvidence
                        , tfseTreasuryAddress =
                            tseTreasuryAddress swapEvidence
                        , tfseTreasuryScriptHash =
                            tseTreasuryScriptHash swapEvidence
                        , tfseSettingsHash =
                            tseSettingsHash swapEvidence
                        , tfsePoolHash = tsePoolHash swapEvidence
                        , tfsePoolStakeHash =
                            tsePoolStakeHash swapEvidence
                        , tfseOrderHash = tseOrderHash swapEvidence
                        , tfsePoolIdent = tsePoolIdent swapEvidence
                        , tfseTestTokenPolicy =
                            tseTestTokenPolicy swapEvidence
                        , tfseTestTokenName =
                            tseTestTokenName swapEvidence
                        , tfseTreasuryAdaBefore = treasuryBefore
                        , tfseTreasuryAdaAfter =
                            treasuryBefore - offerLovelace
                        , tfseSwapOrderTxId = renderTxId swapTxId
                        , tfseScopesRef =
                            txInToText
                                ( GovernanceWithdrawalInit.dgwrScopesRef
                                    registry
                                )
                        , tfsePermissionsRef =
                            txInToText
                                ( GovernanceWithdrawalInit.dgwrPermissionsRef
                                    registry
                                )
                        , tfseTreasuryRef =
                            txInToText
                                ( GovernanceWithdrawalInit.dgwrTreasuryRef
                                    registry
                                )
                        , tfseRegistryRef =
                            txInToText
                                ( GovernanceWithdrawalInit.dgwrRegistryRef
                                    registry
                                )
                        , tfsePermissionsHash =
                            GovernanceWithdrawalInit.dgwrPermissionsScriptHashText
                                registry
                        }
            writeTreasuryFullSwapArtifacts
                runDir
                socket
                timing
                fullEvidence
            statusMilestone "S2 DONE treasury-swap-full-e2e passed"

writeTreasuryFullSwapArtifacts
    :: FilePath
    -> FilePath
    -> ShelleyGenesisTiming
    -> TreasuryFullSwapEvidence
    -> IO ()
writeTreasuryFullSwapArtifacts runDir socket timing evidence = do
    let phaseDir =
            runDir </> "treasury-swap-full-e2e"
        summaryPath =
            phaseDir </> "summary.json"
        summary =
            object
                [ "schemaVersion" .= (1 :: Int)
                , "phase"
                    .= ("treasury-swap-full-e2e" :: String)
                , "status" .= ("passed" :: String)
                , "runDirectory" .= runDir
                , "socket" .= socket
                , "network" .= ("devnet" :: String)
                , "networkMagic" .= sgtNetworkMagic timing
                , "epochDurationSeconds"
                    .= epochDurationSeconds timing
                , "evidence" .= treasuryFullSwapValue evidence
                , "summaryPath" .= summaryPath
                ]
    createDirectoryIfMissing True phaseDir
    BSL.writeFile summaryPath (encode summary)
    BSL.writeFile (runDir </> "summary.json") (encode summary)
    writeFile
        (runDir </> "summary.log")
        (unlines (treasuryFullSwapLines evidence))
    mapM_ putStrLn (treasuryFullSwapLines evidence)

withFundedGovernanceReward
    :: FilePath
    -> ( Provider IO
         -> Submitter IO
         -> PParams ConwayEra
         -> [(TxIn, TxOut ConwayEra)]
         -> IO (TreasuryTarget, extra)
       )
    -> ( FilePath
         -> ShelleyGenesisTiming
         -> Provider IO
         -> Submitter IO
         -> extra
         -> GovernanceEvidence
         -> IO a
       )
    -> IO a
withFundedGovernanceReward runDir prepareTarget action = do
    prepareRunDir runDir
    createDirectoryIfMissing True (runDir </> "governance")

    sourceGenesis <- genesisDir
    assertGenesisDir sourceGenesis
    let smokeGenesis = runDir </> "governance" </> "genesis"
    copyGovernanceGenesis sourceGenesis smokeGenesis
    patchGovernanceGenesis smokeGenesis
    timing <- readShelleyTiming smokeGenesis
    let epochDuration = epochDurationSeconds timing
    sgtNetworkMagic timing `shouldBe` 42
    epochDuration `shouldSatisfy` (<= 10)

    withCardanoNode smokeGenesis $ \socket startMs -> do
        copyNodeLog socket runDir
        writeTiming runDir startMs socket timing
        withGovernanceNode socket $ \provider submitter -> do
            _ <- waitForTreasury provider withdrawalAmount 120
            pp <- queryProtocolParams provider
            utxos <- queryUTxOs provider genesisAddr
            (target, extra) <-
                prepareTarget provider submitter pp utxos
            fundingUtxos <- queryUTxOs provider genesisAddr
            evidence <-
                submitTreasuryWithdrawal
                    target
                    provider
                    submitter
                    pp
                    fundingUtxos
            action socket timing provider submitter extra evidence

data NoCtx a

data GovernanceEvidence = GovernanceEvidence
    { geTxId :: !String
    , geActionId :: !String
    , geRewardAccount :: !String
    , geTreasuryScriptHash :: !String
    , geAmountLovelace :: !Integer
    , geRewardBefore :: !Integer
    , geRewardAfter :: !Integer
    , geSetupEpoch :: !Word64
    , geVoteEpoch :: !Word64
    , geFinalEpoch :: !Word64
    }
    deriving stock (Eq, Show)

data WithdrawalSubmissionEvidence = WithdrawalSubmissionEvidence
    { wseSubmittedTxId :: !T.Text
    , wseSignedTxPath :: !FilePath
    , wseSubmitLogPath :: !FilePath
    , wseMaterializationPath :: !FilePath
    , wseTreasuryMaterializedTxIn :: !T.Text
    , wseTreasuryAddress :: !T.Text
    , wseMaterializedLovelace :: !Integer
    , wseRewardBeforeSubmit :: !Integer
    , wseRewardAfterSubmit :: !Integer
    , wseTreasuryLovelaceBefore :: !Integer
    , wseTreasuryLovelaceAfter :: !Integer
    }
    deriving stock (Eq, Show)

data SwapReadinessEvidence = SwapReadinessEvidence
    { sreOrderValidatorSourceRepository :: !T.Text
    , sreOrderValidatorSourceCommit :: !T.Text
    , sreOrderValidatorTitle :: !T.Text
    , sreOrderValidatorScriptHash :: !T.Text
    , sreOrderReferenceTxIn :: !T.Text
    , sreOrderAddress :: !T.Text
    }
    deriving stock (Eq, Show)

data ScoopM2OrderEvidence = ScoopM2OrderEvidence
    { smeOrderTxId :: !T.Text
    , smeOrderTxIn :: !T.Text
    , smeOrderAddress :: !T.Text
    , smePoolIdent :: !T.Text
    , smeOfferLovelace :: !Integer
    , smeMinReceived :: !Integer
    , smeScooperFeeLovelace :: !Integer
    , smeLockedLovelace :: !Integer
    , smeOwnerKeyHash :: !T.Text
    , smeDestinationScriptHash :: !T.Text
    }
    deriving stock (Eq, Show)

data ScoopE2EEvidence = ScoopE2EEvidence
    { seeSettingsTxIn :: !T.Text
    , seePoolTxIn :: !T.Text
    , seeOrderTxIn :: !T.Text
    , seeScoopTxId :: !T.Text
    , seeOrderConsumed :: !Bool
    , seeWalletTokenQuantity :: !Integer
    , seeSettingsHash :: !T.Text
    , seePoolHash :: !T.Text
    , seePoolStakeHash :: !T.Text
    , seeOrderHash :: !T.Text
    , seePoolIdent :: !T.Text
    , seeTestTokenPolicy :: !T.Text
    , seeTestTokenName :: !T.Text
    }
    deriving stock (Eq, Show)

data TreasurySwapEvidence = TreasurySwapEvidence
    { tseSettingsTxIn :: !T.Text
    , tsePoolTxIn :: !T.Text
    , tseOrderTxIn :: !T.Text
    , tseScoopTxId :: !T.Text
    , tseOrderConsumed :: !Bool
    , tseTreasuryTokenQuantity :: !Integer
    , tseTreasuryAddress :: !T.Text
    , tseTreasuryScriptHash :: !T.Text
    , tseSettingsHash :: !T.Text
    , tsePoolHash :: !T.Text
    , tsePoolStakeHash :: !T.Text
    , tseOrderHash :: !T.Text
    , tsePoolIdent :: !T.Text
    , tseTestTokenPolicy :: !T.Text
    , tseTestTokenName :: !T.Text
    }
    deriving stock (Eq, Show)

data SundaeScriptBundle = SundaeScriptBundle
    { ssbSettingsHash :: !ScriptHash
    , ssbSettingsScript :: !(Script ConwayEra)
    , ssbPoolHash :: !ScriptHash
    , ssbPoolScript :: !(Script ConwayEra)
    , ssbPoolStakeHash :: !ScriptHash
    , ssbPoolStakeScript :: !(Script ConwayEra)
    , ssbOrderHash :: !ScriptHash
    , ssbOrderScript :: !(Script ConwayEra)
    }

data SundaeReferenceScripts = SundaeReferenceScripts
    { srsPool :: !(TxIn, TxOut ConwayEra)
    , srsOrder :: !(TxIn, TxOut ConwayEra)
    , srsPoolStake :: !(TxIn, TxOut ConwayEra)
    }

newtype Blueprint = Blueprint
    { bpValidators :: [BlueprintValidator]
    }

instance FromJSON Blueprint where
    parseJSON =
        withObject "Blueprint" $ \o ->
            Blueprint <$> o .: "validators"

data BlueprintValidator = BlueprintValidator
    { bvTitle :: !T.Text
    , bvCompiledCode :: !T.Text
    }

instance FromJSON BlueprintValidator where
    parseJSON =
        withObject "BlueprintValidator" $ \o ->
            BlueprintValidator
                <$> o .: "title"
                <*> o .: "compiledCode"

data SundaeSettingsUtxo = SundaeSettingsUtxo
    { ssuTxIn :: !TxIn
    , ssuTxOut :: !(TxOut ConwayEra)
    }

data ScoopTestToken = ScoopTestToken
    { sttPolicy :: !PolicyID
    , sttAssetName :: !AssetName
    , sttHolding :: !(TxIn, TxOut ConwayEra)
    }

data SundaePoolUtxo = SundaePoolUtxo
    { spuTxIn :: !TxIn
    , spuTxOut :: !(TxOut ConwayEra)
    , spuIdent :: !BS.ByteString
    , spuNftName :: !AssetName
    , spuLpName :: !AssetName
    , spuRefName :: !AssetName
    }

data SundaeOrderUtxo = SundaeOrderUtxo
    { souTxIn :: !TxIn
    , souTxOut :: !(TxOut ConwayEra)
    }

data WithdrawalFailure
    = WithdrawalRewardTimeout !String !Coin !(Maybe Word64) !(Maybe Word64)
    | WithdrawalZeroRewards !String !Coin !(Maybe Word64) !(Maybe Word64)
    | WithdrawalNetworkMismatch
        !T.Text
        !T.Text
        !Coin
        !(Maybe Word64)
        !(Maybe Word64)
    | WithdrawalResolverFailed
        !Withdraw.WithdrawResolverError
        !Coin
        !(Maybe Word64)
        !(Maybe Word64)
    | WithdrawalIntentFailed
        !Withdraw.WithdrawError
        !Coin
        !(Maybe Word64)
        !(Maybe Word64)
    | WithdrawalTxBuildFailed !ExitCode !(Maybe Report.BuildFailure)
    deriving stock (Eq, Show)

withdrawalAmount :: Coin
withdrawalAmount = Coin 2_000_000

stakeDeposit :: Coin
stakeDeposit = Coin 400_000

governanceDeposit :: Coin
governanceDeposit = Coin 1_000_000

drepDeposit :: Coin
drepDeposit = Coin 500_000

voteOutputCoin :: Coin
voteOutputCoin = Coin 5_000_000

voterSignKey :: SignKeyDSIGN Ed25519DSIGN
voterSignKey =
    mkSignKey "amaru-governance-voter-key-00001"

devnetReferenceScriptCoin :: Coin
devnetReferenceScriptCoin = Coin 100_000_000

upstreamCardanoNodeClientsMain :: String
upstreamCardanoNodeClientsMain =
    "d6773e4cd8a2421617568c8dac0972b0f312a509"

sampleRunDir :: FilePath
sampleRunDir =
    "runs/devnet/sample"

sampleSocket :: FilePath
sampleSocket =
    "runs/devnet/sample/node.socket"

sampleTiming :: ShelleyGenesisTiming
sampleTiming =
    ShelleyGenesisTiming
        { sgtEpochLength = 5
        , sgtNetworkMagic = 42
        , sgtSlotLength = 1
        }

sampleRewardAccount :: String
sampleRewardAccount =
    "5da22eab0370edee0d4591f54bba0d79a89d973598f15eb609d968c4"

sampleEvidence :: GovernanceEvidence
sampleEvidence =
    (placeholderEvidence sampleRewardAccount (Coin 0))
        { geTxId =
            "5fd2aa15f7269474fa5709e9b804b26f3df60ff4b3c38b3f225797cfef165d43"
        , geActionId =
            "5fd2aa15f7269474fa5709e9b804b26f3df60ff4b3c38b3f225797cfef165d43#0"
        , geAmountLovelace = 2_000_000
        , geRewardAfter = 2_000_000
        , geSetupEpoch = 2
        , geVoteEpoch = 3
        , geFinalEpoch = 4
        }

sampleRegistryPath :: FilePath
sampleRegistryPath =
    RegistryInit.registryInitRegistryPath sampleRunDir

sampleStakeRewardPath :: FilePath
sampleStakeRewardPath =
    StakeRewardInit.stakeRewardInitAccountsPath sampleRunDir

sampleGovernanceProposalTxId :: T.Text
sampleGovernanceProposalTxId =
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

sampleGovernanceVoteTxId :: T.Text
sampleGovernanceVoteTxId =
    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

sampleGovernanceWithdrawTxId :: T.Text
sampleGovernanceWithdrawTxId =
    "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

sampleGovernanceActionId :: T.Text
sampleGovernanceActionId =
    sampleGovernanceProposalTxId <> "#0"

sampleGovernanceMaterializedTxIn :: T.Text
sampleGovernanceMaterializedTxIn =
    sampleGovernanceWithdrawTxId <> "#0"

sampleGovernanceTreasuryHash :: T.Text
sampleGovernanceTreasuryHash =
    T.pack sampleRewardAccount

sampleGovernanceTreasuryAddress :: T.Text
sampleGovernanceTreasuryAddress =
    "addr_test1wzsampletreasury"

sampleGovernanceWithdrawalInitResult
    :: GovernanceWithdrawalInit.GovernanceWithdrawalInitResult
sampleGovernanceWithdrawalInitResult =
    GovernanceWithdrawalInit.GovernanceWithdrawalInitResult
        { GovernanceWithdrawalInit.gwirRegistryPath =
            sampleRegistryPath
        , GovernanceWithdrawalInit.gwirStakeRewardPath =
            sampleStakeRewardPath
        , GovernanceWithdrawalInit.gwirGovernance =
            GovernanceWithdrawalInit.GovernanceWithdrawalGovernanceEvidence
                { GovernanceWithdrawalInit.gwgeProposalTxId =
                    sampleGovernanceProposalTxId
                , GovernanceWithdrawalInit.gwgeGovernanceActionId =
                    sampleGovernanceActionId
                , GovernanceWithdrawalInit.gwgeVoteTxId =
                    sampleGovernanceVoteTxId
                , GovernanceWithdrawalInit.gwgeTreasuryRewardAccount =
                    sampleGovernanceTreasuryHash
                , GovernanceWithdrawalInit.gwgeTreasuryScriptHash =
                    sampleGovernanceTreasuryHash
                , GovernanceWithdrawalInit.gwgeAmountLovelace =
                    2_000_000
                , GovernanceWithdrawalInit.gwgeRewardBeforeLovelace =
                    0
                , GovernanceWithdrawalInit.gwgeRewardAfterGovernanceLovelace =
                    2_000_000
                , GovernanceWithdrawalInit.gwgeSetupEpoch =
                    2
                , GovernanceWithdrawalInit.gwgeVoteEpoch =
                    3
                , GovernanceWithdrawalInit.gwgeFinalEpoch =
                    4
                }
        , GovernanceWithdrawalInit.gwirWithdrawal =
            GovernanceWithdrawalInit.GovernanceWithdrawalWithdrawalEvidence
                { GovernanceWithdrawalInit.gwweIntentPath =
                    GovernanceWithdrawalInit.governanceWithdrawalInitIntentPath
                        sampleRunDir
                , GovernanceWithdrawalInit.gwweTxBodyPath =
                    GovernanceWithdrawalInit.governanceWithdrawalInitTxBodyPath
                        sampleRunDir
                , GovernanceWithdrawalInit.gwweReportJsonPath =
                    GovernanceWithdrawalInit.governanceWithdrawalInitReportJsonPath
                        sampleRunDir
                , GovernanceWithdrawalInit.gwweReportMarkdownPath =
                    GovernanceWithdrawalInit.governanceWithdrawalInitReportMarkdownPath
                        sampleRunDir
                , GovernanceWithdrawalInit.gwweTxBuildLogPath =
                    GovernanceWithdrawalInit.governanceWithdrawalInitTxBuildLogPath
                        sampleRunDir
                , GovernanceWithdrawalInit.gwweSignedTxPath =
                    GovernanceWithdrawalInit.governanceWithdrawalInitSignedTxPath
                        sampleRunDir
                , GovernanceWithdrawalInit.gwweSubmitLogPath =
                    GovernanceWithdrawalInit.governanceWithdrawalInitSubmitLogPath
                        sampleRunDir
                , GovernanceWithdrawalInit.gwweTxId =
                    sampleGovernanceWithdrawTxId
                , GovernanceWithdrawalInit.gwweSubmittedTxId =
                    sampleGovernanceWithdrawTxId
                , GovernanceWithdrawalInit.gwweFeeLovelace =
                    173_000
                , GovernanceWithdrawalInit.gwweRewardBeforeSubmitLovelace =
                    2_000_000
                , GovernanceWithdrawalInit.gwweRewardAfterSubmitLovelace =
                    0
                }
        , GovernanceWithdrawalInit.gwirMaterialization =
            GovernanceWithdrawalInit.GovernanceWithdrawalMaterializationEvidence
                { GovernanceWithdrawalInit.gwmeGovernanceActionId =
                    sampleGovernanceActionId
                , GovernanceWithdrawalInit.gwmeTreasuryRewardAccount =
                    sampleGovernanceTreasuryHash
                , GovernanceWithdrawalInit.gwmeSubmittedTxId =
                    sampleGovernanceWithdrawTxId
                , GovernanceWithdrawalInit.gwmeTreasuryMaterializedTxIn =
                    sampleGovernanceMaterializedTxIn
                , GovernanceWithdrawalInit.gwmeTreasuryAddress =
                    sampleGovernanceTreasuryAddress
                , GovernanceWithdrawalInit.gwmeMaterializedAdaLovelace =
                    2_000_000
                , GovernanceWithdrawalInit.gwmeRewardBeforeSubmitLovelace =
                    2_000_000
                , GovernanceWithdrawalInit.gwmeRewardAfterSubmitLovelace =
                    0
                , GovernanceWithdrawalInit.gwmeTreasuryUtxoLovelaceBefore =
                    0
                , GovernanceWithdrawalInit.gwmeTreasuryUtxoLovelaceAfter =
                    2_000_000
                }
        }

sampleDisburseSubmitMaterializedPath :: FilePath
sampleDisburseSubmitMaterializedPath =
    GovernanceWithdrawalInit.governanceWithdrawalInitMaterializationPath
        sampleRunDir

sampleDisburseSubmitTxId :: T.Text
sampleDisburseSubmitTxId =
    "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"

sampleDisburseSubmitBeneficiaryAddress :: T.Text
sampleDisburseSubmitBeneficiaryAddress =
    "addr_test1vzsamplebeneficiary"

sampleDisburseSubmitBeneficiaryTxIn :: T.Text
sampleDisburseSubmitBeneficiaryTxIn =
    sampleDisburseSubmitTxId <> "#1"

sampleDisburseSubmitTreasuryOutput :: T.Text
sampleDisburseSubmitTreasuryOutput =
    sampleDisburseSubmitTxId <> "#0"

sampleDisburseSubmitResult :: DisburseSubmit.DisburseSubmitResult
sampleDisburseSubmitResult =
    DisburseSubmit.DisburseSubmitResult
        { DisburseSubmit.dsrRegistryPath =
            sampleRegistryPath
        , DisburseSubmit.dsrMaterializedPath =
            sampleDisburseSubmitMaterializedPath
        , DisburseSubmit.dsrDisburse =
            DisburseSubmit.DisburseSubmitDisburseEvidence
                { DisburseSubmit.dsdeIntentPath =
                    DisburseSubmit.disburseSubmitIntentPath sampleRunDir
                , DisburseSubmit.dsdeTxBodyPath =
                    DisburseSubmit.disburseSubmitTxBodyPath sampleRunDir
                , DisburseSubmit.dsdeReportJsonPath =
                    DisburseSubmit.disburseSubmitReportJsonPath sampleRunDir
                , DisburseSubmit.dsdeReportMarkdownPath =
                    DisburseSubmit.disburseSubmitReportMarkdownPath
                        sampleRunDir
                , DisburseSubmit.dsdeSignedTxPath =
                    DisburseSubmit.disburseSubmitSignedTxPath sampleRunDir
                , DisburseSubmit.dsdeSubmitLogPath =
                    DisburseSubmit.disburseSubmitSubmitLogPath sampleRunDir
                , DisburseSubmit.dsdeTxId =
                    sampleDisburseSubmitTxId
                , DisburseSubmit.dsdeSubmittedTxId =
                    sampleDisburseSubmitTxId
                , DisburseSubmit.dsdeAmountLovelace =
                    1_000_000
                , DisburseSubmit.dsdeFeeLovelace =
                    171_000
                }
        , DisburseSubmit.dsrBeneficiary =
            DisburseSubmit.DisburseSubmitBeneficiaryEvidence
                { DisburseSubmit.dsbeAddress =
                    sampleDisburseSubmitBeneficiaryAddress
                , DisburseSubmit.dsbeTxIn =
                    sampleDisburseSubmitBeneficiaryTxIn
                , DisburseSubmit.dsbeLovelace =
                    1_000_000
                }
        , DisburseSubmit.dsrTreasury =
            DisburseSubmit.DisburseSubmitTreasuryEvidence
                { DisburseSubmit.dsteInput =
                    sampleGovernanceMaterializedTxIn
                , DisburseSubmit.dsteOutput =
                    sampleDisburseSubmitTreasuryOutput
                , DisburseSubmit.dsteAddress =
                    sampleGovernanceTreasuryAddress
                , DisburseSubmit.dsteLovelaceBefore =
                    2_000_000
                , DisburseSubmit.dsteLovelaceAfter =
                    1_000_000
                , DisburseSubmit.dsteConsumed =
                    True
                }
        }

sampleSwapReadinessEvidence :: SwapReadinessEvidence
sampleSwapReadinessEvidence =
    SwapReadinessEvidence
        { sreOrderValidatorSourceRepository =
            sundaeOrderValidatorSourceRepository
        , sreOrderValidatorSourceCommit =
            sundaeOrderValidatorSourceCommit
        , sreOrderValidatorTitle =
            sundaeOrderValidatorTitle
        , sreOrderValidatorScriptHash =
            sundaeOrderValidatorScriptHashHex
        , sreOrderReferenceTxIn =
            "4c945c6b2d9d8df841f7079d20d32e7bc4eb1f3b0873a134b9dca7c95d22afad#0"
        , sreOrderAddress =
            "addr_test1wzsampleorder"
        }

sampleRegistryPublication :: IO DevnetRegistryPublication
sampleRegistryPublication = do
    target <-
        RegistryInit.treasuryTargetFromBlob Testnet
            =<< expectEither
                "derive sample registry-init treasury script"
                (derivedTreasuryScriptBlob CoreDevelopment)
    pure
        DevnetRegistryPublication
            { drpSeedSplitTxId = sampleTxId 10
            , drpRegistryMintTxId = sampleTxId 11
            , drpReferenceScriptsTxId = sampleTxId 12
            , drpAnchors =
                DevnetRegistryAnchors
                    { draScopesRef = txOutRef (sampleTxId 20) 0
                    , draPermissionsRef = txOutRef (sampleTxId 21) 1
                    , draTreasuryRef = txOutRef (sampleTxId 22) 2
                    , draRegistryRef = txOutRef (sampleTxId 23) 3
                    , draScopesPolicyId =
                        "44444444444444444444444444444444444444444444444444444444"
                    , draRegistryPolicyId =
                        "22222222222222222222222222222222222222222222222222222222"
                    , draPermissionsHash = ttScriptHash target
                    , draOwnerKeyHash =
                        "33333333333333333333333333333333333333333333333333333333"
                    , draTreasuryTarget = target
                    }
            }

preparePinnedTreasuryTarget
    :: Provider IO
    -> Submitter IO
    -> PParams ConwayEra
    -> [(TxIn, TxOut ConwayEra)]
    -> IO (TreasuryTarget, ())
preparePinnedTreasuryTarget _provider _submitter _pp _utxos = do
    target <-
        RegistryInit.treasuryTargetFromBlob Testnet
            =<< expectEither
                "derive pinned treasury script"
                (derivedTreasuryScriptBlob CoreDevelopment)
    pure (target, ())

publishSwapReadiness
    :: Provider IO
    -> Submitter IO
    -> PParams ConwayEra
    -> [(TxIn, TxOut ConwayEra)]
    -> IO SwapReadinessEvidence
publishSwapReadiness provider submitter pp utxos = do
    orderHash <-
        expectEither
            "hash public SundaeSwap V3 order.spend validator"
            (scriptHashOfBlob sundaeOrderValidatorBlob)
    scriptHashToHex orderHash
        `shouldBe` sundaeOrderValidatorScriptHashHex
    orderScript <- scriptFromBlob sundaeOrderValidatorBlob
    seed@(seedIn, _) <-
        selectLargestAdaUtxo
            "SundaeSwap V3 order reference script publishing"
            utxos
    snapshot <- queryLedgerSnapshot provider
    let orderAddress =
            scriptAddr Testnet orderHash
        orderOut =
            refScriptTxOut orderAddress orderScript
        interpret :: InterpretIO NoCtx
        interpret =
            InterpretIO $ \case {}
        eval tx =
            fmap
                (Map.map (either (Left . show) Right))
                (evaluateTx provider tx)
        upperSlot =
            addSlots 20 (ledgerTipSlot snapshot)
        prog :: TxBuild NoCtx Void ()
        prog = do
            _ <- spend seedIn
            orderIx <- output orderOut
            checkMinUtxo pp orderIx
            validTo upperSlot
    txId <-
        buildSubmitAndWait
            "publish SundaeSwap V3 order reference script"
            provider
            submitter
            pp
            interpret
            eval
            [seed]
            []
            genesisAddr
            prog
    let referenceTxIn =
            txOutRef txId 0
    found <-
        waitForTxIns provider [referenceTxIn] 60
    published <- case found of
        [(_, txOut)] -> pure txOut
        _ ->
            expectationFailure "published order reference UTxO was not found"
                *> error "unreachable"
    published ^. addrTxOutL `shouldBe` orderAddress
    case published ^. referenceScriptTxOutL of
        SJust script ->
            scriptHashToHex (Core.hashScript @ConwayEra script)
                `shouldBe` sundaeOrderValidatorScriptHashHex
        SNothing ->
            expectationFailure
                "published order reference UTxO has no reference script"
    pure
        SwapReadinessEvidence
            { sreOrderValidatorSourceRepository =
                sundaeOrderValidatorSourceRepository
            , sreOrderValidatorSourceCommit =
                sundaeOrderValidatorSourceCommit
            , sreOrderValidatorTitle =
                sundaeOrderValidatorTitle
            , sreOrderValidatorScriptHash =
                sundaeOrderValidatorScriptHashHex
            , sreOrderReferenceTxIn =
                txInToText referenceTxIn
            , sreOrderAddress =
                renderAddr orderAddress
            }

publishScoopM2Order
    :: Provider IO
    -> Submitter IO
    -> PParams ConwayEra
    -> [(TxIn, TxOut ConwayEra)]
    -> SwapReadinessEvidence
    -> IO ScoopM2OrderEvidence
publishScoopM2Order provider submitter pp utxos _readiness = do
    orderHash <-
        expectEither
            "hash public SundaeSwap V3 order.spend validator"
            (scriptHashOfBlob sundaeOrderValidatorBlob)
    seed@(seedIn, _) <-
        selectLargestAdaUtxo
            "SundaeSwap V3 order funding"
            utxos
    snapshot <- queryLedgerSnapshot provider
    let orderAddress =
            scriptAddr Testnet orderHash
        ownerHash :: KeyHash Payment
        ownerHash =
            hashKey (VKey (deriveVerKeyDSIGN genesisSignKey))
        ownerBytes =
            keyHashBytes ownerHash
        ownerHex =
            TE.decodeUtf8 (B16.encode ownerBytes)
        destinationBytes =
            scriptHashBytes orderHash
        destinationHex =
            TE.decodeUtf8 (B16.encode destinationBytes)
        poolIdent =
            "devnet-faked-scoop-pool"
        offerLovelace =
            10_000_000
        minReceived =
            1
        scooperFee =
            1_280_000
        minDeposit =
            2_000_000
        lockedLovelace =
            offerLovelace + scooperFee + minDeposit
        datumParams =
            SwapOrderDatumParams
                { sodPoolId = BS8.pack (T.unpack poolIdent)
                , sodCoreOwner = ownerBytes
                , sodOpsOwner = ownerBytes
                , sodNetworkComplianceOwner = ownerBytes
                , sodMiddlewareOwner = ownerBytes
                , sodSundaeProtocolFeeLovelace = scooperFee
                , sodTreasuryScriptHash = destinationBytes
                , sodUsdmPolicy = "devnet-policy"
                , sodUsdmToken = "SCOOP"
                }
        orderDatum =
            swapOrderDatum datumParams offerLovelace minReceived
        orderOut =
            mkBasicTxOut
                orderAddress
                (MaryValue (Coin lockedLovelace) (MultiAsset Map.empty))
                & datumTxOutL .~ mkInlineDatum @ConwayEra orderDatum
        interpret :: InterpretIO NoCtx
        interpret =
            InterpretIO $ \case {}
        eval tx =
            fmap
                (Map.map (either (Left . show) Right))
                (evaluateTx provider tx)
        upperSlot =
            addSlots 20 (ledgerTipSlot snapshot)
        prog :: TxBuild NoCtx Void ()
        prog = do
            _ <- spend seedIn
            orderIx <- output orderOut
            checkMinUtxo pp orderIx
            validTo upperSlot
    txId <-
        buildSubmitAndWait
            "fund SundaeSwap V3 order"
            provider
            submitter
            pp
            interpret
            eval
            [seed]
            []
            genesisAddr
            prog
    orderUtxos <- waitForUtxos provider orderAddress 60
    (orderRef, landed) <-
        case filter (hasTxId txId . fst) orderUtxos of
            [found] -> pure found
            found : _ -> pure found
            [] ->
                expectationFailure
                    "funded order UTxO was not found at order address"
                    *> error "unreachable"
    landed ^. addrTxOutL `shouldBe` orderAddress
    pure
        ScoopM2OrderEvidence
            { smeOrderTxId = renderTxId txId
            , smeOrderTxIn = txInToText orderRef
            , smeOrderAddress = renderAddr orderAddress
            , smePoolIdent = poolIdent
            , smeOfferLovelace = offerLovelace
            , smeMinReceived = minReceived
            , smeScooperFeeLovelace = scooperFee
            , smeLockedLovelace = lockedLovelace
            , smeOwnerKeyHash = ownerHex
            , smeDestinationScriptHash = destinationHex
            }

deriveFreshSundaeScripts :: FilePath -> TxIn -> IO SundaeScriptBundle
deriveFreshSundaeScripts runDir bootIn = do
    contractsDir <-
        fromMaybe "/tmp/devnet-scoop/codex-scoop/sundae-contracts"
            <$> lookupEnv "SUNDAE_CONTRACTS_DIR"
    statusNote "M3 running aiken build for unapplied Sundae blueprint"
    (code, out, err) <-
        withCurrentDirectory contractsDir $
            readProcessWithExitCode
                "nix"
                ["run", "github:aiken-lang/aiken", "--", "build"]
                ""
    case code of
        ExitSuccess -> pure ()
        ExitFailure n ->
            expectationFailure
                ( "aiken build failed with "
                    <> show n
                    <> "\nstdout:\n"
                    <> out
                    <> "\nstderr:\n"
                    <> err
                )
                *> error "unreachable"
    let blueprintPath =
            contractsDir </> "plutus.json"
        copiedBlueprint =
            runDir </> "scoop-e2e" </> "plutus-unapplied.json"
    copyFile blueprintPath copiedBlueprint
    blueprint <-
        decodeJsonFile "fresh Sundae blueprint" blueprintPath
    let raw title =
            case [ bytes
                 | validator <- bpValidators blueprint
                 , bvTitle validator == title
                 , let decoded =
                        B16.decode (TE.encodeUtf8 (bvCompiledCode validator))
                 , Right bytes <- [decoded]
                 ] of
                bytes : _ -> pure bytes
                [] ->
                    expectationFailure
                        ("missing compiledCode for " <> T.unpack title)
                        *> error "unreachable"
        bootData =
            outputReferenceDataFromTxIn bootIn
    settingsRaw <- raw "settings.settings.mint"
    settingsBlob <-
        expectEither
            "apply fresh settings boot parameter"
            (applyScriptParams settingsRaw [ParamData bootData])
    settingsHash <-
        expectEither "hash fresh settings script" $
            scriptHashOfBlob settingsBlob
    let settingsBytes =
            scriptHashBytes settingsHash
    manageRaw <- raw "pool.manage.else"
    manageBlob <-
        expectEither
            "apply fresh manage-stake settings parameter"
            (applyScriptParams manageRaw [ParamData (B settingsBytes)])
    manageHash <-
        expectEither "hash fresh manage-stake script" $
            scriptHashOfBlob manageBlob
    poolRaw <- raw "pool.pool.mint"
    poolBlob <-
        expectEither
            "apply fresh pool parameters"
            ( applyScriptParams
                poolRaw
                [ ParamData (B (scriptHashBytes manageHash))
                , ParamData (B settingsBytes)
                ]
            )
    poolHash <-
        expectEither "hash fresh pool script" $
            scriptHashOfBlob poolBlob
    poolStakeRaw <- raw "pool_stake.pool_stake.else"
    poolStakeBlob <-
        expectEither
            "apply fresh pool-stake parameters"
            ( applyScriptParams
                poolStakeRaw
                [ParamData (B settingsBytes), ParamData (I 0)]
            )
    poolStakeHash <-
        expectEither "hash fresh pool-stake script" $
            scriptHashOfBlob poolStakeBlob
    orderRaw <- raw "order.order.spend"
    orderBlob <-
        expectEither
            "apply fresh order stake parameter"
            ( applyScriptParams
                orderRaw
                [ParamData (B (scriptHashBytes poolStakeHash))]
            )
    orderHash <-
        expectEither "hash fresh order script" $
            scriptHashOfBlob orderBlob
    statusNote $
        "M3 derived fresh hashes settings="
            <> T.unpack (scriptHashToHex settingsHash)
            <> " pool="
            <> T.unpack (scriptHashToHex poolHash)
            <> " pool_stake="
            <> T.unpack (scriptHashToHex poolStakeHash)
            <> " order="
            <> T.unpack (scriptHashToHex orderHash)
    settingsScript <- scriptFromBlob settingsBlob
    poolScript <- scriptFromBlob poolBlob
    poolStakeScript <- scriptFromBlob poolStakeBlob
    orderScript <- scriptFromBlob orderBlob
    pure
        SundaeScriptBundle
            { ssbSettingsHash = settingsHash
            , ssbSettingsScript = settingsScript
            , ssbPoolHash = poolHash
            , ssbPoolScript = poolScript
            , ssbPoolStakeHash = poolStakeHash
            , ssbPoolStakeScript = poolStakeScript
            , ssbOrderHash = orderHash
            , ssbOrderScript = orderScript
            }

publishSundaeReferenceScripts
    :: Provider IO
    -> Submitter IO
    -> PParams ConwayEra
    -> SundaeScriptBundle
    -> IO SundaeReferenceScripts
publishSundaeReferenceScripts provider submitter pp scripts = do
    poolRef <-
        publishSundaeReferenceScript
            provider
            submitter
            pp
            "pool"
            (ssbPoolHash scripts)
            (ssbPoolScript scripts)
    orderRef <-
        publishSundaeReferenceScript
            provider
            submitter
            pp
            "order"
            (ssbOrderHash scripts)
            (ssbOrderScript scripts)
    poolStakeRef <-
        publishSundaeReferenceScript
            provider
            submitter
            pp
            "pool_stake"
            (ssbPoolStakeHash scripts)
            (ssbPoolStakeScript scripts)
    pure
        SundaeReferenceScripts
            { srsPool = poolRef
            , srsOrder = orderRef
            , srsPoolStake = poolStakeRef
            }

publishSundaeReferenceScript
    :: Provider IO
    -> Submitter IO
    -> PParams ConwayEra
    -> String
    -> ScriptHash
    -> Script ConwayEra
    -> IO (TxIn, TxOut ConwayEra)
publishSundaeReferenceScript provider submitter pp label scriptHash script = do
    statusNote ("M3 publish " <> label <> " reference script")
    walletUtxos <- queryUTxOs provider genesisAddr
    seed@(seedIn, _) <-
        selectLargestAdaUtxo
            ("fresh Sundae " <> label <> " reference script publishing")
            walletUtxos
    snapshot <- queryLedgerSnapshot provider
    let refAddress =
            scriptAddr Testnet scriptHash
        refOut =
            refScriptTxOut refAddress script
        upperSlot =
            addSlots 20 (ledgerTipSlot snapshot)
        prog :: TxBuild NoCtx Void ()
        prog = do
            _ <- spend seedIn
            refIx <- output refOut
            checkMinUtxo pp refIx
            validTo upperSlot
    txId <-
        buildSubmitAndWait
            ("publish fresh Sundae " <> label <> " reference script")
            provider
            submitter
            pp
            emptyInterpret
            (evalWith provider)
            [seed]
            []
            genesisAddr
            prog
    let refTxIn =
            txOutRef txId 0
    found <-
        waitForTxIns provider [refTxIn] 60
    case found of
        [(txIn, txOut)] -> do
            txOut ^. addrTxOutL `shouldBe` refAddress
            case txOut ^. referenceScriptTxOutL of
                SJust actualScript ->
                    Core.hashScript @ConwayEra actualScript
                        `shouldBe` scriptHash
                SNothing ->
                    expectationFailure $
                        "published " <> label <> " reference UTxO has no script"
            pure (txIn, txOut)
        _ ->
            expectationFailure
                ("published " <> label <> " reference UTxO was not found")
                *> error "unreachable"

refreshSettingsBeforeReferenceScripts
    :: Provider IO
    -> Submitter IO
    -> PParams ConwayEra
    -> SundaeSettingsUtxo
    -> SundaeScriptBundle
    -> SundaeReferenceScripts
    -> IO SundaeSettingsUtxo
refreshSettingsBeforeReferenceScripts
    provider
    submitter
    pp
    settings
    scripts
    scriptRefs =
        go (10 :: Int) settings
      where
        refTxIns =
            fst
                <$> [srsPool scriptRefs, srsOrder scriptRefs, srsPoolStake scriptRefs]
        firstRef =
            minimum refTxIns
        go attempts current
            | ssuTxIn current < firstRef = do
                statusNote $
                    "M4 settings reference sorts before script refs settings="
                        <> T.unpack (txInToText (ssuTxIn current))
                pure current
            | attempts <= 0 =
                expectationFailure
                    "could not refresh settings UTxO before script reference inputs"
                    *> error "unreachable"
            | otherwise = do
                statusNote $
                    "M4 refresh settings UTxO for reference-input ordering attempt="
                        <> show (11 - attempts)
                refreshed <-
                    refreshSundaeSettings provider submitter pp current scripts
                go (attempts - 1) refreshed

refreshSundaeSettings
    :: Provider IO
    -> Submitter IO
    -> PParams ConwayEra
    -> SundaeSettingsUtxo
    -> SundaeScriptBundle
    -> IO SundaeSettingsUtxo
refreshSundaeSettings provider submitter pp settings scripts = do
    walletUtxos <- queryUTxOs provider genesisAddr
    fuel@(fuelIn, _) <-
        selectLargestAdaUtxo "fresh Sundae settings refresh fuel" walletUtxos
    snapshot <- queryLedgerSnapshot provider
    let upperSlot =
            addSlots 20 (ledgerTipSlot snapshot)
        lowerSlot =
            ledgerTipSlot snapshot
        prog :: TxBuild NoCtx Void ()
        prog = do
            _ <- spend fuelIn
            collateral fuelIn
            attachScript (ssbSettingsScript scripts)
            requiredSignature genesisGuardKeyHash
            _ <-
                spendScript
                    (ssuTxIn settings)
                    (RawPlutusData settingsAdminUpdateRedeemer)
            settingsIx <- output (ssuTxOut settings)
            checkMinUtxo pp settingsIx
            validFrom lowerSlot
            validTo upperSlot
    txId <-
        buildSubmitAndWait
            "refresh fresh Sundae settings"
            provider
            submitter
            pp
            emptyInterpret
            (evalWith provider)
            [fuel, (ssuTxIn settings, ssuTxOut settings)]
            []
            genesisAddr
            prog
    let refreshedTxIn =
            txOutRef txId 0
    found <-
        waitForTxIns provider [refreshedTxIn] 60
    case found of
        [(txIn, txOut)] ->
            pure SundaeSettingsUtxo{ssuTxIn = txIn, ssuTxOut = txOut}
        _ ->
            expectationFailure "refreshed settings UTxO was not found"
                *> error "unreachable"

registerFreshPoolStakeRewardAccount
    :: Provider IO
    -> Submitter IO
    -> PParams ConwayEra
    -> SundaeSettingsUtxo
    -> SundaeScriptBundle
    -> IO ()
registerFreshPoolStakeRewardAccount provider submitter pp settings scripts = do
    walletUtxos <- queryUTxOs provider genesisAddr
    seed@(seedIn, _) <-
        selectLargestAdaUtxo "fresh pool_stake registration fuel" walletUtxos
    snapshot <- queryLedgerSnapshot provider
    let credential =
            ScriptHashObj (ssbPoolStakeHash scripts)
        upperSlot =
            addSlots 20 (ledgerTipSlot snapshot)
        lowerSlot =
            ledgerTipSlot snapshot
        prog :: TxBuild NoCtx Void ()
        prog = do
            _ <- spend seedIn
            collateral seedIn
            reference (ssuTxIn settings)
            attachScript (ssbPoolStakeScript scripts)
            requiredSignature genesisGuardKeyHash
            _ <-
                certify
                    ( ConwayTxCertDeleg $
                        ConwayRegDelegCert
                            credential
                            (DelegVote DRepAlwaysAbstain)
                            stakeDeposit
                    )
                    (ScriptCert (RawPlutusData emptyListRedeemer))
            validFrom lowerSlot
            validTo upperSlot
    _ <-
        buildSubmitAndWait
            "register fresh pool_stake reward account"
            provider
            submitter
            pp
            emptyInterpret
            (evalWith provider)
            [seed]
            [(ssuTxIn settings, ssuTxOut settings)]
            genesisAddr
            prog
    pure ()

bootstrapSundaeSettings
    :: Provider IO
    -> Submitter IO
    -> PParams ConwayEra
    -> (TxIn, TxOut ConwayEra)
    -> SundaeScriptBundle
    -> IO SundaeSettingsUtxo
bootstrapSundaeSettings provider submitter pp seed@(seedIn, _) scripts = do
    snapshot <- queryLedgerSnapshot provider
    let settingsPolicy =
            PolicyID (ssbSettingsHash scripts)
        settingsName =
            AssetName (SBS.toShort "settings")
        owner =
            genesisPaymentKeyHash
        ownerGuard =
            genesisGuardKeyHash
        ownerBytes =
            keyHashBytes owner
        settingsAddress =
            scriptAddr Testnet (ssbSettingsHash scripts)
        metadataAddress =
            walletAddr owner
        settingsOut =
            inlineDatumTxOut
                settingsAddress
                ( MaryValue
                    (Coin 5_000_000)
                    (singleAsset settingsPolicy settingsName 1)
                )
                (settingsDatum ownerBytes)
        upperSlot =
            addSlots 20 (ledgerTipSlot snapshot)
        interpret =
            emptyInterpret
        eval =
            evalWith provider
        prog :: TxBuild NoCtx Void ()
        prog = do
            _ <- spend seedIn
            collateral seedIn
            requiredSignature ownerGuard
            attachScript (ssbSettingsScript scripts)
            mint
                settingsPolicy
                (Map.singleton settingsName 1)
                (RawPlutusData emptyListRedeemer)
            ix <- output settingsOut
            checkMinUtxo pp ix
            validTo upperSlot
    txId <-
        buildSubmitAndWait
            "bootstrap fresh Sundae settings"
            provider
            submitter
            pp
            interpret
            eval
            [seed]
            []
            metadataAddress
            prog
    let settingsRef =
            txOutRef txId 0
    found <- waitForTxIns provider [settingsRef] 60
    case found of
        [(ref, txOut)] ->
            pure SundaeSettingsUtxo{ssuTxIn = ref, ssuTxOut = txOut}
        _ ->
            expectationFailure "fresh settings UTxO was not found"
                *> error "unreachable"

mintScoopTestToken
    :: Provider IO
    -> Submitter IO
    -> PParams ConwayEra
    -> [(TxIn, TxOut ConwayEra)]
    -> IO ScoopTestToken
mintScoopTestToken provider submitter pp utxos = do
    seed@(seedIn, _) <-
        selectLargestAdaUtxo "fresh scoop test-token funding" utxos
    snapshot <- queryLedgerSnapshot provider
    let tokenScript =
            alwaysTrueScript
        policy =
            PolicyID (Core.hashScript @ConwayEra tokenScript)
        assetName =
            AssetName (SBS.toShort "SCOOP")
        tokenOut =
            mkBasicTxOut
                genesisAddr
                ( MaryValue
                    (Coin 1_100_000_000)
                    (singleAsset policy assetName 1_000_000_000)
                )
        upperSlot =
            addSlots 20 (ledgerTipSlot snapshot)
        prog :: TxBuild NoCtx Void ()
        prog = do
            _ <- spend seedIn
            collateral seedIn
            attachScript tokenScript
            mint
                policy
                (Map.singleton assetName 1_000_000_000)
                (RawPlutusData emptyListRedeemer)
            ix <- output tokenOut
            checkMinUtxo pp ix
            validTo upperSlot
    txId <-
        buildSubmitAndWait
            "mint fresh scoop test token"
            provider
            submitter
            pp
            emptyInterpret
            (evalWith provider)
            [seed]
            []
            genesisAddr
            prog
    let tokenRef =
            txOutRef txId 0
    found <- waitForTxIns provider [tokenRef] 60
    case found of
        [holding] ->
            pure
                ScoopTestToken
                    { sttPolicy = policy
                    , sttAssetName = assetName
                    , sttHolding = holding
                    }
        _ ->
            expectationFailure "fresh test-token UTxO was not found"
                *> error "unreachable"

createSundaePool
    :: Provider IO
    -> Submitter IO
    -> PParams ConwayEra
    -> SundaeSettingsUtxo
    -> ScoopTestToken
    -> SundaeScriptBundle
    -> IO SundaePoolUtxo
createSundaePool provider submitter pp settings token scripts = do
    walletUtxos <- queryUTxOs provider genesisAddr
    collateralSeed <-
        selectLargestAdaUtxo "fresh pool collateral" walletUtxos
    snapshot <- queryLedgerSnapshot provider
    let poolPolicy =
            PolicyID (ssbPoolHash scripts)
        poolIdent =
            poolIdentFromTxIn (fst (sttHolding token))
        refName =
            AssetName (SBS.toShort (poolRefName poolIdent))
        nftName =
            AssetName (SBS.toShort (poolNftName poolIdent))
        lpName =
            AssetName (SBS.toShort (poolLpName poolIdent))
        poolAddress =
            poolAddr (ssbPoolHash scripts) genesisStakingKeyHash
        metadataAddress =
            walletAddr genesisPaymentKeyHash
        poolValue =
            MaryValue
                (Coin 1_002_000_000)
                ( multiAsset
                    [ (sttPolicy token, sttAssetName token, 1_000_000_000)
                    , (poolPolicy, nftName, 1)
                    ]
                )
        lpValue =
            MaryValue
                (Coin 2_000_000)
                (singleAsset poolPolicy lpName 1_000_000_000)
        refValue =
            MaryValue
                (Coin 2_000_000)
                (singleAsset poolPolicy refName 1)
        poolDatumValue =
            poolDatum
                poolIdent
                (policyIdBytes (sttPolicy token))
                (assetNameRawBytes (sttAssetName token))
                1_000_000_000
                2_000_000
        poolOut =
            inlineDatumTxOut poolAddress poolValue poolDatumValue
        refOut =
            inlineDatumTxOut metadataAddress refValue voidData
        upperSlot =
            addSlots 20 (ledgerTipSlot snapshot)
        mintRedeemer =
            createPoolRedeemer
                (policyIdBytes (sttPolicy token))
                (assetNameRawBytes (sttAssetName token))
        prog :: TxBuild NoCtx Void ()
        prog = do
            _ <- spend (fst (sttHolding token))
            collateral (fst collateralSeed)
            reference (ssuTxIn settings)
            attachScript (ssbPoolScript scripts)
            mint
                poolPolicy
                ( Map.fromList
                    [ (refName, 1)
                    , (nftName, 1)
                    , (lpName, 1_000_000_000)
                    ]
                )
                (RawPlutusData mintRedeemer)
            poolIx <- output poolOut
            _ <- output (mkBasicTxOut metadataAddress lpValue)
            refIx <- output refOut
            checkMinUtxo pp poolIx
            checkMinUtxo pp refIx
            validTo upperSlot
    txId <-
        buildSubmitAndWait
            "create fresh Sundae pool"
            provider
            submitter
            pp
            emptyInterpret
            (evalWith provider)
            [sttHolding token, collateralSeed]
            [(ssuTxIn settings, ssuTxOut settings)]
            genesisAddr
            prog
    let poolRef =
            txOutRef txId 0
    found <- waitForTxIns provider [poolRef] 60
    case found of
        [(ref, txOut)] ->
            pure
                SundaePoolUtxo
                    { spuTxIn = ref
                    , spuTxOut = txOut
                    , spuIdent = poolIdent
                    , spuNftName = nftName
                    , spuLpName = lpName
                    , spuRefName = refName
                    }
        _ ->
            expectationFailure "fresh pool UTxO was not found"
                *> error "unreachable"

placeGenericSundaeOrder
    :: Provider IO
    -> Submitter IO
    -> PParams ConwayEra
    -> [(TxIn, TxOut ConwayEra)]
    -> ScoopTestToken
    -> SundaeScriptBundle
    -> IO SundaeOrderUtxo
placeGenericSundaeOrder provider submitter pp utxos token scripts = do
    seed@(seedIn, _) <-
        selectLargestAdaUtxo "fresh generic order funding" utxos
    snapshot <- queryLedgerSnapshot provider
    let orderAddress =
            scriptAddr Testnet (ssbOrderHash scripts)
        orderOut =
            inlineDatumTxOut
                orderAddress
                (MaryValue (Coin 14_500_000) (MultiAsset Map.empty))
                (genericOrderDatum token)
        upperSlot =
            addSlots 20 (ledgerTipSlot snapshot)
        prog :: TxBuild NoCtx Void ()
        prog = do
            _ <- spend seedIn
            ix <- output orderOut
            checkMinUtxo pp ix
            validTo upperSlot
    txId <-
        buildSubmitAndWait
            "place generic Sundae order"
            provider
            submitter
            pp
            emptyInterpret
            (evalWith provider)
            [seed]
            []
            genesisAddr
            prog
    let orderRef =
            txOutRef txId 0
    found <- waitForTxIns provider [orderRef] 60
    case found of
        [(ref, txOut)] ->
            pure SundaeOrderUtxo{souTxIn = ref, souTxOut = txOut}
        _ ->
            expectationFailure "fresh generic order UTxO was not found"
                *> error "unreachable"

placeTreasurySwapOrder
    :: Provider IO
    -> Submitter IO
    -> PParams ConwayEra
    -> [(TxIn, TxOut ConwayEra)]
    -> ScriptHash
    -> ScoopTestToken
    -> SundaePoolUtxo
    -> SundaeScriptBundle
    -> IO SundaeOrderUtxo
placeTreasurySwapOrder
    provider
    submitter
    pp
    utxos
    treasuryHash
    token
    pool
    scripts = do
        seed@(seedIn, _) <-
            selectLargestAdaUtxo "fresh treasury swap order funding" utxos
        snapshot <- queryLedgerSnapshot provider
        let orderAddress =
                scriptAddr Testnet (ssbOrderHash scripts)
            ownerBytes =
                keyHashBytes genesisPaymentKeyHash
            offerLovelace =
                10_000_000
            minReceived =
                1
            scooperFee =
                2_500_000
            lockedLovelace =
                14_500_000
            datumParams =
                SwapOrderDatumParams
                    { sodPoolId = spuIdent pool
                    , sodCoreOwner = ownerBytes
                    , sodOpsOwner = ownerBytes
                    , sodNetworkComplianceOwner = ownerBytes
                    , sodMiddlewareOwner = ownerBytes
                    , sodSundaeProtocolFeeLovelace = scooperFee
                    , sodTreasuryScriptHash = scriptHashBytes treasuryHash
                    , sodUsdmPolicy = policyIdBytes (sttPolicy token)
                    , sodUsdmToken = assetNameRawBytes (sttAssetName token)
                    }
            orderOut =
                inlineDatumTxOut
                    orderAddress
                    (MaryValue (Coin lockedLovelace) (MultiAsset Map.empty))
                    (swapOrderDatum datumParams offerLovelace minReceived)
            upperSlot =
                addSlots 20 (ledgerTipSlot snapshot)
            prog :: TxBuild NoCtx Void ()
            prog = do
                _ <- spend seedIn
                ix <- output orderOut
                checkMinUtxo pp ix
                validTo upperSlot
        txId <-
            buildSubmitAndWait
                "place treasury Sundae order"
                provider
                submitter
                pp
                emptyInterpret
                (evalWith provider)
                [seed]
                []
                genesisAddr
                prog
        let orderRef =
                txOutRef txId 0
        found <- waitForTxIns provider [orderRef] 60
        case found of
            [(ref, txOut)] ->
                pure SundaeOrderUtxo{souTxIn = ref, souTxOut = txOut}
            _ ->
                expectationFailure "fresh treasury order UTxO was not found"
                    *> error "unreachable"

scoopSundaeOrder
    :: Provider IO
    -> Submitter IO
    -> PParams ConwayEra
    -> [(TxIn, TxOut ConwayEra)]
    -> SundaeSettingsUtxo
    -> ScoopTestToken
    -> SundaePoolUtxo
    -> SundaeOrderUtxo
    -> SundaeScriptBundle
    -> SundaeReferenceScripts
    -> IO ScoopE2EEvidence
scoopSundaeOrder
    provider
    submitter
    pp
    utxos
    settings
    token
    pool
    order
    scripts
    scriptRefs = do
        fuel@(fuelIn, _) <-
            selectLargestAdaUtxo "fresh scoop fee fuel" utxos
        snapshot <- queryLedgerSnapshot provider
        let poolPolicy =
                PolicyID (ssbPoolHash scripts)
            ownerGuard =
                genesisGuardKeyHash
            poolAddress =
                poolAddr (ssbPoolHash scripts) genesisStakingKeyHash
            walletAddress =
                walletAddr genesisPaymentKeyHash
            treasuryAddress =
                stakedWalletAddr genesisPaymentKeyHash genesisStakingKeyHash
            finalPoolValue =
                MaryValue
                    (Coin 1_014_500_000)
                    ( multiAsset
                        [ (sttPolicy token, sttAssetName token, 990_103_912)
                        , (poolPolicy, spuNftName pool, 1)
                        ]
                    )
            walletValue =
                MaryValue
                    (Coin 2_000_000)
                    (singleAsset (sttPolicy token) (sttAssetName token) 9_896_088)
            finalPoolOut =
                inlineDatumTxOut
                    poolAddress
                    finalPoolValue
                    ( poolDatum
                        (spuIdent pool)
                        (policyIdBytes (sttPolicy token))
                        (assetNameRawBytes (sttAssetName token))
                        1_000_000_000
                        4_500_000
                    )
            walletOut =
                mkBasicTxOut walletAddress walletValue
            treasuryOut =
                inlineDatumTxOut
                    treasuryAddress
                    (MaryValue (Coin 2_000_000) mempty)
                    voidData
            rewardAccount =
                AccountAddress
                    Testnet
                    (AccountId (ScriptHashObj (ssbPoolStakeHash scripts)))
            lowerSlot =
                ledgerTipSlot snapshot
            upperSlot =
                addSlots 20 (ledgerTipSlot snapshot)
            prog :: TxBuild NoCtx Void ()
            prog = do
                _ <- spend fuelIn
                collateral fuelIn
                reference (ssuTxIn settings)
                reference (fst (srsPool scriptRefs))
                reference (fst (srsOrder scriptRefs))
                reference (fst (srsPoolStake scriptRefs))
                requiredSignature ownerGuard
                orderIx <-
                    spendScript
                        (souTxIn order)
                        (RawPlutusData orderScoopRedeemer)
                _ <-
                    spendScript
                        (spuTxIn pool)
                        ( RawPlutusData $
                            poolScoopRedeemer (toInteger orderIx)
                        )
                withdrawScript
                    rewardAccount
                    (Coin 0)
                    (RawPlutusData voidData)
                poolIx <- output finalPoolOut
                _ <- output walletOut
                _ <- output treasuryOut
                checkMinUtxo pp poolIx
                validFrom lowerSlot
                validTo upperSlot
        txId <-
            buildSubmitAndWait
                "scoop fresh Sundae order"
                provider
                submitter
                pp
                emptyInterpret
                (evalWith provider)
                [ fuel
                , (souTxIn order, souTxOut order)
                , (spuTxIn pool, spuTxOut pool)
                ]
                ( (ssuTxIn settings, ssuTxOut settings)
                    : [ srsPool scriptRefs
                      , srsOrder scriptRefs
                      , srsPoolStake scriptRefs
                      ]
                )
                genesisAddr
                prog
        orderStillThere <-
            any ((== souTxIn order) . fst)
                <$> queryUTxOs provider (scriptAddr Testnet (ssbOrderHash scripts))
        walletUtxos <- queryUTxOs provider (walletAddr genesisPaymentKeyHash)
        let walletTokenQuantity =
                sum
                    [ assetQuantity
                        (sttPolicy token)
                        (sttAssetName token)
                        (txOutValue txOut)
                    | (_, txOut) <- walletUtxos
                    ]
        orderStillThere `shouldBe` False
        walletTokenQuantity `shouldSatisfy` (>= 9_896_088)
        pure
            ScoopE2EEvidence
                { seeSettingsTxIn = txInToText (ssuTxIn settings)
                , seePoolTxIn = txInToText (spuTxIn pool)
                , seeOrderTxIn = txInToText (souTxIn order)
                , seeScoopTxId = renderTxId txId
                , seeOrderConsumed = not orderStillThere
                , seeWalletTokenQuantity = walletTokenQuantity
                , seeSettingsHash = scriptHashToHex (ssbSettingsHash scripts)
                , seePoolHash = scriptHashToHex (ssbPoolHash scripts)
                , seePoolStakeHash = scriptHashToHex (ssbPoolStakeHash scripts)
                , seeOrderHash = scriptHashToHex (ssbOrderHash scripts)
                , seePoolIdent = hexText (spuIdent pool)
                , seeTestTokenPolicy = policyIdHex (sttPolicy token)
                , seeTestTokenName = assetNameHex (sttAssetName token)
                }

scoopTreasurySwapOrder
    :: Provider IO
    -> Submitter IO
    -> PParams ConwayEra
    -> [(TxIn, TxOut ConwayEra)]
    -> SundaeSettingsUtxo
    -> ScriptHash
    -> Addr
    -> ScoopTestToken
    -> SundaePoolUtxo
    -> SundaeOrderUtxo
    -> SundaeScriptBundle
    -> SundaeReferenceScripts
    -> IO TreasurySwapEvidence
scoopTreasurySwapOrder
    provider
    submitter
    pp
    utxos
    settings
    treasuryHash
    treasuryAddress
    token
    pool
    order
    scripts
    scriptRefs = do
        fuel@(fuelIn, _) <-
            selectLargestAdaUtxo "fresh treasury scoop fee fuel" utxos
        snapshot <- queryLedgerSnapshot provider
        let poolPolicy =
                PolicyID (ssbPoolHash scripts)
            ownerGuard =
                genesisGuardKeyHash
            poolAddress =
                poolAddr (ssbPoolHash scripts) genesisStakingKeyHash
            swapRecipientAddress =
                treasuryAddress
            protocolTreasuryAddress =
                stakedWalletAddr genesisPaymentKeyHash genesisStakingKeyHash
            finalPoolValue =
                MaryValue
                    (Coin 1_014_500_000)
                    ( multiAsset
                        [ (sttPolicy token, sttAssetName token, 990_103_912)
                        , (poolPolicy, spuNftName pool, 1)
                        ]
                    )
            swapValue =
                MaryValue
                    (Coin 2_000_000)
                    (singleAsset (sttPolicy token) (sttAssetName token) 9_896_088)
            finalPoolOut =
                inlineDatumTxOut
                    poolAddress
                    finalPoolValue
                    ( poolDatum
                        (spuIdent pool)
                        (policyIdBytes (sttPolicy token))
                        (assetNameRawBytes (sttAssetName token))
                        1_000_000_000
                        4_500_000
                    )
            swapOut =
                mkBasicTxOut swapRecipientAddress swapValue
            protocolTreasuryOut =
                inlineDatumTxOut
                    protocolTreasuryAddress
                    (MaryValue (Coin 2_000_000) mempty)
                    voidData
            rewardAccount =
                AccountAddress
                    Testnet
                    (AccountId (ScriptHashObj (ssbPoolStakeHash scripts)))
            lowerSlot =
                ledgerTipSlot snapshot
            upperSlot =
                addSlots 20 (ledgerTipSlot snapshot)
            prog :: TxBuild NoCtx Void ()
            prog = do
                _ <- spend fuelIn
                collateral fuelIn
                reference (ssuTxIn settings)
                reference (fst (srsPool scriptRefs))
                reference (fst (srsOrder scriptRefs))
                reference (fst (srsPoolStake scriptRefs))
                requiredSignature ownerGuard
                orderIx <-
                    spendScript
                        (souTxIn order)
                        (RawPlutusData orderScoopRedeemer)
                _ <-
                    spendScript
                        (spuTxIn pool)
                        ( RawPlutusData $
                            poolScoopRedeemer (toInteger orderIx)
                        )
                withdrawScript
                    rewardAccount
                    (Coin 0)
                    (RawPlutusData voidData)
                poolIx <- output finalPoolOut
                _ <- output swapOut
                _ <- output protocolTreasuryOut
                checkMinUtxo pp poolIx
                validFrom lowerSlot
                validTo upperSlot
        txId <-
            buildSubmitAndWait
                "scoop treasury Sundae order"
                provider
                submitter
                pp
                emptyInterpret
                (evalWith provider)
                [ fuel
                , (souTxIn order, souTxOut order)
                , (spuTxIn pool, spuTxOut pool)
                ]
                ( (ssuTxIn settings, ssuTxOut settings)
                    : [ srsPool scriptRefs
                      , srsOrder scriptRefs
                      , srsPoolStake scriptRefs
                      ]
                )
                genesisAddr
                prog
        orderStillThere <-
            any ((== souTxIn order) . fst)
                <$> queryUTxOs provider (scriptAddr Testnet (ssbOrderHash scripts))
        treasuryUtxos <- queryUTxOs provider treasuryAddress
        let treasuryTokenQuantity =
                sum
                    [ assetQuantity
                        (sttPolicy token)
                        (sttAssetName token)
                        (txOutValue txOut)
                    | (_, txOut) <- treasuryUtxos
                    ]
        orderStillThere `shouldBe` False
        treasuryTokenQuantity `shouldSatisfy` (>= 9_896_088)
        pure
            TreasurySwapEvidence
                { tseSettingsTxIn = txInToText (ssuTxIn settings)
                , tsePoolTxIn = txInToText (spuTxIn pool)
                , tseOrderTxIn = txInToText (souTxIn order)
                , tseScoopTxId = renderTxId txId
                , tseOrderConsumed = not orderStillThere
                , tseTreasuryTokenQuantity = treasuryTokenQuantity
                , tseTreasuryAddress = renderAddr treasuryAddress
                , tseTreasuryScriptHash = scriptHashToHex treasuryHash
                , tseSettingsHash = scriptHashToHex (ssbSettingsHash scripts)
                , tsePoolHash = scriptHashToHex (ssbPoolHash scripts)
                , tsePoolStakeHash = scriptHashToHex (ssbPoolStakeHash scripts)
                , tseOrderHash = scriptHashToHex (ssbOrderHash scripts)
                , tsePoolIdent = hexText (spuIdent pool)
                , tseTestTokenPolicy = policyIdHex (sttPolicy token)
                , tseTestTokenName = assetNameHex (sttAssetName token)
                }

emptyInterpret :: InterpretIO NoCtx
emptyInterpret =
    InterpretIO $ \case {}

evalWith
    :: Provider IO
    -> ConwayTx
    -> IO
        ( Map.Map
            (ConwayPlutusPurpose AsIx ConwayEra)
            (Either String ExUnits)
        )
evalWith provider tx =
    fmap
        (Map.map (either (Left . show) Right))
        (evaluateTx provider tx)

requiredSignature :: KeyHash Guard -> TxBuild NoCtx Void ()
requiredSignature keyHash =
    singleton $ ReqSignature keyHash

genesisPaymentKeyHash :: KeyHash Payment
genesisPaymentKeyHash =
    hashKey (VKey (deriveVerKeyDSIGN genesisSignKey))

genesisGuardKeyHash :: KeyHash Guard
genesisGuardKeyHash =
    hashKey (VKey (deriveVerKeyDSIGN genesisSignKey))

genesisStakingKeyHash :: KeyHash Staking
genesisStakingKeyHash =
    hashKey (VKey (deriveVerKeyDSIGN genesisSignKey))

settingsDatum :: BS.ByteString -> Data
settingsDatum owner =
    Constr
        0
        [ signatureMultisig owner
        , walletAddressData owner
        , signatureMultisig owner
        , stakedWalletAddressData owner owner
        , List [I 1, I 10]
        , someData (List [B owner])
        , List [verificationKeyCredentialData owner]
        , I 0
        , I 2_500_000
        , I 5_000_000
        , I 0
        , voidData
        ]

poolDatum
    :: BS.ByteString
    -> BS.ByteString
    -> BS.ByteString
    -> Integer
    -> Integer
    -> Data
poolDatum ident tokenPolicy tokenName circulatingLp protocolFees =
    Constr
        0
        [ B ident
        , List
            [ assetClassData "" ""
            , assetClassData tokenPolicy tokenName
            ]
        , I circulatingLp
        , I 5
        , I 5
        , noneData
        , I 0
        , I protocolFees
        ]

genericOrderDatum :: ScoopTestToken -> Data
genericOrderDatum token =
    Constr
        0
        [ noneData
        , signatureMultisig (keyHashBytes genesisPaymentKeyHash)
        , I 2_500_000
        , Constr
            0
            [ walletAddressData (keyHashBytes genesisPaymentKeyHash)
            , noDatumData
            ]
        , Constr
            1
            [ singletonValueData "" "" 10_000_000
            , singletonValueData
                (policyIdBytes (sttPolicy token))
                (assetNameRawBytes (sttAssetName token))
                0
            ]
        , voidData
        ]

createPoolRedeemer :: BS.ByteString -> BS.ByteString -> Data
createPoolRedeemer tokenPolicy tokenName =
    Constr
        1
        [ List
            [ assetClassData "" ""
            , assetClassData tokenPolicy tokenName
            ]
        , I 0
        , I 2
        ]

poolScoopRedeemer :: Integer -> Data
poolScoopRedeemer orderIndex =
    Constr
        0
        [ I 0
        , I 0
        , List [List [I orderIndex, noneData, I 0]]
        ]

orderScoopRedeemer :: Data
orderScoopRedeemer =
    Constr 0 []

settingsAdminUpdateRedeemer :: Data
settingsAdminUpdateRedeemer =
    Constr 0 []

signatureMultisig :: BS.ByteString -> Data
signatureMultisig owner =
    Constr 0 [B owner]

walletAddressData :: BS.ByteString -> Data
walletAddressData paymentKeyHash =
    Constr
        0
        [ verificationKeyCredentialData paymentKeyHash
        , noneData
        ]

stakedWalletAddressData :: BS.ByteString -> BS.ByteString -> Data
stakedWalletAddressData paymentKeyHash stakeKeyHash =
    Constr
        0
        [ verificationKeyCredentialData paymentKeyHash
        , someData (Constr 0 [verificationKeyCredentialData stakeKeyHash])
        ]

verificationKeyCredentialData :: BS.ByteString -> Data
verificationKeyCredentialData keyHash =
    Constr 0 [B keyHash]

someData :: Data -> Data
someData datum =
    Constr 0 [datum]

noneData :: Data
noneData =
    Constr 1 []

voidData :: Data
voidData =
    Constr 0 []

noDatumData :: Data
noDatumData =
    Constr 0 []

assetClassData :: BS.ByteString -> BS.ByteString -> Data
assetClassData policy name =
    List [B policy, B name]

singletonValueData
    :: BS.ByteString -> BS.ByteString -> Integer -> Data
singletonValueData policy name quantity =
    List [B policy, B name, I quantity]

outputReferenceDataFromTxIn :: TxIn -> Data
outputReferenceDataFromTxIn txIn =
    Constr
        0
        [ B (txInIdBytes txIn)
        , I (toInteger (txInIndex txIn))
        ]

txInIdBytes :: TxIn -> BS.ByteString
txInIdBytes (TxIn (TxId h) _) =
    hashToBytes (extractHash h)

txInIndex :: TxIn -> Int
txInIndex (TxIn _ ix) =
    txIxToInt ix

poolIdentFromTxIn :: TxIn -> BS.ByteString
poolIdentFromTxIn txIn =
    BS.drop 4 $
        hashToBytes $
            hashWith @Blake2b_256 id $
                txInIdBytes txIn
                    <> "#"
                    <> BS.singleton (fromIntegral (txInIndex txIn))

poolRefName :: BS.ByteString -> BS.ByteString
poolRefName ident =
    decodeHexUnsafeLocal "000643b0" <> ident

poolNftName :: BS.ByteString -> BS.ByteString
poolNftName ident =
    decodeHexUnsafeLocal "000de140" <> ident

poolLpName :: BS.ByteString -> BS.ByteString
poolLpName ident =
    decodeHexUnsafeLocal "0014df10" <> ident

inlineDatumTxOut :: Addr -> MaryValue -> Data -> TxOut ConwayEra
inlineDatumTxOut addr value datum =
    mkBasicTxOut addr value
        & datumTxOutL .~ mkInlineDatum @ConwayEra datum

walletAddr :: KeyHash Payment -> Addr
walletAddr payment =
    Addr Testnet (KeyHashObj payment) StakeRefNull

stakedWalletAddr :: KeyHash Payment -> KeyHash Staking -> Addr
stakedWalletAddr payment stake =
    Addr
        Testnet
        (KeyHashObj payment)
        (StakeRefBase (KeyHashObj stake))

stakedScriptAddr :: ScriptHash -> Addr
stakedScriptAddr scriptHash =
    Addr
        Testnet
        (ScriptHashObj scriptHash)
        (StakeRefBase (ScriptHashObj scriptHash))

poolAddr :: ScriptHash -> KeyHash Staking -> Addr
poolAddr poolHash stakeKey =
    Addr
        Testnet
        (ScriptHashObj poolHash)
        (StakeRefBase (KeyHashObj stakeKey))

singleAsset :: PolicyID -> AssetName -> Integer -> MultiAsset
singleAsset policy asset quantity =
    MultiAsset $
        Map.singleton policy $
            Map.singleton asset quantity

multiAsset :: [(PolicyID, AssetName, Integer)] -> MultiAsset
multiAsset assets =
    MultiAsset $
        Map.fromListWith
            (Map.unionWith (+))
            [ (policy, Map.singleton asset quantity)
            | (policy, asset, quantity) <- assets
            ]

assetQuantity :: PolicyID -> AssetName -> MaryValue -> Integer
assetQuantity policy asset (MaryValue _ (MultiAsset assets)) =
    Map.findWithDefault 0 asset $
        Map.findWithDefault Map.empty policy assets

txOutValue :: TxOut ConwayEra -> MaryValue
txOutValue txOut =
    txOut ^. valueTxOutL

policyIdBytes :: PolicyID -> BS.ByteString
policyIdBytes (PolicyID (ScriptHash h)) =
    hashToBytes h

assetNameRawBytes :: AssetName -> BS.ByteString
assetNameRawBytes (AssetName name) =
    SBS.fromShort name

policyIdHex :: PolicyID -> T.Text
policyIdHex =
    hexText . policyIdBytes

assetNameHex :: AssetName -> T.Text
assetNameHex =
    hexText . assetNameRawBytes

hexText :: BS.ByteString -> T.Text
hexText =
    TE.decodeUtf8 . B16.encode

decodeHexUnsafeLocal :: BS.ByteString -> BS.ByteString
decodeHexUnsafeLocal hexBytes =
    case B16.decode hexBytes of
        Right bytes -> bytes
        Left err -> error ("invalid hex fixture: " <> err)

alwaysTrueScript :: Script ConwayEra
alwaysTrueScript =
    let bytes =
            decodeHexUnsafeLocal (BS8.filter (/= '\n') alwaysTrueHex)
        plutus =
            Plutus @PlutusV3
                (PlutusBinary (SBS.toShort bytes))
    in  maybe
            (error "alwaysTrueScript: mkPlutusScript")
            fromPlutusScript
            (mkPlutusScript plutus)

alwaysTrueHex :: BS8.ByteString
alwaysTrueHex =
    "58d501010029800aba2aba1aab9eaab9dab9a48888966002646465\
    \300130053754003300700398038012444b30013370e9000001c4c\
    \9289bae300a3009375400915980099b874800800e2646644944c0\
    \2c004c02cc030004c024dd5002456600266e1d200400389925130\
    \0a3009375400915980099b874801800e2646644944dd698058009\
    \805980600098049baa0048acc004cdc3a40100071324a26014601\
    \26ea80122646644944dd698058009805980600098049baa004401\
    \c8039007200e401c3006300700130060013003375400d149a26ca\
    \c8009"

statusNote :: String -> IO ()
statusNote =
    statusLine "NOTE"

statusMilestone :: String -> IO ()
statusMilestone =
    statusLine "MILESTONE"

statusLine :: String -> String -> IO ()
statusLine label message = do
    now <- getCurrentTime
    appendFile
        "/tmp/devnet-scoop/codex-scoop/STATUS.md"
        ( label
            <> " "
            <> formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" now
            <> " "
            <> message
            <> "\n"
        )

writeGenesisPaymentSigningKey :: FilePath -> IO FilePath
writeGenesisPaymentSigningKey runDir = do
    let path = runDir </> "registry-init-funding.skey"
    BSL.writeFile
        path
        ( encode
            ( object
                [ "type"
                    .= ( "PaymentSigningKeyShelley_ed25519"
                            :: T.Text
                       )
                , "description" .= ("Payment Signing Key" :: T.Text)
                , "cborHex"
                    .= TE.decodeUtf8
                        ( "5820"
                            <> B16.encode
                                ( rawSerialiseSignKeyDSIGN
                                    genesisSignKey
                                )
                        )
                ]
            )
        )
    setFileMode path ownerReadMode
    pure path

buildSubmitAndWait
    :: String
    -> Provider IO
    -> Submitter IO
    -> PParams ConwayEra
    -> InterpretIO NoCtx
    -> ( ConwayTx
         -> IO
                ( Map.Map
                    (ConwayPlutusPurpose AsIx ConwayEra)
                    (Either String ExUnits)
                )
       )
    -> [(TxIn, TxOut ConwayEra)]
    -> [(TxIn, TxOut ConwayEra)]
    -> Addr
    -> TxBuild NoCtx Void ()
    -> IO TxId
buildSubmitAndWait
    label
    provider
    submitter
    pp
    interpret
    eval
    inputs
    refs
    changeAddr
    prog =
        build
            (mkPParamsBound pp)
            interpret
            eval
            inputs
            refs
            changeAddr
            prog
            >>= \case
                Left err ->
                    expectationFailure (label <> ": " <> show err)
                        *> error "unreachable"
                Right tx -> do
                    let signed = addKeyWitness genesisSignKey tx
                        txId = txIdTx signed
                    submitTx submitter signed >>= \case
                        Submitted _ -> pure ()
                        Rejected reason ->
                            expectationFailure $
                                label <> " rejected: " <> show reason
                    waitForTxChange provider txId genesisAddr 60
                    pure txId

submitTreasuryWithdrawal
    :: TreasuryTarget
    -> Provider IO
    -> Submitter IO
    -> PParams ConwayEra
    -> [(TxIn, TxOut ConwayEra)]
    -> IO GovernanceEvidence
submitTreasuryWithdrawal target provider submitter pp utxos = do
    seed@(seedIn, _) <- selectLargestAdaUtxo "governance funding" utxos

    buildSnapshot <- queryLedgerSnapshot provider
    let treasuryHashText =
            ttScriptHashText target
        upperSlot =
            addSlots 20 (ledgerTipSlot buildSnapshot)
        treasuryCredential =
            ScriptHashObj (ttScriptHash target)
        treasuryAccount =
            AccountAddress Testnet (AccountId treasuryCredential)
        returnAccount =
            rewardAccountFromSignKey genesisSignKey
        returnCredential =
            stakeCredentialFromSignKey genesisSignKey
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
        prog = do
            _ <- spend seedIn
            collateral seedIn
            _ <-
                registerAndVoteAbstain
                    returnCredential
                    stakeDeposit
                    PubKeyCert
            _ <-
                registerAndVoteAbstain
                    treasuryCredential
                    stakeDeposit
                    (ScriptCert (RawPlutusData emptyListRedeemer))
            attachScript (ttScript target)
            _ <-
                certify
                    ( ConwayTxCertGov $
                        ConwayRegDRep
                            drepCredential
                            drepDeposit
                            SNothing
                    )
                    PubKeyCert
            _ <-
                certify
                    ( ConwayTxCertDeleg $
                        ConwayRegDelegCert
                            voterCredential
                            (DelegVote (DRepKeyHash drepKey))
                            stakeDeposit
                    )
                    PubKeyCert
            _ <-
                payTo
                    voterBaseAddr
                    (inject voteOutputCoin)
            _ <-
                proposeTreasuryWithdrawal
                    governanceDeposit
                    returnAccount
                    governanceAnchor
                    (Map.singleton treasuryAccount withdrawalAmount)
                    SNothing
                    NoProposalScript
            validTo upperSlot

    rewardBefore <- rewardBalance provider treasuryAccount
    build (mkPParamsBound pp) interpret eval [seed] [] genesisAddr prog
        >>= \case
            Left err ->
                expectationFailure (show err)
                    >> pure
                        ( placeholderEvidence
                            (T.unpack treasuryHashText)
                            rewardBefore
                        )
            Right tx -> do
                let signed =
                        addKeyWitness voterSignKey $
                            addKeyWitness genesisSignKey tx
                    setupTxId =
                        txIdTx signed
                submitTx submitter signed
                    >>= \case
                        Submitted _ -> pure ()
                        Rejected reason ->
                            expectationFailure $
                                "submitTx rejected: "
                                    <> show reason
                waitForTxChange provider setupTxId genesisAddr 60
                setupSnapshot <- queryLedgerSnapshot provider
                governanceState <- queryGovernanceState provider
                governanceState `seq` pure ()
                waitForEpochAfter
                    provider
                    (ledgerEpoch setupSnapshot)
                    60
                voteUtxos <-
                    waitForUtxos provider voterBaseAddr 60
                voteSeed <- case voteUtxos of
                    u : _ -> pure u
                    [] -> fail "voter base UTxO disappeared"
                let actionId =
                        GovActionId setupTxId (GovActionIx 0)
                submitVote
                    provider
                    submitter
                    pp
                    voterBaseAddr
                    voteSeed
                    drepCredential
                    actionId
                voteSnapshot <- queryLedgerSnapshot provider
                rewardAfter <-
                    waitForRewardIncrease
                        provider
                        treasuryAccount
                        (ledgerEpoch voteSnapshot)
                        rewardBefore
                        withdrawalAmount
                        180
                finalSnapshot <- queryLedgerSnapshot provider
                rewardAfter
                    `shouldBe` addCoin
                        rewardBefore
                        withdrawalAmount
                pure $
                    GovernanceEvidence
                        { geTxId = show setupTxId
                        , geActionId = show actionId
                        , geRewardAccount =
                            T.unpack treasuryHashText
                        , geTreasuryScriptHash =
                            T.unpack treasuryHashText
                        , geAmountLovelace =
                            coinLovelace withdrawalAmount
                        , geRewardBefore =
                            coinLovelace rewardBefore
                        , geRewardAfter =
                            coinLovelace rewardAfter
                        , geSetupEpoch =
                            epochNumber (ledgerEpoch setupSnapshot)
                        , geVoteEpoch =
                            epochNumber (ledgerEpoch voteSnapshot)
                        , geFinalEpoch =
                            epochNumber (ledgerEpoch finalSnapshot)
                        }

submitVote
    :: Provider IO
    -> Submitter IO
    -> PParams ConwayEra
    -> Addr
    -> (TxIn, TxOut ConwayEra)
    -> Credential DRepRole
    -> GovActionId
    -> IO ()
submitVote
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
                    expectationFailure (show err)
                Right tx -> do
                    let signed =
                            addKeyWitness voterSignKey tx
                        txId =
                            txIdTx signed
                    submitTx submitter signed
                        >>= \case
                            Submitted _ -> pure ()
                            Rejected reason ->
                                expectationFailure $
                                    "submitVote rejected: "
                                        <> show reason
                    waitForTxChange provider txId voterBaseAddr 60

withGovernanceNode
    :: FilePath
    -> (Provider IO -> Submitter IO -> IO a)
    -> IO a
withGovernanceNode socket action = do
    lsq <- newLSQChannel 16
    ltxs <- newLTxSChannel 16
    withAsync
        (runNodeClient devnetMagic socket lsq ltxs)
        $ \nodeThread -> do
            threadDelay 3_000_000
            poll nodeThread >>= \case
                Just (Left err) ->
                    error $
                        "Node connection failed: "
                            <> show err
                Just (Right (Left err)) ->
                    error $
                        "Node connection error: "
                            <> show err
                Just (Right (Right ())) ->
                    error
                        "Node connection closed unexpectedly"
                Nothing -> pure ()
            action
                (mkN2CProvider lsq)
                (mkN2CSubmitter ltxs)

governanceAnchor :: Anchor
governanceAnchor =
    Anchor
        ( fromJust $
            textToUrl
                128
                "https://example.invalid/amaru-devnet-governance.json"
        )
        (unsafeMakeSafeHash (mkHash32 42))

rewardAccountFromSignKey
    :: SignKeyDSIGN Ed25519DSIGN
    -> AccountAddress
rewardAccountFromSignKey sk =
    AccountAddress
        Testnet
        (AccountId (stakeCredentialFromSignKey sk))

stakeCredentialFromSignKey
    :: SignKeyDSIGN Ed25519DSIGN
    -> Credential Staking
stakeCredentialFromSignKey =
    KeyHashObj . stakeKeyHashFromSignKey

stakeKeyHashFromSignKey
    :: SignKeyDSIGN Ed25519DSIGN
    -> KeyHash Staking
stakeKeyHashFromSignKey =
    hashKey
        . VKey
        . deriveVerKeyDSIGN

drepCredentialFromSignKey
    :: SignKeyDSIGN Ed25519DSIGN
    -> Credential DRepRole
drepCredentialFromSignKey =
    KeyHashObj . drepKeyHashFromSignKey

drepKeyHashFromSignKey
    :: SignKeyDSIGN Ed25519DSIGN
    -> KeyHash DRepRole
drepKeyHashFromSignKey =
    hashKey
        . VKey
        . deriveVerKeyDSIGN

paymentKeyHashFromSignKey
    :: SignKeyDSIGN Ed25519DSIGN
    -> KeyHash Payment
paymentKeyHashFromSignKey =
    hashKey
        . VKey
        . deriveVerKeyDSIGN

baseAddrFromSignKey
    :: SignKeyDSIGN Ed25519DSIGN
    -> Credential Staking
    -> Addr
baseAddrFromSignKey sk stakeCredential =
    Addr
        Testnet
        (KeyHashObj (paymentKeyHashFromSignKey sk))
        (StakeRefBase stakeCredential)

rewardBalance :: Provider IO -> AccountAddress -> IO Coin
rewardBalance provider account =
    Map.findWithDefault (Coin 0) account
        <$> queryRewardAccounts provider (Set.singleton account)

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

waitForTreasury :: Provider IO -> Coin -> Int -> IO Coin
waitForTreasury _ minimumCoin attempts
    | attempts <= 0 =
        expectationFailure
            ( "timed out waiting for treasury >= "
                <> show minimumCoin
            )
            >> pure (Coin 0)
waitForTreasury provider minimumCoin attempts = do
    treasury <- queryTreasury provider
    if treasury >= minimumCoin
        then pure treasury
        else do
            threadDelay 500_000
            waitForTreasury provider minimumCoin (attempts - 1)

waitForUtxos
    :: Provider IO
    -> Addr
    -> Int
    -> IO [(TxIn, TxOut ConwayEra)]
waitForUtxos _ addr attempts
    | attempts <= 0 =
        expectationFailure
            ("timed out waiting for UTxOs at " <> show addr)
            >> pure []
waitForUtxos provider addr attempts = do
    utxos <- queryUTxOs provider addr
    if null utxos
        then do
            threadDelay 500_000
            waitForUtxos provider addr (attempts - 1)
        else pure utxos

waitForTxChange :: Provider IO -> TxId -> Addr -> Int -> IO ()
waitForTxChange _ txId _ attempts
    | attempts <= 0 =
        expectationFailure $
            "timed out waiting for tx change output: " <> show txId
waitForTxChange provider txId addr attempts = do
    utxos <- queryUTxOs provider addr
    if any (hasTxId txId . fst) utxos
        then pure ()
        else do
            threadDelay 500_000
            waitForTxChange provider txId addr (attempts - 1)

waitForEpochAfter :: Provider IO -> EpochNo -> Int -> IO ()
waitForEpochAfter _ epoch attempts
    | attempts <= 0 =
        expectationFailure
            ("timed out waiting for epoch after " <> show epoch)
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
    -> IO Coin
waitForRewardIncrease _ account _ _ expected attempts
    | attempts <= 0 =
        expectationFailure
            ( "timed out waiting for treasury withdrawal at "
                <> show account
                <> " to increase by "
                <> show expected
            )
            >> pure (Coin 0)
waitForRewardIncrease
    provider
    account
    submittedEpoch
    before
    expected
    attempts = do
        snapshot <- queryLedgerSnapshot provider
        after <- rewardBalance provider account
        if epochNumber (ledgerEpoch snapshot)
            > epochNumber submittedEpoch
            && after == addCoin before expected
            then pure after
            else do
                threadDelay 500_000
                waitForRewardIncrease
                    provider
                    account
                    submittedEpoch
                    before
                    expected
                    (attempts - 1)

copyGovernanceGenesis :: FilePath -> FilePath -> IO ()
copyGovernanceGenesis source target = do
    createDirectoryIfMissing True target
    createDirectoryIfMissing True (target </> "delegate-keys")
    traverse_
        copyGenesisFile
        [ "alonzo-genesis.json"
        , "byron-genesis.json"
        , "conway-genesis.json"
        , "dijkstra-genesis.json"
        , "node-config.json"
        , "shelley-genesis.json"
        , "topology.json"
        ]
    traverse_
        copyDelegateKey
        [ "delegate1.kes.skey"
        , "delegate1.opcert"
        , "delegate1.vrf.skey"
        ]
  where
    copyGenesisFile name =
        BS.readFile (source </> name)
            >>= BS.writeFile (target </> name)
    copyDelegateKey name = do
        let targetKey = target </> "delegate-keys" </> name
        BS.readFile (source </> "delegate-keys" </> name)
            >>= BS.writeFile targetKey
        setFileMode targetKey ownerReadMode

patchGovernanceGenesis :: FilePath -> IO ()
patchGovernanceGenesis dir = do
    patchFile
        (dir </> "shelley-genesis.json")
        [ ("\"epochLength\": 500", "\"epochLength\": 50")
        ,
            ( "\"maxLovelaceSupply\": 30000000000000000"
            , "\"maxLovelaceSupply\": 60000000000000000"
            )
        ]
    patchFile
        (dir </> "conway-genesis.json")
        [ ("\"treasuryWithdrawal\": 0.67", "\"treasuryWithdrawal\": 0.0")
        , ("\"committeeMinSize\": 7", "\"committeeMinSize\": 0")
        ,
            ( "\"committee\": {\n    \"members\": {\n    },\n    \"threshold\": 0.67\n  }"
            , "\"committee\": {\n    \"members\": {\n      \"keyHash-4e88cc2d27c364aaf90648a87dfb95f8ee103ba67fa1f12f5e86c42a\": 100000\n    },\n    \"threshold\": 0.0\n  }"
            )
        ,
            ( "\"dRepDeposit\": 500000000"
            , "\"dRepDeposit\": 500000"
            )
        ,
            ( "\"govActionDeposit\": 50000000000"
            , "\"govActionDeposit\": 1000000"
            )
        ]

patchFile :: FilePath -> [(BS.ByteString, BS.ByteString)] -> IO ()
patchFile path replacements = do
    content <- BS.readFile path
    BS.writeFile path $
        foldl'
            ( \bytes (needle, replacement) ->
                replaceRequired needle replacement bytes
            )
            content
            replacements

replaceRequired
    :: BS.ByteString
    -> BS.ByteString
    -> BS.ByteString
    -> BS.ByteString
replaceRequired needle replacement content =
    let (before, after) =
            BS.breakSubstring needle content
    in  if BS.null after
            then
                error $
                    "governance smoke genesis patch did not find "
                        <> BS8.unpack needle
            else
                before
                    <> replacement
                    <> BS.drop (BS.length needle) after

scriptFromBlob :: BS.ByteString -> IO (Script ConwayEra)
scriptFromBlob blob =
    case mkPlutusScript plutus of
        Just script -> pure (fromPlutusScript script)
        Nothing ->
            expectationFailure "failed to build Plutus script"
                *> error "unreachable"
  where
    plutus =
        Plutus @PlutusV3 (PlutusBinary (SBS.toShort blob))

refScriptTxOut :: Addr -> Script ConwayEra -> TxOut ConwayEra
refScriptTxOut addr script =
    mkBasicTxOut
        addr
        (MaryValue devnetReferenceScriptCoin (MultiAsset Map.empty))
        & referenceScriptTxOutL .~ SJust script

scriptAddr :: Network -> ScriptHash -> Addr
scriptAddr network scriptHash =
    Addr
        network
        (ScriptHashObj scriptHash)
        (StakeRefBase (ScriptHashObj scriptHash))

scriptHashBytes :: ScriptHash -> BS.ByteString
scriptHashBytes (ScriptHash h) =
    hashToBytes h

keyHashBytes :: KeyHash kr -> BS.ByteString
keyHashBytes (KeyHash h) =
    hashToBytes h

txOutRef :: TxId -> Integer -> TxIn
txOutRef txId ix =
    TxIn txId (mkTxIxPartial ix)

waitForTxIns
    :: Provider IO
    -> [TxIn]
    -> Int
    -> IO [(TxIn, TxOut ConwayEra)]
waitForTxIns _ refs attempts
    | attempts <= 0 =
        expectationFailure
            ( "timed out waiting for UTxOs: "
                <> show (txInToText <$> refs)
            )
            >> pure []
waitForTxIns provider refs attempts = do
    found <- queryUTxOByTxIn provider (Set.fromList refs)
    if all (`Map.member` found) refs
        then
            pure
                [ (ref, found Map.! ref)
                | ref <- refs
                ]
        else do
            threadDelay 500_000
            waitForTxIns provider refs (attempts - 1)

writeGovernanceArtifacts
    :: FilePath
    -> FilePath
    -> ShelleyGenesisTiming
    -> GovernanceEvidence
    -> IO ()
writeGovernanceArtifacts runDir socket timing evidence = do
    let govDir = runDir </> "governance"
        summary = governanceSummaryValue runDir socket timing evidence
    BSL.writeFile
        (govDir </> "certificates.json")
        ( encode $
            object
                [ "treasuryScriptHash"
                    .= geTreasuryScriptHash evidence
                , "stakeDepositLovelace"
                    .= coinLovelace stakeDeposit
                , "drepDepositLovelace"
                    .= coinLovelace drepDeposit
                , "voteDelegation"
                    .= ("always-abstain" :: String)
                ]
        )
    BSL.writeFile
        (govDir </> "action.json")
        ( encode $
            object
                [ "txId" .= geTxId evidence
                , "governanceActionId" .= geActionId evidence
                , "rewardAccount" .= geRewardAccount evidence
                , "amountLovelace" .= geAmountLovelace evidence
                ]
        )
    BSL.writeFile (govDir </> "summary.json") (encode summary)
    BSL.writeFile (runDir </> "summary.json") (encode summary)
    writeFile
        (runDir </> "summary.log")
        (unlines (governanceSummaryLines runDir socket timing evidence))

governanceSummaryValue
    :: FilePath
    -> FilePath
    -> ShelleyGenesisTiming
    -> GovernanceEvidence
    -> Value
governanceSummaryValue runDir socket timing evidence =
    object
        [ "phase" .= ("governance" :: String)
        , "status" .= ("passed" :: String)
        , "runDirectory" .= runDir
        , "socket" .= socket
        , "network" .= ("devnet" :: String)
        , "networkMagic" .= sgtNetworkMagic timing
        , "epochDurationSeconds" .= epochDurationSeconds timing
        , "txId" .= geTxId evidence
        , "governanceActionId" .= geActionId evidence
        , "rewardAccount" .= geRewardAccount evidence
        , "treasuryScriptHash" .= geTreasuryScriptHash evidence
        , "amountLovelace" .= geAmountLovelace evidence
        , "rewardBeforeLovelace" .= geRewardBefore evidence
        , "rewardAfterLovelace" .= geRewardAfter evidence
        , "setupEpoch" .= geSetupEpoch evidence
        , "voteEpoch" .= geVoteEpoch evidence
        , "finalEpoch" .= geFinalEpoch evidence
        ]

putGovernanceSummaryLines
    :: FilePath
    -> FilePath
    -> ShelleyGenesisTiming
    -> GovernanceEvidence
    -> IO ()
putGovernanceSummaryLines runDir socket timing evidence =
    mapM_ putStrLn $
        governanceSummaryLines runDir socket timing evidence

governanceSummaryLines
    :: FilePath
    -> FilePath
    -> ShelleyGenesisTiming
    -> GovernanceEvidence
    -> [String]
governanceSummaryLines runDir socket timing evidence =
    [ "devnet-smoke: run-dir " <> runDir
    , "devnet-smoke: network devnet magic "
        <> show (sgtNetworkMagic timing)
    , "devnet-smoke: epoch-duration "
        <> show (epochDurationSeconds timing)
    , "devnet-smoke: socket " <> socket
    , "devnet-smoke: phase governance passed"
    , "devnet-smoke: governance-tx-id " <> geTxId evidence
    , "devnet-smoke: governance-action-id " <> geActionId evidence
    , "devnet-smoke: reward-account " <> geRewardAccount evidence
    , "devnet-smoke: governance-amount "
        <> show (geAmountLovelace evidence)
    , "devnet-smoke: governance-summary "
        <> (runDir </> "governance" </> "summary.json")
    ]

writeSwapReadinessArtifacts
    :: FilePath
    -> FilePath
    -> ShelleyGenesisTiming
    -> SwapReadinessEvidence
    -> IO ()
writeSwapReadinessArtifacts runDir socket timing evidence = do
    let swapDir =
            runDir </> "swap-ready"
        registry =
            swapReadinessRegistryValue runDir socket timing evidence
        summary =
            swapReadinessSummaryValue runDir socket timing evidence
        provenance =
            swapReadinessProvenanceValue runDir evidence
    createDirectoryIfMissing True swapDir
    BSL.writeFile (swapReadinessRegistryPath runDir) (encode registry)
    BSL.writeFile (swapReadinessSummaryPath runDir) (encode summary)
    BSL.writeFile (swapReadinessProvenancePath runDir) (encode provenance)
    BSL.writeFile (runDir </> "summary.json") (encode summary)
    writeFile
        (runDir </> "summary.log")
        (unlines (swapReadinessLines runDir evidence))

swapReadinessRegistryValue
    :: FilePath
    -> FilePath
    -> ShelleyGenesisTiming
    -> SwapReadinessEvidence
    -> Value
swapReadinessRegistryValue runDir socket timing evidence =
    object
        [ "schemaVersion" .= (1 :: Int)
        , "phase" .= ("swap-ready" :: String)
        , "status" .= ("passed" :: String)
        , "runDirectory" .= runDir
        , "socket" .= socket
        , "network" .= ("devnet" :: String)
        , "networkMagic" .= sgtNetworkMagic timing
        , "epochDurationSeconds" .= epochDurationSeconds timing
        , "orderValidator"
            .= object
                [ "sourceRepository"
                    .= sreOrderValidatorSourceRepository evidence
                , "sourceCommit"
                    .= sreOrderValidatorSourceCommit evidence
                , "validatorTitle" .= sreOrderValidatorTitle evidence
                , "scriptHash" .= sreOrderValidatorScriptHash evidence
                , "fixtureOnly" .= False
                ]
        , "orderReference"
            .= object
                [ "referenceTxIn" .= sreOrderReferenceTxIn evidence
                , "address" .= sreOrderAddress evidence
                , "scriptHash" .= sreOrderValidatorScriptHash evidence
                ]
        , "orderBuildInputs"
            .= object
                [ "swapOrderAddress" .= sreOrderAddress evidence
                , "orderScriptRef" .= sreOrderReferenceTxIn evidence
                ]
        , "registryPath" .= swapReadinessRegistryPath runDir
        , "summaryPath" .= swapReadinessSummaryPath runDir
        , "provenancePath" .= swapReadinessProvenancePath runDir
        ]

swapReadinessSummaryValue
    :: FilePath
    -> FilePath
    -> ShelleyGenesisTiming
    -> SwapReadinessEvidence
    -> Value
swapReadinessSummaryValue runDir socket timing evidence =
    object
        [ "schemaVersion" .= (1 :: Int)
        , "phase" .= ("swap-ready" :: String)
        , "status" .= ("passed" :: String)
        , "runDirectory" .= runDir
        , "socket" .= socket
        , "network" .= ("devnet" :: String)
        , "networkMagic" .= sgtNetworkMagic timing
        , "epochDurationSeconds" .= epochDurationSeconds timing
        , "orderValidatorSourceRepository"
            .= sreOrderValidatorSourceRepository evidence
        , "orderValidatorSourceCommit"
            .= sreOrderValidatorSourceCommit evidence
        , "orderValidatorTitle" .= sreOrderValidatorTitle evidence
        , "orderValidatorScriptHash"
            .= sreOrderValidatorScriptHash evidence
        , "orderReferenceTxIn" .= sreOrderReferenceTxIn evidence
        , "orderAddress" .= sreOrderAddress evidence
        , "registryPath" .= swapReadinessRegistryPath runDir
        , "provenancePath" .= swapReadinessProvenancePath runDir
        ]

swapReadinessProvenanceValue
    :: FilePath
    -> SwapReadinessEvidence
    -> Value
swapReadinessProvenanceValue runDir evidence =
    object
        [ "sourceRepository"
            .= sreOrderValidatorSourceRepository evidence
        , "sourceCommit" .= sreOrderValidatorSourceCommit evidence
        , "validatorTitle" .= sreOrderValidatorTitle evidence
        , "checkedInArtifactPath"
            .= ("assets/plutus/sundae_order.cbor" :: String)
        , "scriptHash" .= sreOrderValidatorScriptHash evidence
        , "referenceTxIn" .= sreOrderReferenceTxIn evidence
        , "registryPath" .= swapReadinessRegistryPath runDir
        , "fixtureOnly" .= False
        ]

putSwapReadinessLines :: FilePath -> SwapReadinessEvidence -> IO ()
putSwapReadinessLines runDir evidence =
    mapM_ putStrLn (swapReadinessLines runDir evidence)

swapReadinessLines :: FilePath -> SwapReadinessEvidence -> [String]
swapReadinessLines runDir evidence =
    [ "devnet-smoke: run-dir " <> runDir
    , "devnet-smoke: phase swap-ready passed"
    , "devnet-smoke: swap-ready-order-script-hash "
        <> T.unpack (sreOrderValidatorScriptHash evidence)
    , "devnet-smoke: swap-ready-order-script-ref "
        <> T.unpack (sreOrderReferenceTxIn evidence)
    , "devnet-smoke: swap-ready-order-address "
        <> T.unpack (sreOrderAddress evidence)
    , "devnet-smoke: swap-ready-registry "
        <> swapReadinessRegistryPath runDir
    ]

writeScoopM2Artifacts
    :: FilePath
    -> FilePath
    -> ShelleyGenesisTiming
    -> SwapReadinessEvidence
    -> ScoopM2OrderEvidence
    -> IO ()
writeScoopM2Artifacts runDir socket timing readiness evidence = do
    let scoopDir =
            runDir </> "scoop-m2"
        orderPath =
            scoopDir </> "order.json"
        summary =
            object
                [ "schemaVersion" .= (1 :: Int)
                , "phase" .= ("scoop-m2" :: String)
                , "status" .= ("passed" :: String)
                , "runDirectory" .= runDir
                , "socket" .= socket
                , "network" .= ("devnet" :: String)
                , "networkMagic" .= sgtNetworkMagic timing
                , "epochDurationSeconds" .= epochDurationSeconds timing
                , "orderValidatorScriptHash"
                    .= sreOrderValidatorScriptHash readiness
                , "orderReferenceTxIn"
                    .= sreOrderReferenceTxIn readiness
                , "orderAddress" .= smeOrderAddress evidence
                , "orderTxId" .= smeOrderTxId evidence
                , "orderTxIn" .= smeOrderTxIn evidence
                , "poolIdent" .= smePoolIdent evidence
                , "offerLovelace" .= smeOfferLovelace evidence
                , "minReceived" .= smeMinReceived evidence
                , "scooperFeeLovelace"
                    .= smeScooperFeeLovelace evidence
                , "lockedLovelace" .= smeLockedLovelace evidence
                , "ownerKeyHash" .= smeOwnerKeyHash evidence
                , "destinationScriptHash"
                    .= smeDestinationScriptHash evidence
                , "orderPath" .= orderPath
                ]
    createDirectoryIfMissing True scoopDir
    BSL.writeFile (scoopDir </> "order.json") (encode summary)
    BSL.writeFile (scoopDir </> "summary.json") (encode summary)
    BSL.writeFile (runDir </> "summary.json") (encode summary)
    writeFile
        (runDir </> "summary.log")
        (unlines (scoopM2Lines runDir evidence))

putScoopM2Lines :: FilePath -> ScoopM2OrderEvidence -> IO ()
putScoopM2Lines runDir evidence =
    mapM_ putStrLn (scoopM2Lines runDir evidence)

scoopM2Lines :: FilePath -> ScoopM2OrderEvidence -> [String]
scoopM2Lines runDir evidence =
    [ "devnet-smoke: run-dir " <> runDir
    , "devnet-smoke: phase scoop-m2 passed"
    , "devnet-smoke: scoop-m2-order-tx-id "
        <> T.unpack (smeOrderTxId evidence)
    , "devnet-smoke: scoop-m2-order-tx-in "
        <> T.unpack (smeOrderTxIn evidence)
    , "devnet-smoke: scoop-m2-order-address "
        <> T.unpack (smeOrderAddress evidence)
    , "devnet-smoke: scoop-m2-pool-ident "
        <> T.unpack (smePoolIdent evidence)
    , "devnet-smoke: scoop-m2-order "
        <> (runDir </> "scoop-m2" </> "order.json")
    ]

writeScoopE2EArtifacts
    :: FilePath
    -> FilePath
    -> ShelleyGenesisTiming
    -> ScoopE2EEvidence
    -> IO ()
writeScoopE2EArtifacts runDir socket timing evidence = do
    let scoopDir =
            runDir </> "scoop-e2e"
        summaryPath =
            scoopDir </> "summary.json"
        summary =
            object
                [ "schemaVersion" .= (1 :: Int)
                , "phase" .= ("scoop-e2e" :: String)
                , "status" .= ("passed" :: String)
                , "runDirectory" .= runDir
                , "socket" .= socket
                , "network" .= ("devnet" :: String)
                , "networkMagic" .= sgtNetworkMagic timing
                , "epochDurationSeconds" .= epochDurationSeconds timing
                , "settingsTxIn" .= seeSettingsTxIn evidence
                , "poolTxIn" .= seePoolTxIn evidence
                , "orderTxIn" .= seeOrderTxIn evidence
                , "scoopTxId" .= seeScoopTxId evidence
                , "orderConsumed" .= seeOrderConsumed evidence
                , "walletTokenQuantity"
                    .= seeWalletTokenQuantity evidence
                , "settingsScriptHash" .= seeSettingsHash evidence
                , "poolScriptHash" .= seePoolHash evidence
                , "poolStakeScriptHash" .= seePoolStakeHash evidence
                , "orderScriptHash" .= seeOrderHash evidence
                , "poolIdent" .= seePoolIdent evidence
                , "testTokenPolicy" .= seeTestTokenPolicy evidence
                , "testTokenName" .= seeTestTokenName evidence
                , "summaryPath" .= summaryPath
                ]
    createDirectoryIfMissing True scoopDir
    BSL.writeFile summaryPath (encode summary)
    BSL.writeFile (runDir </> "summary.json") (encode summary)
    writeFile
        (runDir </> "summary.log")
        (unlines (scoopE2ELines runDir evidence))

putScoopE2ELines :: FilePath -> ScoopE2EEvidence -> IO ()
putScoopE2ELines runDir evidence =
    mapM_ putStrLn (scoopE2ELines runDir evidence)

scoopE2ELines :: FilePath -> ScoopE2EEvidence -> [String]
scoopE2ELines runDir evidence =
    [ "devnet-smoke: run-dir " <> runDir
    , "devnet-smoke: phase scoop-e2e passed"
    , "devnet-smoke: scoop-e2e-settings-tx-in "
        <> T.unpack (seeSettingsTxIn evidence)
    , "devnet-smoke: scoop-e2e-pool-tx-in "
        <> T.unpack (seePoolTxIn evidence)
    , "devnet-smoke: scoop-e2e-order-tx-in "
        <> T.unpack (seeOrderTxIn evidence)
    , "devnet-smoke: scoop-e2e-scoop-tx-id "
        <> T.unpack (seeScoopTxId evidence)
    , "devnet-smoke: scoop-e2e-order-consumed "
        <> show (seeOrderConsumed evidence)
    , "devnet-smoke: scoop-e2e-wallet-token-quantity "
        <> show (seeWalletTokenQuantity evidence)
    , "devnet-smoke: scoop-e2e-summary "
        <> (runDir </> "scoop-e2e" </> "summary.json")
    ]

writeTreasurySwapArtifacts
    :: FilePath
    -> FilePath
    -> ShelleyGenesisTiming
    -> TreasurySwapEvidence
    -> IO ()
writeTreasurySwapArtifacts runDir socket timing evidence = do
    let phaseDir =
            runDir </> "treasury-swap-e2e"
        summaryPath =
            phaseDir </> "summary.json"
        summary =
            object
                [ "schemaVersion" .= (1 :: Int)
                , "phase" .= ("treasury-swap-e2e" :: String)
                , "status" .= ("passed" :: String)
                , "runDirectory" .= runDir
                , "socket" .= socket
                , "network" .= ("devnet" :: String)
                , "networkMagic" .= sgtNetworkMagic timing
                , "epochDurationSeconds" .= epochDurationSeconds timing
                , "settingsTxIn" .= tseSettingsTxIn evidence
                , "poolTxIn" .= tsePoolTxIn evidence
                , "orderTxIn" .= tseOrderTxIn evidence
                , "scoopTxId" .= tseScoopTxId evidence
                , "orderConsumed" .= tseOrderConsumed evidence
                , "treasuryTokenQuantity"
                    .= tseTreasuryTokenQuantity evidence
                , "treasuryAddress" .= tseTreasuryAddress evidence
                , "treasuryScriptHash" .= tseTreasuryScriptHash evidence
                , "settingsScriptHash" .= tseSettingsHash evidence
                , "poolScriptHash" .= tsePoolHash evidence
                , "poolStakeScriptHash" .= tsePoolStakeHash evidence
                , "orderScriptHash" .= tseOrderHash evidence
                , "poolIdent" .= tsePoolIdent evidence
                , "testTokenPolicy" .= tseTestTokenPolicy evidence
                , "testTokenName" .= tseTestTokenName evidence
                , "summaryPath" .= summaryPath
                ]
    createDirectoryIfMissing True phaseDir
    BSL.writeFile summaryPath (encode summary)
    BSL.writeFile (runDir </> "summary.json") (encode summary)
    writeFile
        (runDir </> "summary.log")
        (unlines (treasurySwapLines runDir evidence))

putTreasurySwapLines :: FilePath -> TreasurySwapEvidence -> IO ()
putTreasurySwapLines runDir evidence =
    mapM_ putStrLn (treasurySwapLines runDir evidence)

treasurySwapLines :: FilePath -> TreasurySwapEvidence -> [String]
treasurySwapLines runDir evidence =
    [ "devnet-smoke: run-dir " <> runDir
    , "devnet-smoke: phase treasury-swap-e2e passed"
    , "devnet-smoke: treasury-swap-e2e-settings-tx-in "
        <> T.unpack (tseSettingsTxIn evidence)
    , "devnet-smoke: treasury-swap-e2e-pool-tx-in "
        <> T.unpack (tsePoolTxIn evidence)
    , "devnet-smoke: treasury-swap-e2e-order-tx-in "
        <> T.unpack (tseOrderTxIn evidence)
    , "devnet-smoke: treasury-swap-e2e-scoop-tx-id "
        <> T.unpack (tseScoopTxId evidence)
    , "devnet-smoke: treasury-swap-e2e-order-consumed "
        <> show (tseOrderConsumed evidence)
    , "devnet-smoke: treasury-swap-e2e-token-quantity "
        <> show (tseTreasuryTokenQuantity evidence)
    , "devnet-smoke: treasury-swap-e2e-treasury-address "
        <> T.unpack (tseTreasuryAddress evidence)
    , "devnet-smoke: treasury-swap-e2e-treasury-script-hash "
        <> T.unpack (tseTreasuryScriptHash evidence)
    , "devnet-smoke: treasury-swap-e2e-summary "
        <> (runDir </> "treasury-swap-e2e" </> "summary.json")
    ]

withdrawalResolverFailure
    :: Withdraw.WithdrawResolverError
    -> Coin
    -> Maybe Word64
    -> Maybe Word64
    -> WithdrawalFailure
withdrawalResolverFailure err rewards epoch tipSlot =
    case err of
        Withdraw.WithdrawResolverNetworkMismatch expected observed ->
            WithdrawalNetworkMismatch expected observed rewards epoch tipSlot
        _ ->
            WithdrawalResolverFailed err rewards epoch tipSlot

writeWithdrawalFailure
    :: FilePath
    -> FilePath
    -> ShelleyGenesisTiming
    -> Maybe GovernanceEvidence
    -> WithdrawalFailure
    -> IO String
writeWithdrawalFailure runDir socket timing evidence failure = do
    let withdrawDir = runDir </> "withdraw"
        value =
            withdrawalFailureValue
                runDir
                socket
                timing
                evidence
                failure
        message = withdrawalFailureMessage failure
        linesOut = withdrawalFailureLines runDir failure
    createDirectoryIfMissing True withdrawDir
    when (withdrawalFailureRemovesIntent failure) $
        removeIfExists (withdrawIntentPath runDir)
    removeIfExists (withdrawTxBodyPath runDir)
    removeIfExists (withdrawReportMarkdownPath runDir)
    removeIfExists (withdrawSignedTxPath runDir)
    removeIfExists (withdrawSubmitLogPath runDir)
    removeIfExists (withdrawMaterializationPath runDir)
    unless (withdrawalFailurePreservesTxBuildArtifacts failure) $ do
        removeIfExists (withdrawReportJsonPath runDir)
        removeIfExists (withdrawTxBuildLogPath runDir)
    BSL.writeFile (withdrawDir </> "failure.json") (encode value)
    BSL.writeFile (withdrawDir </> "summary.json") (encode value)
    BSL.writeFile (runDir </> "summary.json") (encode value)
    writeFile (runDir </> "summary.log") (unlines linesOut)
    mapM_ putStrLn linesOut
    pure message

withdrawalFailureValue
    :: FilePath
    -> FilePath
    -> ShelleyGenesisTiming
    -> Maybe GovernanceEvidence
    -> WithdrawalFailure
    -> Value
withdrawalFailureValue runDir socket timing evidence failure =
    object
        [ "phase" .= ("withdraw" :: String)
        , "status" .= ("failed" :: String)
        , "code" .= withdrawalFailureCode failure
        , "message" .= withdrawalFailureMessage failure
        , "runDirectory" .= runDir
        , "socket" .= socket
        , "network" .= ("devnet" :: String)
        , "networkMagic" .= sgtNetworkMagic timing
        , "epochDurationSeconds" .= epochDurationSeconds timing
        , "rewardAccount" .= withdrawalFailureRewardAccount evidence failure
        , "rewardBeforeLovelace" .= fmap geRewardBefore evidence
        , "rewardAfterGovernanceLovelace" .= fmap geRewardAfter evidence
        , "lastObservedRewardLovelace"
            .= withdrawalFailureLastObservedReward failure
        , "epoch" .= withdrawalFailureEpoch failure
        , "tipSlot" .= withdrawalFailureTipSlot failure
        , "governancePrerequisitePath"
            .= (runDir </> "withdraw" </> "governance-prerequisite.json")
        , "intentPath" .= withdrawIntentPath runDir
        , "txBodyPath" .= withdrawTxBodyPath runDir
        , "reportJsonPath" .= withdrawReportJsonPath runDir
        , "reportMarkdownPath" .= withdrawReportMarkdownPath runDir
        , "txBuildLogPath" .= withdrawTxBuildLogPath runDir
        , "upstreamCardanoNodeClientsMain"
            .= upstreamCardanoNodeClientsMain
        , "txBuildExitCode" .= withdrawalFailureTxBuildExitCode failure
        , "txBuildFailureCode" .= withdrawalFailureTxBuildCode failure
        , "txBuildFailureMessage" .= withdrawalFailureTxBuildMessage failure
        ]

withdrawalFailureLines :: FilePath -> WithdrawalFailure -> [String]
withdrawalFailureLines runDir failure =
    [ "devnet-smoke: run-dir " <> runDir
    , "devnet-smoke: phase withdraw failed"
    , "devnet-smoke: "
        <> withdrawalFailureCode failure
        <> ": "
        <> withdrawalFailureMessage failure
    , "devnet-smoke: failure "
        <> (runDir </> "withdraw" </> "failure.json")
    ]

withdrawalFailureCode :: WithdrawalFailure -> String
withdrawalFailureCode = \case
    WithdrawalRewardTimeout{} -> "reward-timeout"
    WithdrawalZeroRewards{} -> "zero-rewards"
    WithdrawalNetworkMismatch{} -> "network-mismatch"
    WithdrawalResolverFailed{} -> "resolver-failed"
    WithdrawalIntentFailed{} -> "intent-failed"
    WithdrawalTxBuildFailed{} -> "tx-build-failed"

withdrawalFailureMessage :: WithdrawalFailure -> String
withdrawalFailureMessage = \case
    WithdrawalRewardTimeout account _ _ _ ->
        "timed out waiting for reward account "
            <> account
            <> " to become positive"
    WithdrawalZeroRewards account _ _ _ ->
        "reward account " <> account <> " has zero rewards"
    WithdrawalNetworkMismatch expected observed _ _ _ ->
        "withdraw intent network "
            <> T.unpack expected
            <> " does not match observed "
            <> T.unpack observed
    WithdrawalResolverFailed err _ _ _ ->
        "withdraw resolver failed: " <> show err
    WithdrawalIntentFailed err _ _ _ ->
        "withdraw intent translation failed: " <> show err
    WithdrawalTxBuildFailed exitCode maybeFailure ->
        "tx-build exited with "
            <> show exitCode
            <> maybe
                ""
                ( \failure ->
                    ": "
                        <> T.unpack (Report.bfCode failure)
                        <> ": "
                        <> T.unpack (Report.bfMessage failure)
                )
                maybeFailure

withdrawalFailureRewardAccount
    :: Maybe GovernanceEvidence -> WithdrawalFailure -> Maybe String
withdrawalFailureRewardAccount evidence = \case
    WithdrawalRewardTimeout account _ _ _ -> Just account
    WithdrawalZeroRewards account _ _ _ -> Just account
    WithdrawalNetworkMismatch{} -> geRewardAccount <$> evidence
    WithdrawalResolverFailed{} -> geRewardAccount <$> evidence
    WithdrawalIntentFailed{} -> geRewardAccount <$> evidence
    WithdrawalTxBuildFailed{} -> geRewardAccount <$> evidence

withdrawalFailureLastObservedReward
    :: WithdrawalFailure -> Maybe Integer
withdrawalFailureLastObservedReward = \case
    WithdrawalRewardTimeout _ reward _ _ -> Just (coinLovelace reward)
    WithdrawalZeroRewards _ reward _ _ -> Just (coinLovelace reward)
    WithdrawalNetworkMismatch _ _ reward _ _ -> Just (coinLovelace reward)
    WithdrawalResolverFailed _ reward _ _ -> Just (coinLovelace reward)
    WithdrawalIntentFailed _ reward _ _ -> Just (coinLovelace reward)
    WithdrawalTxBuildFailed{} -> Nothing

withdrawalFailureEpoch :: WithdrawalFailure -> Maybe Word64
withdrawalFailureEpoch = \case
    WithdrawalRewardTimeout _ _ epoch _ -> epoch
    WithdrawalZeroRewards _ _ epoch _ -> epoch
    WithdrawalNetworkMismatch _ _ _ epoch _ -> epoch
    WithdrawalResolverFailed _ _ epoch _ -> epoch
    WithdrawalIntentFailed _ _ epoch _ -> epoch
    WithdrawalTxBuildFailed{} -> Nothing

withdrawalFailureTipSlot :: WithdrawalFailure -> Maybe Word64
withdrawalFailureTipSlot = \case
    WithdrawalRewardTimeout _ _ _ tipSlot -> tipSlot
    WithdrawalZeroRewards _ _ _ tipSlot -> tipSlot
    WithdrawalNetworkMismatch _ _ _ _ tipSlot -> tipSlot
    WithdrawalResolverFailed _ _ _ tipSlot -> tipSlot
    WithdrawalIntentFailed _ _ _ tipSlot -> tipSlot
    WithdrawalTxBuildFailed{} -> Nothing

withdrawalFailureTxBuildExitCode :: WithdrawalFailure -> Maybe Int
withdrawalFailureTxBuildExitCode = \case
    WithdrawalTxBuildFailed ExitSuccess _ -> Just 0
    WithdrawalTxBuildFailed (ExitFailure n) _ -> Just n
    _ -> Nothing

withdrawalFailureTxBuildCode :: WithdrawalFailure -> Maybe T.Text
withdrawalFailureTxBuildCode = \case
    WithdrawalTxBuildFailed _ (Just failure) ->
        Just (Report.bfCode failure)
    _ -> Nothing

withdrawalFailureTxBuildMessage :: WithdrawalFailure -> Maybe T.Text
withdrawalFailureTxBuildMessage = \case
    WithdrawalTxBuildFailed _ (Just failure) ->
        Just (Report.bfMessage failure)
    _ -> Nothing

withdrawalFailureRemovesIntent :: WithdrawalFailure -> Bool
withdrawalFailureRemovesIntent = \case
    WithdrawalTxBuildFailed{} -> False
    _ -> True

withdrawalFailurePreservesTxBuildArtifacts
    :: WithdrawalFailure -> Bool
withdrawalFailurePreservesTxBuildArtifacts = \case
    WithdrawalTxBuildFailed{} -> True
    _ -> False

removeIfExists :: FilePath -> IO ()
removeIfExists path = do
    exists <- doesFileExist path
    when exists (removeFile path)

withdrawalMaterializationValue
    :: GovernanceEvidence
    -> WithdrawalSubmissionEvidence
    -> Value
withdrawalMaterializationValue evidence submitted =
    object
        [ "governanceActionId" .= geActionId evidence
        , "rewardAccount" .= geRewardAccount evidence
        , "submittedTxId" .= wseSubmittedTxId submitted
        , "signedTxPath" .= wseSignedTxPath submitted
        , "submitLogPath" .= wseSubmitLogPath submitted
        , "materializationPath" .= wseMaterializationPath submitted
        , "treasuryMaterializedTxIn"
            .= wseTreasuryMaterializedTxIn submitted
        , "treasuryAddress" .= wseTreasuryAddress submitted
        , "materializedAdaLovelace"
            .= wseMaterializedLovelace submitted
        , "rewardBeforeSubmitLovelace"
            .= wseRewardBeforeSubmit submitted
        , "rewardAfterSubmitLovelace"
            .= wseRewardAfterSubmit submitted
        , "treasuryUtxoLovelaceBefore"
            .= wseTreasuryLovelaceBefore submitted
        , "treasuryUtxoLovelaceAfter"
            .= wseTreasuryLovelaceAfter submitted
        ]

withdrawIntentPath :: FilePath -> FilePath
withdrawIntentPath runDir =
    runDir </> "withdraw" </> "intent.json"

withdrawTxBodyPath :: FilePath -> FilePath
withdrawTxBodyPath runDir =
    runDir </> "withdraw" </> "tx-body.cbor.hex"

withdrawReportJsonPath :: FilePath -> FilePath
withdrawReportJsonPath runDir =
    runDir </> "withdraw" </> "report.json"

withdrawReportMarkdownPath :: FilePath -> FilePath
withdrawReportMarkdownPath runDir =
    runDir </> "withdraw" </> "report.md"

withdrawTxBuildLogPath :: FilePath -> FilePath
withdrawTxBuildLogPath runDir =
    runDir </> "withdraw" </> "tx-build.log"

withdrawSignedTxPath :: FilePath -> FilePath
withdrawSignedTxPath runDir =
    runDir </> "withdraw" </> "signed-tx.cbor.hex"

withdrawSubmitLogPath :: FilePath -> FilePath
withdrawSubmitLogPath runDir =
    runDir </> "withdraw" </> "submit.log"

withdrawMaterializationPath :: FilePath -> FilePath
withdrawMaterializationPath runDir =
    runDir </> "withdraw" </> "materialized.json"

swapReadinessRegistryPath :: FilePath -> FilePath
swapReadinessRegistryPath runDir =
    runDir </> "swap-ready" </> "registry.json"

swapReadinessSummaryPath :: FilePath -> FilePath
swapReadinessSummaryPath runDir =
    runDir </> "swap-ready" </> "summary.json"

swapReadinessProvenancePath :: FilePath -> FilePath
swapReadinessProvenancePath runDir =
    runDir </> "swap-ready" </> "provenance.json"

placeholderEvidence :: String -> Coin -> GovernanceEvidence
placeholderEvidence treasuryHash rewardBefore =
    GovernanceEvidence
        { geTxId = ""
        , geActionId = ""
        , geRewardAccount = treasuryHash
        , geTreasuryScriptHash = treasuryHash
        , geAmountLovelace = coinLovelace withdrawalAmount
        , geRewardBefore = coinLovelace rewardBefore
        , geRewardAfter = coinLovelace rewardBefore
        , geSetupEpoch = 0
        , geVoteEpoch = 0
        , geFinalEpoch = 0
        }

hasTxId :: TxId -> TxIn -> Bool
hasTxId txId (TxIn utxoTxId _) =
    txId == utxoTxId

addCoin :: Coin -> Coin -> Coin
addCoin (Coin a) (Coin b) =
    Coin (a + b)

addSlots :: Word64 -> SlotNo -> SlotNo
addSlots delta (SlotNo slot) =
    SlotNo (slot + delta)

coinLovelace :: Coin -> Integer
coinLovelace (Coin lovelace) =
    lovelace

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

epochNumber :: EpochNo -> Word64
epochNumber (EpochNo epoch) =
    epoch

expectEither :: String -> Either String a -> IO a
expectEither label =
    either
        ( \err ->
            expectationFailure (label <> ": " <> err)
                *> error "unreachable"
        )
        pure

withTempRunDir :: String -> (FilePath -> IO a) -> IO a
withTempRunDir label action = do
    base <- getTemporaryDirectory
    let path = base </> label
    _ <- try @SomeException (removePathForcibly path)
    createDirectoryIfMissing True path
    result <- action path
    _ <- try @SomeException (removePathForcibly path)
    pure result

mkHash32 :: (HashAlgorithm h) => Word8 -> Hash h a
mkHash32 n =
    fromJust $
        hashFromBytes $
            BS.pack $
                replicate 31 0 ++ [n]

sampleTxId :: Word8 -> TxId
sampleTxId n =
    TxId (unsafeMakeSafeHash (mkHash32 n))

resolveRunDir :: IO FilePath
resolveRunDir = do
    explicit <- lookupEnv "DEVNET_SMOKE_RUN_DIR"
    case explicit of
        Just p -> makeAbsolute p
        Nothing -> do
            cwd <- getCurrentDirectory
            stamp <- utcStamp
            pure (cwd </> "dist-newstyle" </> "devnet-smoke" </> stamp)

resolveRewardTimeoutSeconds :: IO Int
resolveRewardTimeoutSeconds = do
    raw <-
        fromMaybe "600" <$> lookupEnv "DEVNET_SMOKE_REWARD_TIMEOUT_SECONDS"
    case readMaybe raw of
        Just seconds | seconds > 0 -> pure seconds
        _ -> do
            expectationFailure
                ( "DEVNET_SMOKE_REWARD_TIMEOUT_SECONDS must be a positive integer: "
                    <> raw
                )
            pure 600

prepareRunDir :: FilePath -> IO ()
prepareRunDir runDir = do
    exists <- doesDirectoryExist runDir
    contents <-
        if exists
            then listDirectory runDir
            else pure []
    unless (null contents) $
        expectationFailure
            ( "devnet smoke run directory is not empty: "
                <> runDir
            )
    createDirectoryIfMissing True runDir

assertGenesisDir :: FilePath -> IO ()
assertGenesisDir gDir = do
    present <- doesFileExist (gDir </> "shelley-genesis.json")
    unless present $
        expectationFailure
            ( "E2E_GENESIS_DIR does not point at cardano-node-clients genesis: "
                <> gDir
            )

readShelleyTiming :: FilePath -> IO ShelleyGenesisTiming
readShelleyTiming gDir = do
    decoded <-
        eitherDecodeFileStrict
            (gDir </> "shelley-genesis.json")
    case decoded of
        Left err ->
            expectationFailure
                ( "decode shelley-genesis.json: "
                    <> err
                )
                *> error "unreachable"
        Right timing -> pure timing

assertStakeRewardInitArtifacts
    :: FilePath
    -> FilePath
    -> ShelleyGenesisTiming
    -> IO ()
assertStakeRewardInitArtifacts runDir registryPath timing = do
    let summaryPath = StakeRewardInit.stakeRewardInitSummaryPath runDir
        accountsPath = StakeRewardInit.stakeRewardInitAccountsPath runDir
        provenancePath = StakeRewardInit.stakeRewardInitProvenancePath runDir
    traverse_
        assertFileExists
        [ summaryPath
        , accountsPath
        , provenancePath
        ]
    summary <-
        decodeJsonFile
            "stake-reward-init summary"
            summaryPath
    srisPhase summary `shouldBe` "stake-reward-init"
    srisNetwork summary `shouldBe` "devnet"
    srisNetworkMagic summary `shouldBe` sgtNetworkMagic timing
    srisRegistryPath summary `shouldBe` registryPath
    srisAccountsPath summary `shouldBe` accountsPath
    srisProvenancePath summary `shouldBe` provenancePath

    accounts <-
        decodeJsonFile
            "stake-reward-init accounts"
            accountsPath
    sriaPhase accounts `shouldBe` "stake-reward-init"
    sriaNetwork accounts `shouldBe` "devnet"
    assertPreparedStakeRewardAccount True (sriaTreasury accounts)
    assertPreparedStakeRewardAccount True (sriaPermissions accounts)

    provenance <-
        decodeJsonFile
            "stake-reward-init provenance"
            provenancePath
    sripPhase provenance `shouldBe` "stake-reward-init"
    sripSource provenance `shouldBe` "amaru-treasury-tx"
    sripIssue provenance `shouldBe` 148

assertGovernanceWithdrawalInitArtifacts
    :: FilePath
    -> FilePath
    -> FilePath
    -> ShelleyGenesisTiming
    -> IO ()
assertGovernanceWithdrawalInitArtifacts
    runDir
    registryPath
    stakeRewardPath
    timing = do
        let summaryPath =
                GovernanceWithdrawalInit.governanceWithdrawalInitSummaryPath
                    runDir
            governancePath =
                GovernanceWithdrawalInit.governanceWithdrawalInitGovernancePath
                    runDir
            withdrawalPath =
                GovernanceWithdrawalInit.governanceWithdrawalInitWithdrawalPath
                    runDir
            materializationPath =
                GovernanceWithdrawalInit.governanceWithdrawalInitMaterializationPath
                    runDir
            provenancePath =
                GovernanceWithdrawalInit.governanceWithdrawalInitProvenancePath
                    runDir
            intentPath =
                GovernanceWithdrawalInit.governanceWithdrawalInitIntentPath
                    runDir
            txBodyPath =
                GovernanceWithdrawalInit.governanceWithdrawalInitTxBodyPath
                    runDir
            reportJsonPath =
                GovernanceWithdrawalInit.governanceWithdrawalInitReportJsonPath
                    runDir
            reportMarkdownPath =
                GovernanceWithdrawalInit.governanceWithdrawalInitReportMarkdownPath
                    runDir
            txBuildLogPath =
                GovernanceWithdrawalInit.governanceWithdrawalInitTxBuildLogPath
                    runDir
            signedTxPath =
                GovernanceWithdrawalInit.governanceWithdrawalInitSignedTxPath
                    runDir
            submitLogPath =
                GovernanceWithdrawalInit.governanceWithdrawalInitSubmitLogPath
                    runDir
        traverse_
            assertDirectoryExists
            [ runDir </> "registry-init"
            , runDir </> "stake-reward-init"
            , GovernanceWithdrawalInit.governanceWithdrawalInitDirectory runDir
            ]
        traverse_
            assertFileExists
            [ summaryPath
            , governancePath
            , withdrawalPath
            , materializationPath
            , provenancePath
            , intentPath
            , txBodyPath
            , reportJsonPath
            , reportMarkdownPath
            , txBuildLogPath
            , signedTxPath
            , submitLogPath
            ]

        summary <-
            decodeJsonFile
                "governance-withdrawal-init summary"
                summaryPath
        gwisPhase summary `shouldBe` "governance-withdrawal-init"
        gwisStatus summary `shouldBe` "passed"
        gwisNetwork summary `shouldBe` "devnet"
        gwisNetworkMagic summary `shouldBe` sgtNetworkMagic timing
        gwisRunDirectory summary `shouldBe` runDir
        gwisRegistryPath summary `shouldBe` registryPath
        gwisStakeRewardPath summary `shouldBe` stakeRewardPath
        gwisAmountLovelace summary `shouldBe` coinLovelace withdrawalAmount
        gwisGovernancePath summary `shouldBe` governancePath
        gwisWithdrawalPath summary `shouldBe` withdrawalPath
        gwisMaterializationPath summary `shouldBe` materializationPath
        gwisProvenancePath summary `shouldBe` provenancePath

        governance <-
            decodeJsonFile
                "governance-withdrawal-init governance"
                governancePath
        gwigPhase governance `shouldBe` "governance-withdrawal-init"
        gwigNetwork governance `shouldBe` "devnet"
        gwigProposalTxId governance `shouldSatisfy` (not . T.null)
        gwigGovernanceActionId governance
            `shouldSatisfy` T.isSuffixOf "#0"
        gwigVoteTxId governance `shouldSatisfy` (not . T.null)
        gwigTreasuryRewardAccount governance
            `shouldBe` gwigTreasuryScriptHash governance
        gwigAmountLovelace governance
            `shouldBe` coinLovelace withdrawalAmount
        gwigRewardAfterGovernanceLovelace governance
            - gwigRewardBeforeLovelace governance
            `shouldBe` coinLovelace withdrawalAmount
        gwigFinalEpoch governance
            `shouldSatisfy` (>= gwigVoteEpoch governance)
        gwigVoteEpoch governance
            `shouldSatisfy` (>= gwigSetupEpoch governance)

        withdrawal <-
            decodeJsonFile
                "governance-withdrawal-init withdrawal"
                withdrawalPath
        gwiwPhase withdrawal `shouldBe` "governance-withdrawal-init"
        gwiwNetwork withdrawal `shouldBe` "devnet"
        gwiwIntentPath withdrawal `shouldBe` intentPath
        gwiwTxBodyPath withdrawal `shouldBe` txBodyPath
        gwiwReportJsonPath withdrawal `shouldBe` reportJsonPath
        gwiwReportMarkdownPath withdrawal `shouldBe` reportMarkdownPath
        gwiwTxBuildLogPath withdrawal `shouldBe` txBuildLogPath
        gwiwSignedTxPath withdrawal `shouldBe` signedTxPath
        gwiwSubmitLogPath withdrawal `shouldBe` submitLogPath
        gwiwTxId withdrawal `shouldBe` gwiwSubmittedTxId withdrawal
        gwiwFeeLovelace withdrawal `shouldSatisfy` (>= 0)
        gwiwRewardBeforeSubmitLovelace withdrawal
            `shouldBe` gwigRewardAfterGovernanceLovelace governance
        gwiwRewardAfterSubmitLovelace withdrawal `shouldBe` 0

        materialization <-
            decodeJsonFile
                "governance-withdrawal-init materialization"
                materializationPath
        gwimPhase materialization `shouldBe` "governance-withdrawal-init"
        gwimNetwork materialization `shouldBe` "devnet"
        gwimGovernanceActionId materialization
            `shouldBe` gwigGovernanceActionId governance
        gwimTreasuryRewardAccount materialization
            `shouldBe` gwigTreasuryRewardAccount governance
        gwimSubmittedTxId materialization
            `shouldBe` gwiwSubmittedTxId withdrawal
        gwimTreasuryMaterializedTxIn materialization
            `shouldSatisfy` T.isSuffixOf "#0"
        gwimTreasuryAddress materialization `shouldSatisfy` (not . T.null)
        gwimMaterializedAdaLovelace materialization
            `shouldBe` coinLovelace withdrawalAmount
        gwimRewardBeforeSubmitLovelace materialization
            `shouldBe` gwiwRewardBeforeSubmitLovelace withdrawal
        gwimRewardAfterSubmitLovelace materialization `shouldBe` 0
        gwimTreasuryUtxoLovelaceAfter materialization
            - gwimTreasuryUtxoLovelaceBefore materialization
            `shouldBe` gwimMaterializedAdaLovelace materialization
        gwimRegistryPath materialization `shouldBe` registryPath
        gwimStakeRewardPath materialization `shouldBe` stakeRewardPath

        provenance <-
            decodeJsonFile
                "governance-withdrawal-init provenance"
                provenancePath
        gwipPhase provenance `shouldBe` "governance-withdrawal-init"
        gwipSource provenance `shouldBe` "amaru-treasury-tx"
        gwipIssue provenance `shouldBe` 149
        gwipParentIssue provenance `shouldBe` 151
        gwipDependsOnIssues provenance `shouldBe` [147, 148]

assertDisburseSubmitArtifacts
    :: FilePath
    -> FilePath
    -> FilePath
    -> T.Text
    -> ShelleyGenesisTiming
    -> IO ()
assertDisburseSubmitArtifacts
    runDir
    registryPath
    materializedPath
    beneficiaryAddress
    timing = do
        let summaryPath =
                DisburseSubmit.disburseSubmitSummaryPath runDir
            disbursePath =
                DisburseSubmit.disburseSubmitDisbursePath runDir
            beneficiaryPath =
                DisburseSubmit.disburseSubmitBeneficiaryPath runDir
            treasuryPath =
                DisburseSubmit.disburseSubmitTreasuryPath runDir
            provenancePath =
                DisburseSubmit.disburseSubmitProvenancePath runDir
            intentPath =
                DisburseSubmit.disburseSubmitIntentPath runDir
            txBodyPath =
                DisburseSubmit.disburseSubmitTxBodyPath runDir
            reportJsonPath =
                DisburseSubmit.disburseSubmitReportJsonPath runDir
            reportMarkdownPath =
                DisburseSubmit.disburseSubmitReportMarkdownPath runDir
            signedTxPath =
                DisburseSubmit.disburseSubmitSignedTxPath runDir
            submitLogPath =
                DisburseSubmit.disburseSubmitSubmitLogPath runDir
        traverse_
            assertDirectoryExists
            [ runDir </> "registry-init"
            , runDir </> "stake-reward-init"
            , GovernanceWithdrawalInit.governanceWithdrawalInitDirectory runDir
            , DisburseSubmit.disburseSubmitDirectory runDir
            ]
        traverse_
            assertFileExists
            [ summaryPath
            , disbursePath
            , beneficiaryPath
            , treasuryPath
            , provenancePath
            , intentPath
            , txBodyPath
            , reportJsonPath
            , reportMarkdownPath
            , signedTxPath
            , submitLogPath
            ]

        materialization <-
            decodeJsonFile
                "governance-withdrawal-init materialization"
                materializedPath

        summary <-
            decodeJsonFile "disburse-submit summary" summaryPath
        dsssPhase summary `shouldBe` "disburse-submit"
        dsssStatus summary `shouldBe` "passed"
        dsssNetwork summary `shouldBe` "devnet"
        dsssNetworkMagic summary `shouldBe` sgtNetworkMagic timing
        dsssRunDirectory summary `shouldBe` runDir
        dsssRegistryPath summary `shouldBe` registryPath
        dsssMaterializedPath summary `shouldBe` materializedPath
        dsssAmountLovelace summary `shouldBe` 1_000_000
        dsssDisbursePath summary `shouldBe` disbursePath
        dsssBeneficiaryPath summary `shouldBe` beneficiaryPath
        dsssTreasuryPath summary `shouldBe` treasuryPath
        dsssProvenancePath summary `shouldBe` provenancePath

        disburse <-
            decodeJsonFile "disburse-submit disburse" disbursePath
        dssdPhase disburse `shouldBe` "disburse-submit"
        dssdNetwork disburse `shouldBe` "devnet"
        dssdIntentPath disburse `shouldBe` intentPath
        dssdTxBodyPath disburse `shouldBe` txBodyPath
        dssdReportJsonPath disburse `shouldBe` reportJsonPath
        dssdReportMarkdownPath disburse `shouldBe` reportMarkdownPath
        dssdSignedTxPath disburse `shouldBe` signedTxPath
        dssdSubmitLogPath disburse `shouldBe` submitLogPath
        dssdTxId disburse `shouldBe` dssdSubmittedTxId disburse
        dssdSubmittedTxId disburse `shouldSatisfy` (not . T.null)
        dssdAmountLovelace disburse `shouldBe` 1_000_000
        dssdFeeLovelace disburse `shouldSatisfy` (>= 0)

        beneficiary <-
            decodeJsonFile "disburse-submit beneficiary" beneficiaryPath
        dsbPhase beneficiary `shouldBe` "disburse-submit"
        dsbNetwork beneficiary `shouldBe` "devnet"
        dsbAddress beneficiary `shouldBe` beneficiaryAddress
        dsbTxIn beneficiary
            `shouldBe` dssdSubmittedTxId disburse <> "#1"
        dsbLovelace beneficiary `shouldBe` dssdAmountLovelace disburse

        treasury <-
            decodeJsonFile "disburse-submit treasury" treasuryPath
        dstPhase treasury `shouldBe` "disburse-submit"
        dstNetwork treasury `shouldBe` "devnet"
        dstInput treasury
            `shouldBe` gwimTreasuryMaterializedTxIn materialization
        dstOutput treasury
            `shouldBe` dssdSubmittedTxId disburse <> "#0"
        dstAddress treasury `shouldBe` gwimTreasuryAddress materialization
        dstLovelaceBefore treasury
            `shouldBe` gwimMaterializedAdaLovelace materialization
        dstLovelaceBefore treasury
            - dstLovelaceAfter treasury
            `shouldBe` dssdAmountLovelace disburse
        dstLovelaceAfter treasury `shouldSatisfy` (> 0)
        dstConsumed treasury `shouldBe` True

        provenance <-
            decodeJsonFile "disburse-submit provenance" provenancePath
        dspPhase provenance `shouldBe` "disburse-submit"
        dspSource provenance `shouldBe` "amaru-treasury-tx"
        dspIssue provenance `shouldBe` 150
        dspParentIssue provenance `shouldBe` 151
        dspDependsOnIssues provenance `shouldBe` [147, 149]

assertPreparedStakeRewardAccount
    :: Bool -> StakeRewardInitAccount -> IO ()
assertPreparedStakeRewardAccount expectedRegistered account = do
    sriaScriptHash account
        `shouldSatisfy` (not . T.null)
    sriaRewardAccount account
        `shouldSatisfy` (not . T.null)
    sriaLedgerNetwork account `shouldBe` "Testnet"
    sriaRegistered account `shouldBe` expectedRegistered
    sriaRewardsLovelace account `shouldSatisfy` (>= 0)

assertFileExists :: FilePath -> IO ()
assertFileExists path = do
    exists <- doesFileExist path
    exists `shouldBe` True

assertDirectoryExists :: FilePath -> IO ()
assertDirectoryExists path = do
    exists <- doesDirectoryExist path
    exists `shouldBe` True

decodeJsonFile :: (FromJSON a) => String -> FilePath -> IO a
decodeJsonFile label path =
    eitherDecodeFileStrict path >>= \case
        Left err ->
            expectationFailure
                ( "decode "
                    <> label
                    <> " at "
                    <> path
                    <> ": "
                    <> err
                )
                *> error "unreachable"
        Right value -> pure value

epochDurationSeconds :: ShelleyGenesisTiming -> Double
epochDurationSeconds timing =
    fromIntegral (sgtEpochLength timing) * sgtSlotLength timing

copyNodeLog :: FilePath -> FilePath -> IO ()
copyNodeLog socket runDir = do
    let source = takeDirectory socket </> "node.log"
        target = runDir </> "node.log"
    exists <- doesFileExist source
    when exists (copyFile source target)

writeTiming
    :: FilePath
    -> Integer
    -> FilePath
    -> ShelleyGenesisTiming
    -> IO ()
writeTiming runDir startMs socket timing =
    BSL.writeFile
        (runDir </> "timing.json")
        ( encode
            ( timingValue
                startMs
                socket
                timing
            )
        )

writeSummary
    :: FilePath
    -> FilePath
    -> ShelleyGenesisTiming
    -> String
    -> IO ()
writeSummary runDir socket timing status =
    BSL.writeFile
        (runDir </> "summary.json")
        ( encode
            ( object
                [ "phase" .= ("node" :: String)
                , "status" .= status
                , "socket" .= socket
                , "network" .= ("devnet" :: String)
                , "networkMagic" .= sgtNetworkMagic timing
                , "epochDurationSeconds"
                    .= epochDurationSeconds timing
                ]
            )
        )

timingValue
    :: Integer
    -> FilePath
    -> ShelleyGenesisTiming
    -> Value
timingValue startMs socket timing =
    object
        [ "network" .= ("devnet" :: String)
        , "networkMagic" .= sgtNetworkMagic timing
        , "epochLength" .= sgtEpochLength timing
        , "slotLengthSeconds" .= sgtSlotLength timing
        , "epochDurationSeconds" .= epochDurationSeconds timing
        , "systemStartMs" .= startMs
        , "socket" .= socket
        ]

putSummaryLines
    :: FilePath
    -> FilePath
    -> ShelleyGenesisTiming
    -> String
    -> IO ()
putSummaryLines runDir socket timing status = do
    let linesOut =
            [ "devnet-smoke: run-dir " <> runDir
            , "devnet-smoke: network devnet magic "
                <> show (sgtNetworkMagic timing)
            , "devnet-smoke: epoch-duration "
                <> show (epochDurationSeconds timing)
            , "devnet-smoke: socket " <> socket
            , "devnet-smoke: phase node " <> status
            ]
    writeFile (runDir </> "summary.log") (unlines linesOut)
    mapM_ putStrLn linesOut

utcStamp :: IO FilePath
utcStamp =
    formatTime defaultTimeLocale "%Y%m%dT%H%M%SZ"
        <$> getCurrentTime
