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
    )
import Cardano.Crypto.Hash
    ( Hash
    , HashAlgorithm
    , hashFromBytes
    )
import Cardano.Crypto.Hash.Class (hashToBytes)
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
    ( KeyRole (DRepRole, Payment, Staking)
    , VKey (..)
    , hashKey
    )
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    , multiAssetFromList
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
    , registerAndVoteAbstain
    , spend
    , validTo
    , vote
    )
import Cardano.Tx.Ledger (ConwayTx)
import Codec.Binary.Bech32 qualified as Bech32
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (poll, withAsync)
import Control.Exception (SomeException, try)
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
import Data.Text.IO qualified as TIO
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
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    , shouldSatisfy
    )

import Amaru.Treasury.Backend.N2C
    ( probeNetworkMagic
    )
import Amaru.Treasury.Cli.TxBuild qualified as TxBuild
import Amaru.Treasury.IntentJSON
    ( SAction (..)
    , SomeTreasuryIntent (..)
    , TreasuryIntent (..)
    , WithdrawInputs (..)
    , decodeTreasuryIntentFile
    , encodeSomeTreasuryIntent
    )
import Amaru.Treasury.Redeemer
    ( RawPlutusData (..)
    , emptyListRedeemer
    )
import Amaru.Treasury.Registry.Constants
    ( payoutUpperbound
    , permissionsValidatorBlob
    , registryTokenName
    , scopesTokenName
    , scopesValidatorBlob
    , treasuryExpirationMs
    , treasuryRegistryValidatorBlob
    , treasuryValidatorBlob
    )
import Amaru.Treasury.Registry.Derive
    ( ScriptParam (..)
    , applyParams
    , applyScriptParams
    , derivedTreasuryScriptBlob
    , scriptHashOfBlob
    , scriptHashToHex
    )
import Amaru.Treasury.Report qualified as Report
import Amaru.Treasury.Report.Render qualified as ReportRender
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
import Amaru.Treasury.Tx.AttachWitness
    ( decodeUnsignedTxHex
    , encodeSignedTxHex
    , renderAttachError
    )
import Amaru.Treasury.Tx.Submit
    ( renderTxId
    )
import Amaru.Treasury.Tx.SwapWizard
    ( ScopeOwners (..)
    , txInToText
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
            "withdraw: submits built rewards and materializes ADA"
            (runForPhases ["withdraw"] withdrawSmoke)
        it
            "swap-ready: publishes SundaeSwap V3 order validator readiness"
            (runForPhases ["swap-ready"] swapReadySmoke)

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

withdrawSmoke :: IO ()
withdrawSmoke = do
    runDir <- resolveRunDir
    withFundedGovernanceReward runDir prepareDevnetWithdrawalRegistry $
        \socket timing provider submitter registry evidence -> do
            writeGovernanceArtifacts runDir socket timing evidence
            rewards <-
                writeWithdrawalIntentArtifacts
                    runDir
                    socket
                    timing
                    provider
                    registry
                    evidence
            writeWithdrawalBuildArtifacts
                runDir
                socket
                timing
                provider
                submitter
                registry
                evidence
                rewards

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

data TreasuryTarget = TreasuryTarget
    { ttScript :: !(Script ConwayEra)
    , ttScriptHash :: !ScriptHash
    , ttScriptHashText :: !T.Text
    , ttAddress :: !Addr
    }

data DevnetScriptSet = DevnetScriptSet
    { dssScopesScript :: !(Script ConwayEra)
    , dssScopesHash :: !ScriptHash
    , dssRegistryScript :: !(Script ConwayEra)
    , dssRegistryHash :: !ScriptHash
    , dssPermissionsScript :: !(Script ConwayEra)
    , dssPermissionsHash :: !ScriptHash
    , dssTreasuryTarget :: !TreasuryTarget
    }

data DevnetRegistryAnchors = DevnetRegistryAnchors
    { draScopesRef :: !TxIn
    , draPermissionsRef :: !TxIn
    , draTreasuryRef :: !TxIn
    , draRegistryRef :: !TxIn
    , draRegistryPolicyId :: !T.Text
    , draPermissionsHash :: !ScriptHash
    , draOwnerKeyHash :: !T.Text
    , draTreasuryTarget :: !TreasuryTarget
    }

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

devnetSeedCoin :: Coin
devnetSeedCoin = Coin 100_000_000

devnetNftCoin :: Coin
devnetNftCoin = Coin 5_000_000

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

preparePinnedTreasuryTarget
    :: Provider IO
    -> Submitter IO
    -> PParams ConwayEra
    -> [(TxIn, TxOut ConwayEra)]
    -> IO (TreasuryTarget, ())
preparePinnedTreasuryTarget _provider _submitter _pp _utxos = do
    target <-
        treasuryTargetFromBlob
            =<< expectEither
                "derive pinned treasury script"
                (derivedTreasuryScriptBlob CoreDevelopment)
    pure (target, ())

prepareDevnetWithdrawalRegistry
    :: Provider IO
    -> Submitter IO
    -> PParams ConwayEra
    -> [(TxIn, TxOut ConwayEra)]
    -> IO (TreasuryTarget, DevnetRegistryAnchors)
prepareDevnetWithdrawalRegistry provider submitter pp utxos = do
    registry <-
        deployDevnetWithdrawalRegistry provider submitter pp utxos
    pure (draTreasuryTarget registry, registry)

deployDevnetWithdrawalRegistry
    :: Provider IO
    -> Submitter IO
    -> PParams ConwayEra
    -> [(TxIn, TxOut ConwayEra)]
    -> IO DevnetRegistryAnchors
deployDevnetWithdrawalRegistry provider submitter pp utxos = do
    seed <- selectLargestAdaUtxo "registry deployment" utxos
    (scopesSeedRef, registrySeedRef) <-
        submitSeedSplit provider submitter pp seed
    seedOuts <-
        waitForTxIns provider [scopesSeedRef, registrySeedRef] 60
    scripts <-
        deriveDevnetScripts scopesSeedRef registrySeedRef
    (scopesRef, registryRef) <-
        submitRegistryNfts
            provider
            submitter
            pp
            scripts
            seedOuts
    publishUtxos <- queryUTxOs provider genesisAddr
    publishSeed <-
        selectLargestAdaUtxo "reference script publishing" publishUtxos
    (permissionsRef, treasuryRef) <-
        submitReferenceScripts
            provider
            submitter
            pp
            scripts
            publishSeed
    let ownerHash =
            keyHashToText $
                paymentKeyHashFromSignKey genesisSignKey
        treasuryTarget =
            dssTreasuryTarget scripts
    pure
        DevnetRegistryAnchors
            { draScopesRef = scopesRef
            , draPermissionsRef = permissionsRef
            , draTreasuryRef = treasuryRef
            , draRegistryRef = registryRef
            , draRegistryPolicyId =
                scriptHashToHex (dssRegistryHash scripts)
            , draPermissionsHash =
                dssPermissionsHash scripts
            , draOwnerKeyHash = ownerHash
            , draTreasuryTarget = treasuryTarget
            }

submitSeedSplit
    :: Provider IO
    -> Submitter IO
    -> PParams ConwayEra
    -> (TxIn, TxOut ConwayEra)
    -> IO (TxIn, TxIn)
submitSeedSplit provider submitter pp seed@(seedIn, _) = do
    snapshot <- queryLedgerSnapshot provider
    let interpret :: InterpretIO NoCtx
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
            _ <- payTo genesisAddr (inject devnetSeedCoin)
            _ <- payTo genesisAddr (inject devnetSeedCoin)
            validTo upperSlot
    txId <-
        buildSubmitAndWait
            "split registry seed"
            provider
            submitter
            pp
            interpret
            eval
            [seed]
            []
            genesisAddr
            prog
    pure (txOutRef txId 0, txOutRef txId 1)

submitRegistryNfts
    :: Provider IO
    -> Submitter IO
    -> PParams ConwayEra
    -> DevnetScriptSet
    -> [(TxIn, TxOut ConwayEra)]
    -> IO (TxIn, TxIn)
submitRegistryNfts provider submitter pp scripts seedOuts = do
    (scopesSeed@(scopesSeedRef, _), registrySeed@(registrySeedRef, _)) <-
        case seedOuts of
            [scopesSeed, registrySeed] ->
                pure (scopesSeed, registrySeed)
            _ ->
                fail "expected exactly two registry seed UTxOs"
    let
        scopesOut =
            nftTxOut
                (scriptAddr Testnet (dssScopesHash scripts))
                (dssScopesHash scripts)
                scopesTokenName
                (ownersDatum (paymentKeyHashFromSignKey genesisSignKey))
        registryOut =
            nftTxOut
                (scriptAddr Testnet (dssRegistryHash scripts))
                (dssRegistryHash scripts)
                registryTokenName
                (registryDatum (ttScriptHash (dssTreasuryTarget scripts)))
    snapshot <- queryLedgerSnapshot provider
    let interpret :: InterpretIO NoCtx
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
            _ <- spend scopesSeedRef
            _ <- spend registrySeedRef
            collateral scopesSeedRef
            attachScript (dssScopesScript scripts)
            attachScript (dssRegistryScript scripts)
            mint
                (PolicyID (dssScopesHash scripts))
                (Map.singleton (assetName scopesTokenName) 1)
                (RawPlutusData emptyListRedeemer)
            mint
                (PolicyID (dssRegistryHash scripts))
                (Map.singleton (assetName registryTokenName) 1)
                (RawPlutusData emptyListRedeemer)
            scopesIx <- output scopesOut
            registryIx <- output registryOut
            checkMinUtxo pp scopesIx
            checkMinUtxo pp registryIx
            validTo upperSlot
    txId <-
        buildSubmitAndWait
            "mint registry NFTs"
            provider
            submitter
            pp
            interpret
            eval
            [scopesSeed, registrySeed]
            []
            genesisAddr
            prog
    pure (txOutRef txId 0, txOutRef txId 1)

submitReferenceScripts
    :: Provider IO
    -> Submitter IO
    -> PParams ConwayEra
    -> DevnetScriptSet
    -> (TxIn, TxOut ConwayEra)
    -> IO (TxIn, TxIn)
submitReferenceScripts provider submitter pp scripts seed@(seedIn, _) = do
    snapshot <- queryLedgerSnapshot provider
    let refAddr =
            ttAddress (dssTreasuryTarget scripts)
        permissionsOut =
            refScriptTxOut refAddr (dssPermissionsScript scripts)
        treasuryOut =
            refScriptTxOut refAddr (ttScript (dssTreasuryTarget scripts))
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
            permissionsIx <- output permissionsOut
            treasuryIx <- output treasuryOut
            checkMinUtxo pp permissionsIx
            checkMinUtxo pp treasuryIx
            validTo upperSlot
    txId <-
        buildSubmitAndWait
            "publish reference scripts"
            provider
            submitter
            pp
            interpret
            eval
            [seed]
            []
            genesisAddr
            prog
    pure (txOutRef txId 0, txOutRef txId 1)

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

deriveDevnetScripts :: TxIn -> TxIn -> IO DevnetScriptSet
deriveDevnetScripts scopesSeed registrySeed = do
    scopesBlob <-
        expectEither
            "derive devnet scopes NFT policy"
            (applyParams scopesValidatorBlob [outputReferenceData scopesSeed])
    scopesHash <-
        expectEither
            "hash devnet scopes NFT policy"
            (scriptHashOfBlob scopesBlob)
    scopesScript <- scriptFromBlob scopesBlob
    registryBlob <-
        expectEither
            "derive devnet registry NFT policy"
            ( applyParams
                treasuryRegistryValidatorBlob
                [ outputReferenceData registrySeed
                , scopeData CoreDevelopment
                ]
            )
    registryHash <-
        expectEither
            "hash devnet registry NFT policy"
            (scriptHashOfBlob registryBlob)
    registryScript <- scriptFromBlob registryBlob
    permissionsBlob <-
        expectEither
            "derive devnet permissions script"
            ( applyScriptParams
                permissionsValidatorBlob
                [ ParamData (B (scriptHashBytes scopesHash))
                , ParamData (scopeData CoreDevelopment)
                ]
            )
    permissionsHash <-
        expectEither
            "hash devnet permissions script"
            (scriptHashOfBlob permissionsBlob)
    permissionsScript <- scriptFromBlob permissionsBlob
    treasuryTarget <-
        treasuryTargetFromBlob
            =<< expectEither
                "derive devnet treasury script"
                ( applyParams
                    treasuryValidatorBlob
                    [ treasuryConfigurationData
                        (scriptHashBytes registryHash)
                        (scriptHashBytes permissionsHash)
                    ]
                )
    pure
        DevnetScriptSet
            { dssScopesScript = scopesScript
            , dssScopesHash = scopesHash
            , dssRegistryScript = registryScript
            , dssRegistryHash = registryHash
            , dssPermissionsScript = permissionsScript
            , dssPermissionsHash = permissionsHash
            , dssTreasuryTarget = treasuryTarget
            }

treasuryTargetFromBlob :: BS.ByteString -> IO TreasuryTarget
treasuryTargetFromBlob blob = do
    script <- scriptFromBlob blob
    scriptHash <-
        expectEither
            "hash treasury script"
            (scriptHashOfBlob blob)
    pure
        TreasuryTarget
            { ttScript = script
            , ttScriptHash = scriptHash
            , ttScriptHashText = scriptHashToHex scriptHash
            , ttAddress = scriptAddr Testnet scriptHash
            }

outputReferenceData :: TxIn -> Data
outputReferenceData (TxIn (TxId txIdHash) ix) =
    Constr
        0
        [ B (hashToBytes (extractHash txIdHash))
        , I (toInteger (txIxToInt ix))
        ]

scopeData :: ScopeId -> Data
scopeData = \case
    CoreDevelopment -> Constr 0 []
    _ -> error "devnet smoke only derives core_development scripts"

treasuryConfigurationData :: BS.ByteString -> BS.ByteString -> Data
treasuryConfigurationData registryPolicy permissionsHash =
    Constr
        0
        [ B registryPolicy
        , treasuryPermissionsData permissionsHash
        , I treasuryExpirationMs
        , I payoutUpperbound
        ]

treasuryPermissionsData :: BS.ByteString -> Data
treasuryPermissionsData permissionsHash =
    Constr
        0
        [ multisigScriptPermission permissionsHash
        , multisigScriptPermission permissionsHash
        , Constr 2 [List []]
        , multisigScriptPermission permissionsHash
        ]

multisigScriptPermission :: BS.ByteString -> Data
multisigScriptPermission scriptHash =
    Constr 6 [B scriptHash]

ownersDatum :: KeyHash Payment -> Data
ownersDatum owner =
    Constr
        0
        [ ownerSignature
        , ownerSignature
        , ownerSignature
        , ownerSignature
        ]
  where
    ownerSignature =
        Constr 0 [B (keyHashBytes owner)]

registryDatum :: ScriptHash -> Data
registryDatum treasuryHash =
    Constr
        0
        [ scriptCredential treasuryHash
        , Constr 1 [B (BS.replicate 28 0)]
        ]

scriptCredential :: ScriptHash -> Data
scriptCredential =
    Constr 1 . pure . B . scriptHashBytes

nftTxOut
    :: Addr
    -> ScriptHash
    -> BS.ByteString
    -> Data
    -> TxOut ConwayEra
nftTxOut addr policy tokenName datum =
    mkBasicTxOut
        addr
        ( MaryValue
            devnetNftCoin
            ( multiAssetFromList
                [
                    ( PolicyID policy
                    , assetName tokenName
                    , 1
                    )
                ]
            )
        )
        & datumTxOutL .~ mkInlineDatum @ConwayEra datum

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

assetName :: BS.ByteString -> AssetName
assetName =
    AssetName . SBS.toShort

scriptHashBytes :: ScriptHash -> BS.ByteString
scriptHashBytes (ScriptHash h) =
    hashToBytes h

keyHashBytes :: KeyHash kr -> BS.ByteString
keyHashBytes (KeyHash h) =
    hashToBytes h

keyHashToText :: KeyHash kr -> T.Text
keyHashToText =
    TE.decodeUtf8Lenient . B16.encode . keyHashBytes

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

writeWithdrawalIntentArtifacts
    :: FilePath
    -> FilePath
    -> ShelleyGenesisTiming
    -> Provider IO
    -> DevnetRegistryAnchors
    -> GovernanceEvidence
    -> IO Coin
writeWithdrawalIntentArtifacts runDir socket timing provider registry evidence = do
    createDirectoryIfMissing True (runDir </> "withdraw")
    writeWithdrawalRegistryArtifacts runDir registry
    let treasuryHash =
            ttScriptHash (draTreasuryTarget registry)
    ttScriptHashText (draTreasuryTarget registry)
        `shouldBe` T.pack (geTreasuryScriptHash evidence)
    let treasuryAccount =
            AccountAddress Testnet (AccountId (ScriptHashObj treasuryHash))
    observedRewards <- rewardBalance provider treasuryAccount
    observedRewards `shouldBe` Coin (geRewardAfter evidence)
    let registryView =
            devnetRegistryView registry
    let walletAddress = renderAddr genesisAddr
        resolver =
            Withdraw.WithdrawResolverEnv
                { Withdraw.wreQueryWalletUtxos =
                    queryWalletUtxosForWithdraw provider walletAddress
                , Withdraw.wreQueryRewardsLovelace = \account -> do
                    account `shouldBe` T.pack (geRewardAccount evidence)
                    coinLovelace <$> rewardBalance provider treasuryAccount
                , Withdraw.wreComputeUpperBound = \_ -> do
                    snapshot <- queryLedgerSnapshot provider
                    pure $
                        Right $
                            slotNumber $
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
    when (observedRewards <= Coin 0) $ do
        (epoch, tipSlot) <- withdrawalEpochTip provider
        message <-
            writeWithdrawalFailure
                runDir
                socket
                timing
                (Just evidence)
                ( WithdrawalZeroRewards
                    (geRewardAccount evidence)
                    observedRewards
                    epoch
                    tipSlot
                )
        expectationFailure message
    resolved <- Withdraw.resolveWithdrawEnv resolver input
    env <- case resolved of
        Right ok -> pure ok
        Left err -> do
            (epoch, tipSlot) <- withdrawalEpochTip provider
            let failure = withdrawalResolverFailure err observedRewards epoch tipSlot
            message <-
                writeWithdrawalFailure
                    runDir
                    socket
                    timing
                    (Just evidence)
                    failure
            expectationFailure message *> error "unreachable"
    Withdraw.weTreasuryRewardAccount env
        `shouldBe` T.pack (geRewardAccount evidence)
    Withdraw.weRewardsLovelace env
        `shouldBe` coinLovelace observedRewards
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
    intent <- case Withdraw.withdrawToTreasuryResult env answers of
        Left err -> do
            (epoch, tipSlot) <- withdrawalEpochTip provider
            let failure =
                    withdrawalIntentFailure err observedRewards epoch tipSlot
            message <-
                writeWithdrawalFailure
                    runDir
                    socket
                    timing
                    (Just evidence)
                    failure
            expectationFailure message *> error "unreachable"
        Right (Withdraw.WithdrawNoRewards account) -> do
            (epoch, tipSlot) <- withdrawalEpochTip provider
            message <-
                writeWithdrawalFailure
                    runDir
                    socket
                    timing
                    (Just evidence)
                    ( WithdrawalZeroRewards
                        (T.unpack account)
                        observedRewards
                        epoch
                        tipSlot
                    )
            expectationFailure message *> error "unreachable"
        Right (Withdraw.WithdrawIntentReady ready) -> pure ready
    BSL.writeFile
        (withdrawIntentPath runDir)
        (encodeSomeTreasuryIntent (SomeTreasuryIntent SWithdraw intent))
    decoded <- decodeTreasuryIntentFile (withdrawIntentPath runDir)
    case decoded of
        Right (SomeTreasuryIntent SWithdraw parsed) -> do
            wdiTreasuryRewardAccount (tiPayload parsed)
                `shouldBe` T.pack (geRewardAccount evidence)
            wdiRewardsLovelace (tiPayload parsed)
                `shouldBe` coinLovelace observedRewards
        Right _ ->
            expectationFailure "withdraw smoke wrote non-withdraw intent"
        Left err ->
            expectationFailure ("decode withdraw intent: " <> err)
    writeWithdrawalGovernancePrerequisite runDir evidence
    writeWithdrawalIntentSummary
        runDir
        socket
        timing
        evidence
        (coinLovelace observedRewards)
    putWithdrawalIntentLines runDir evidence observedRewards
    pure observedRewards

withdrawalEpochTip :: Provider IO -> IO (Maybe Word64, Maybe Word64)
withdrawalEpochTip provider = do
    snapshot <- queryLedgerSnapshot provider
    pure
        ( Just (epochNumber (ledgerEpoch snapshot))
        , Just (slotNumber (ledgerTipSlot snapshot))
        )

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

withdrawalIntentFailure
    :: Withdraw.WithdrawError
    -> Coin
    -> Maybe Word64
    -> Maybe Word64
    -> WithdrawalFailure
withdrawalIntentFailure err rewards epoch tipSlot =
    case err of
        Withdraw.WithdrawNetworkMismatch expected observed ->
            WithdrawalNetworkMismatch expected observed rewards epoch tipSlot
        _ ->
            WithdrawalIntentFailed err rewards epoch tipSlot

writeWithdrawalBuildArtifacts
    :: FilePath
    -> FilePath
    -> ShelleyGenesisTiming
    -> Provider IO
    -> Submitter IO
    -> DevnetRegistryAnchors
    -> GovernanceEvidence
    -> Coin
    -> IO ()
writeWithdrawalBuildArtifacts
    runDir
    socket
    timing
    provider
    submitter
    registry
    evidence
    rewards = do
        createDirectoryIfMissing True (runDir </> "withdraw")
        removeIfExists (withdrawTxBodyPath runDir)
        removeIfExists (withdrawReportJsonPath runDir)
        removeIfExists (withdrawReportMarkdownPath runDir)
        removeIfExists (withdrawTxBuildLogPath runDir)
        removeIfExists (withdrawSignedTxPath runDir)
        removeIfExists (withdrawSubmitLogPath runDir)
        removeIfExists (withdrawMaterializationPath runDir)
        buildExit <-
            try @ExitCode $
                TxBuild.runTxBuild
                    socket
                    TxBuild.TxBuildOpts
                        { TxBuild.tboIntentPath =
                            Just (withdrawIntentPath runDir)
                        , TxBuild.tboOutPath = Just (withdrawTxBodyPath runDir)
                        , TxBuild.tboLog = Just (withdrawTxBuildLogPath runDir)
                        , TxBuild.tboReportPath =
                            Just (withdrawReportJsonPath runDir)
                        }
        case buildExit of
            Right () -> pure ()
            Left exitCode -> do
                failure <- readWithdrawalTxBuildFailure runDir
                message <-
                    writeWithdrawalFailure
                        runDir
                        socket
                        timing
                        (Just evidence)
                        (WithdrawalTxBuildFailed exitCode failure)
                expectationFailure message
        buildOutput <-
            expectEither
                "decode withdrawal tx-build report"
                =<< eitherDecodeFileStrict
                    @Report.TxBuildOutput
                    (withdrawReportJsonPath runDir)
        success <- case Report.txoResult buildOutput of
            Report.TxBuildOutputSuccess ok -> pure ok
            Report.TxBuildOutputFailure failure ->
                expectationFailure
                    ( "withdrawal tx-build report is failure: "
                        <> show failure
                    )
                    *> error "unreachable"
        txBodyHex <- TE.decodeUtf8 <$> BS.readFile (withdrawTxBodyPath runDir)
        txBodyHex `shouldBe` Report.unTxCborHex (Report.tbsTxCbor success)
        render <- case ReportRender.renderBuildOutput buildOutput of
            Right ok -> pure ok
            Left err ->
                expectationFailure
                    ("render withdrawal report: " <> show err)
                    *> error "unreachable"
        TIO.writeFile
            (withdrawReportMarkdownPath runDir)
            (ReportRender.unRenderOutput render)
        writeWithdrawalBuildSummary
            runDir
            socket
            timing
            evidence
            rewards
            success
        putWithdrawalBuildLines runDir evidence rewards success
        submitted <-
            signSubmitAndMaterializeWithdrawal
                runDir
                provider
                submitter
                registry
                evidence
                rewards
                success
        writeWithdrawalSubmittedSummary
            runDir
            socket
            timing
            evidence
            rewards
            success
            submitted
        putWithdrawalSubmittedLines runDir evidence rewards success submitted

signSubmitAndMaterializeWithdrawal
    :: FilePath
    -> Provider IO
    -> Submitter IO
    -> DevnetRegistryAnchors
    -> GovernanceEvidence
    -> Coin
    -> Report.TxBuildSuccess
    -> IO WithdrawalSubmissionEvidence
signSubmitAndMaterializeWithdrawal
    runDir
    provider
    submitter
    registry
    evidence
    rewards
    success = do
        txHex <- BS.readFile (withdrawTxBodyPath runDir)
        tx <- case decodeUnsignedTxHex txHex of
            Right ok -> pure ok
            Left err ->
                expectationFailure
                    ( "decode withdrawal tx before signing: "
                        <> T.unpack (renderAttachError err)
                    )
                    *> error "unreachable"
        let target =
                draTreasuryTarget registry
            treasuryAccount =
                AccountAddress
                    Testnet
                    (AccountId (ScriptHashObj (ttScriptHash target)))
            signed =
                addKeyWitness genesisSignKey tx
            submittedTxId =
                txIdTx signed
            submittedTxIdText =
                renderTxId submittedTxId
            materializedRef =
                txOutRef submittedTxId 0
            identity =
                Report.trIdentity (Report.tbsReport success)
        Report.tiTxId identity `shouldBe` submittedTxIdText
        rewardBeforeSubmit <- rewardBalance provider treasuryAccount
        rewardBeforeSubmit `shouldBe` rewards
        treasuryBefore <- queryUTxOs provider (ttAddress target)
        let treasuryLovelaceBefore =
                sumUtxoLovelace treasuryBefore
        BS.writeFile
            (withdrawSignedTxPath runDir)
            (encodeSignedTxHex signed)
        submitTx submitter signed >>= \case
            Submitted _ -> pure ()
            Rejected reason ->
                expectationFailure
                    ( "withdrawal submit rejected: "
                        <> BS8.unpack reason
                    )
        writeFile
            (withdrawSubmitLogPath runDir)
            ( "submit: accepted "
                <> T.unpack submittedTxIdText
                <> "\n"
            )
        materialized <-
            waitForMaterializedTxOut
                provider
                materializedRef
                60
        materializedOut <- case materialized of
            Just (_, txOut) -> pure txOut
            Nothing ->
                expectationFailure
                    ( "timed out waiting for materialized treasury UTxO "
                        <> T.unpack (txInToText materializedRef)
                    )
                    *> error "unreachable"
        materializedOut ^. addrTxOutL `shouldBe` ttAddress target
        let materializedLovelace =
                txOutLovelace materializedOut
            materializedAssets =
                txOutHasAssets materializedOut
        materializedLovelace `shouldBe` coinLovelace rewards
        materializedAssets `shouldBe` False
        rewardAfterSubmit <- rewardBalance provider treasuryAccount
        rewardAfterSubmit `shouldBe` Coin 0
        treasuryAfter <- queryUTxOs provider (ttAddress target)
        let treasuryLovelaceAfter =
                sumUtxoLovelace treasuryAfter
            submitted =
                WithdrawalSubmissionEvidence
                    { wseSubmittedTxId = submittedTxIdText
                    , wseSignedTxPath = withdrawSignedTxPath runDir
                    , wseSubmitLogPath = withdrawSubmitLogPath runDir
                    , wseMaterializationPath =
                        withdrawMaterializationPath runDir
                    , wseTreasuryMaterializedTxIn =
                        txInToText materializedRef
                    , wseTreasuryAddress = renderAddr (ttAddress target)
                    , wseMaterializedLovelace =
                        materializedLovelace
                    , wseRewardBeforeSubmit =
                        coinLovelace rewardBeforeSubmit
                    , wseRewardAfterSubmit =
                        coinLovelace rewardAfterSubmit
                    , wseTreasuryLovelaceBefore =
                        treasuryLovelaceBefore
                    , wseTreasuryLovelaceAfter =
                        treasuryLovelaceAfter
                    }
        treasuryLovelaceAfter - treasuryLovelaceBefore
            `shouldBe` coinLovelace rewards
        BSL.writeFile
            (withdrawMaterializationPath runDir)
            (encode (withdrawalMaterializationValue evidence submitted))
        pure submitted

readWithdrawalTxBuildFailure
    :: FilePath -> IO (Maybe Report.BuildFailure)
readWithdrawalTxBuildFailure runDir = do
    let path = withdrawReportJsonPath runDir
    exists <- doesFileExist path
    if not exists
        then pure Nothing
        else
            eitherDecodeFileStrict @Report.TxBuildOutput path >>= \case
                Right buildOutput ->
                    case Report.txoResult buildOutput of
                        Report.TxBuildOutputFailure failure ->
                            pure (Just failure)
                        Report.TxBuildOutputSuccess{} ->
                            pure Nothing
                Left{} -> pure Nothing

writeWithdrawalRegistryArtifacts
    :: FilePath
    -> DevnetRegistryAnchors
    -> IO ()
writeWithdrawalRegistryArtifacts runDir registry =
    BSL.writeFile
        (runDir </> "withdraw" </> "registry.json")
        ( encode $
            object
                [ "scopesDeployedAt"
                    .= txInToText (draScopesRef registry)
                , "permissionsDeployedAt"
                    .= txInToText (draPermissionsRef registry)
                , "permissionsScriptHash"
                    .= scriptHashToHex (draPermissionsHash registry)
                , "treasuryDeployedAt"
                    .= txInToText (draTreasuryRef registry)
                , "registryDeployedAt"
                    .= txInToText (draRegistryRef registry)
                , "registryPolicyId"
                    .= draRegistryPolicyId registry
                , "treasuryScriptHash"
                    .= ttScriptHashText (draTreasuryTarget registry)
                , "treasuryAddress"
                    .= renderAddr (ttAddress (draTreasuryTarget registry))
                ]
        )

devnetRegistryView
    :: DevnetRegistryAnchors
    -> Withdraw.RegistryView
devnetRegistryView registry =
    let treasuryHashText =
            ttScriptHashText (draTreasuryTarget registry)
        treasuryAddress =
            renderAddr (ttAddress (draTreasuryTarget registry))
        refs =
            Withdraw.TreasuryRefs
                { Withdraw.trAddress = treasuryAddress
                , Withdraw.trScriptHash = treasuryHashText
                , Withdraw.trPermissionsRewardAccount =
                    scriptHashToHex (draPermissionsHash registry)
                }
        owners =
            ScopeOwners
                { soCore = draOwnerKeyHash registry
                , soOps = draOwnerKeyHash registry
                , soNetworkCompliance = draOwnerKeyHash registry
                , soMiddleware = draOwnerKeyHash registry
                }
    in  Withdraw.RegistryView
            { Withdraw.rvScopesDeployedAt =
                txInToText (draScopesRef registry)
            , Withdraw.rvPermissionsDeployedAt =
                txInToText (draPermissionsRef registry)
            , Withdraw.rvTreasuryDeployedAt =
                txInToText (draTreasuryRef registry)
            , Withdraw.rvRegistryDeployedAt =
                txInToText (draRegistryRef registry)
            , Withdraw.rvRegistryPolicyId =
                draRegistryPolicyId registry
            , Withdraw.rvOwners = owners
            , Withdraw.rvTreasuryByScope =
                Map.singleton CoreDevelopment refs
            }

queryWalletUtxosForWithdraw
    :: Provider IO
    -> T.Text
    -> T.Text
    -> IO [(T.Text, Integer, Bool)]
queryWalletUtxosForWithdraw provider expectedWallet requestedWallet = do
    requestedWallet `shouldBe` expectedWallet
    utxos <- queryUTxOs provider genesisAddr
    pure
        [ (txInToText txIn, lovelace, not (Map.null assets))
        | (txIn, txOut) <- utxos
        , let MaryValue (Coin lovelace) (MultiAsset assets) =
                txOut ^. valueTxOutL
        ]

writeWithdrawalGovernancePrerequisite
    :: FilePath
    -> GovernanceEvidence
    -> IO ()
writeWithdrawalGovernancePrerequisite runDir evidence =
    BSL.writeFile
        (runDir </> "withdraw" </> "governance-prerequisite.json")
        ( encode $
            object
                [ "governanceSummaryPath"
                    .= (runDir </> "governance" </> "summary.json")
                , "rewardAccount" .= geRewardAccount evidence
                , "rewardBeforeLovelace" .= geRewardBefore evidence
                , "rewardAfterGovernanceLovelace"
                    .= geRewardAfter evidence
                , "governanceActionId" .= geActionId evidence
                ]
        )

writeWithdrawalIntentSummary
    :: FilePath
    -> FilePath
    -> ShelleyGenesisTiming
    -> GovernanceEvidence
    -> Integer
    -> IO ()
writeWithdrawalIntentSummary runDir socket timing evidence observedRewards = do
    let summary =
            withdrawalIntentSummaryValue
                runDir
                socket
                timing
                evidence
                observedRewards
    BSL.writeFile
        (runDir </> "withdraw" </> "summary.json")
        (encode summary)
    BSL.writeFile (runDir </> "summary.json") (encode summary)
    writeFile
        (runDir </> "summary.log")
        ( unlines $
            withdrawalIntentLines
                runDir
                evidence
                (Coin observedRewards)
        )

withdrawalIntentSummaryValue
    :: FilePath
    -> FilePath
    -> ShelleyGenesisTiming
    -> GovernanceEvidence
    -> Integer
    -> Value
withdrawalIntentSummaryValue runDir socket timing evidence observedRewards =
    object
        [ "phase" .= ("withdraw" :: String)
        , "status" .= ("intent-ready" :: String)
        , "runDirectory" .= runDir
        , "socket" .= socket
        , "network" .= ("devnet" :: String)
        , "networkMagic" .= sgtNetworkMagic timing
        , "epochDurationSeconds" .= epochDurationSeconds timing
        , "rewardAccount" .= geRewardAccount evidence
        , "rewardBeforeLovelace" .= geRewardBefore evidence
        , "rewardAfterGovernanceLovelace" .= geRewardAfter evidence
        , "withdrawRewardsLovelace" .= observedRewards
        , "governancePrerequisitePath"
            .= (runDir </> "withdraw" </> "governance-prerequisite.json")
        , "intentPath" .= withdrawIntentPath runDir
        , "txBodyPath" .= withdrawTxBodyPath runDir
        , "reportJsonPath" .= withdrawReportJsonPath runDir
        , "reportMarkdownPath" .= withdrawReportMarkdownPath runDir
        ]

putWithdrawalIntentLines
    :: FilePath
    -> GovernanceEvidence
    -> Coin
    -> IO ()
putWithdrawalIntentLines runDir evidence rewards =
    mapM_ putStrLn (withdrawalIntentLines runDir evidence rewards)

withdrawalIntentLines
    :: FilePath
    -> GovernanceEvidence
    -> Coin
    -> [String]
withdrawalIntentLines runDir evidence rewards =
    [ "devnet-smoke: run-dir " <> runDir
    , "devnet-smoke: phase withdraw intent-ready"
    , "devnet-smoke: reward-account " <> geRewardAccount evidence
    , "devnet-smoke: withdraw-rewards "
        <> show (coinLovelace rewards)
    , "devnet-smoke: withdraw-intent "
        <> withdrawIntentPath runDir
    ]

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

writeWithdrawalBuildSummary
    :: FilePath
    -> FilePath
    -> ShelleyGenesisTiming
    -> GovernanceEvidence
    -> Coin
    -> Report.TxBuildSuccess
    -> IO ()
writeWithdrawalBuildSummary
    runDir
    socket
    timing
    evidence
    rewards
    success = do
        let summary =
                withdrawalBuildSummaryValue
                    runDir
                    socket
                    timing
                    evidence
                    rewards
                    success
        BSL.writeFile
            (runDir </> "withdraw" </> "summary.json")
            (encode summary)
        BSL.writeFile (runDir </> "summary.json") (encode summary)
        writeFile
            (runDir </> "summary.log")
            ( unlines $
                withdrawalBuildLines runDir evidence rewards success
            )

withdrawalBuildSummaryValue
    :: FilePath
    -> FilePath
    -> ShelleyGenesisTiming
    -> GovernanceEvidence
    -> Coin
    -> Report.TxBuildSuccess
    -> Value
withdrawalBuildSummaryValue runDir socket timing evidence rewards success =
    object
        [ "phase" .= ("withdraw" :: String)
        , "status" .= ("passed" :: String)
        , "runDirectory" .= runDir
        , "socket" .= socket
        , "network" .= ("devnet" :: String)
        , "networkMagic" .= sgtNetworkMagic timing
        , "epochDurationSeconds" .= epochDurationSeconds timing
        , "rewardAccount" .= geRewardAccount evidence
        , "rewardBeforeLovelace" .= geRewardBefore evidence
        , "rewardAfterGovernanceLovelace" .= geRewardAfter evidence
        , "withdrawRewardsLovelace" .= coinLovelace rewards
        , "governancePrerequisitePath"
            .= (runDir </> "withdraw" </> "governance-prerequisite.json")
        , "intentPath" .= withdrawIntentPath runDir
        , "txBodyPath" .= withdrawTxBodyPath runDir
        , "reportJsonPath" .= withdrawReportJsonPath runDir
        , "reportMarkdownPath" .= withdrawReportMarkdownPath runDir
        , "txBuildLogPath" .= withdrawTxBuildLogPath runDir
        , "upstreamCardanoNodeClientsMain"
            .= upstreamCardanoNodeClientsMain
        , "txId" .= Report.tiTxId identity
        , "bodySizeBytes" .= Report.tiBodySizeBytes identity
        , "feeLovelace" .= Report.tiFeeLovelace identity
        , "totalCollateralLovelace"
            .= Report.tiTotalCollateralLovelace identity
        , "validityInterval" .= Report.tiValidityInterval identity
        , "txCborHexLength"
            .= T.length (Report.unTxCborHex (Report.tbsTxCbor success))
        ]
  where
    identity =
        Report.trIdentity (Report.tbsReport success)

writeWithdrawalSubmittedSummary
    :: FilePath
    -> FilePath
    -> ShelleyGenesisTiming
    -> GovernanceEvidence
    -> Coin
    -> Report.TxBuildSuccess
    -> WithdrawalSubmissionEvidence
    -> IO ()
writeWithdrawalSubmittedSummary
    runDir
    socket
    timing
    evidence
    rewards
    success
    submitted = do
        let summary =
                withdrawalSubmittedSummaryValue
                    runDir
                    socket
                    timing
                    evidence
                    rewards
                    success
                    submitted
        BSL.writeFile
            (runDir </> "withdraw" </> "summary.json")
            (encode summary)
        BSL.writeFile (runDir </> "summary.json") (encode summary)
        writeFile
            (runDir </> "summary.log")
            ( unlines $
                withdrawalSubmittedLines
                    runDir
                    evidence
                    rewards
                    success
                    submitted
            )

withdrawalSubmittedSummaryValue
    :: FilePath
    -> FilePath
    -> ShelleyGenesisTiming
    -> GovernanceEvidence
    -> Coin
    -> Report.TxBuildSuccess
    -> WithdrawalSubmissionEvidence
    -> Value
withdrawalSubmittedSummaryValue
    runDir
    socket
    timing
    evidence
    rewards
    success
    submitted =
        object
            [ "phase" .= ("withdraw" :: String)
            , "status" .= ("passed" :: String)
            , "runDirectory" .= runDir
            , "socket" .= socket
            , "network" .= ("devnet" :: String)
            , "networkMagic" .= sgtNetworkMagic timing
            , "epochDurationSeconds" .= epochDurationSeconds timing
            , "rewardAccount" .= geRewardAccount evidence
            , "rewardBeforeLovelace" .= geRewardBefore evidence
            , "rewardAfterGovernanceLovelace" .= geRewardAfter evidence
            , "withdrawRewardsLovelace" .= coinLovelace rewards
            , "governancePrerequisitePath"
                .= (runDir </> "withdraw" </> "governance-prerequisite.json")
            , "intentPath" .= withdrawIntentPath runDir
            , "txBodyPath" .= withdrawTxBodyPath runDir
            , "reportJsonPath" .= withdrawReportJsonPath runDir
            , "reportMarkdownPath" .= withdrawReportMarkdownPath runDir
            , "txBuildLogPath" .= withdrawTxBuildLogPath runDir
            , "signedTxPath" .= wseSignedTxPath submitted
            , "submitLogPath" .= wseSubmitLogPath submitted
            , "materializationPath" .= wseMaterializationPath submitted
            , "upstreamCardanoNodeClientsMain"
                .= upstreamCardanoNodeClientsMain
            , "txId" .= Report.tiTxId identity
            , "bodySizeBytes" .= Report.tiBodySizeBytes identity
            , "feeLovelace" .= Report.tiFeeLovelace identity
            , "totalCollateralLovelace"
                .= Report.tiTotalCollateralLovelace identity
            , "validityInterval" .= Report.tiValidityInterval identity
            , "txCborHexLength"
                .= T.length (Report.unTxCborHex (Report.tbsTxCbor success))
            , "submittedTxAccepted" .= True
            , "submittedTxId" .= wseSubmittedTxId submitted
            , "treasuryMaterializedTxIn"
                .= wseTreasuryMaterializedTxIn submitted
            , "treasuryAddress" .= wseTreasuryAddress submitted
            , "materialized" .= True
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
      where
        identity =
            Report.trIdentity (Report.tbsReport success)

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

putWithdrawalBuildLines
    :: FilePath
    -> GovernanceEvidence
    -> Coin
    -> Report.TxBuildSuccess
    -> IO ()
putWithdrawalBuildLines runDir evidence rewards success =
    mapM_ putStrLn (withdrawalBuildLines runDir evidence rewards success)

withdrawalBuildLines
    :: FilePath
    -> GovernanceEvidence
    -> Coin
    -> Report.TxBuildSuccess
    -> [String]
withdrawalBuildLines runDir evidence rewards success =
    [ "devnet-smoke: run-dir " <> runDir
    , "devnet-smoke: phase withdraw passed"
    , "devnet-smoke: reward-account " <> geRewardAccount evidence
    , "devnet-smoke: withdraw-rewards "
        <> show (coinLovelace rewards)
    , "devnet-smoke: withdraw-tx-id "
        <> T.unpack (Report.tiTxId identity)
    , "devnet-smoke: withdraw-fee "
        <> show (Report.tiFeeLovelace identity)
    , "devnet-smoke: withdraw-tx-body "
        <> withdrawTxBodyPath runDir
    , "devnet-smoke: withdraw-report-json "
        <> withdrawReportJsonPath runDir
    , "devnet-smoke: withdraw-report-md "
        <> withdrawReportMarkdownPath runDir
    ]
  where
    identity =
        Report.trIdentity (Report.tbsReport success)

putWithdrawalSubmittedLines
    :: FilePath
    -> GovernanceEvidence
    -> Coin
    -> Report.TxBuildSuccess
    -> WithdrawalSubmissionEvidence
    -> IO ()
putWithdrawalSubmittedLines runDir evidence rewards success submitted =
    mapM_ putStrLn $
        withdrawalSubmittedLines runDir evidence rewards success submitted

withdrawalSubmittedLines
    :: FilePath
    -> GovernanceEvidence
    -> Coin
    -> Report.TxBuildSuccess
    -> WithdrawalSubmissionEvidence
    -> [String]
withdrawalSubmittedLines runDir evidence rewards success submitted =
    withdrawalBuildLines runDir evidence rewards success
        <> [ "devnet-smoke: withdraw-signed-tx "
                <> wseSignedTxPath submitted
           , "devnet-smoke: withdraw-submitted-tx-id "
                <> T.unpack (wseSubmittedTxId submitted)
           , "devnet-smoke: withdraw-materialized-tx-in "
                <> T.unpack (wseTreasuryMaterializedTxIn submitted)
           , "devnet-smoke: withdraw-materialized-ada "
                <> show (wseMaterializedLovelace submitted)
           , "devnet-smoke: withdraw-reward-after-submit "
                <> show (wseRewardAfterSubmit submitted)
           , "devnet-smoke: withdraw-materialization "
                <> wseMaterializationPath submitted
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

resolveRunDir :: IO FilePath
resolveRunDir = do
    explicit <- lookupEnv "DEVNET_SMOKE_RUN_DIR"
    case explicit of
        Just p -> makeAbsolute p
        Nothing -> do
            cwd <- getCurrentDirectory
            stamp <- utcStamp
            pure (cwd </> "dist-newstyle" </> "devnet-smoke" </> stamp)

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
