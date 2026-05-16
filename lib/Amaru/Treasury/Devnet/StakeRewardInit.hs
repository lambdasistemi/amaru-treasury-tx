{-# LANGUAGE EmptyCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

{- |
Module      : Amaru.Treasury.Devnet.StakeRewardInit
Description : DevNet stake/reward account setup
License     : Apache-2.0

Production-backed setup for the DevNet treasury script reward account
and permissions reward-account handoff. The registry-init artifact
supplies the deployed script anchors; this module owns the setup
transaction and the operator-facing artifacts for the stake/reward
phase.
-}
module Amaru.Treasury.Devnet.StakeRewardInit
    ( -- * Configuration and registry handoff
      DevnetStakeRewardInitConfig (..)
    , DevnetStakeRewardRegistry (..)
    , readDevnetStakeRewardRegistry

      -- * Results and diagnostics
    , DevnetStakeRewardAccount (..)
    , DevnetStakeRewardInitResult (..)
    , StakeRewardInitDiagnostic (..)
    , StakeRewardInitFailure (..)
    , StakeRewardInitFailureStep (..)

      -- * Setup
    , setupDevnetStakeRewards
    , stakeRewardSetupProgram

      -- * Artifacts
    , stakeRewardInitSummaryPath
    , stakeRewardInitAccountsPath
    , stakeRewardInitProvenancePath
    , stakeRewardInitFailurePath
    , stakeRewardInitSummaryValue
    , stakeRewardInitAccountsValue
    , stakeRewardInitProvenanceValue
    , stakeRewardInitFailureValue
    , stakeRewardInitCommandLines
    , writeStakeRewardInitArtifacts
    , writeStakeRewardInitArtifactsWithLines
    ) where

import Cardano.Ledger.Address
    ( AccountAddress (..)
    , AccountId (..)
    , Addr
    )
import Cardano.Ledger.Api.Tx (txIdTx)
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , referenceScriptTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.BaseTypes
    ( Network (..)
    , StrictMaybe (..)
    )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (PParams, ppKeyDepositL)
import Cardano.Ledger.Core qualified as Core
import Cardano.Ledger.Credential (Credential (..))
import Cardano.Ledger.Hashes (ScriptHash)
import Cardano.Ledger.Keys (KeyRole (Staking))
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..))
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
import Cardano.Tx.Build
    ( CertWitness (..)
    , ConwayDelegCert (..)
    , ConwayTxCert (..)
    , DRep (..)
    , Delegatee (..)
    , InterpretIO (..)
    , TxBuild
    , build
    , certify
    , collateral
    , mkPParamsBound
    , reference
    , spend
    , validTo
    )
import Cardano.Tx.Ledger (ConwayTx)
import Control.Concurrent (threadDelay)
import Control.Exception (throwIO)
import Control.Monad (unless)
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
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as BSL
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Void (Void)
import Data.Word (Word64)
import Lens.Micro ((^.))
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))

import Amaru.Treasury.LedgerParse
    ( scriptHashFromHex
    , txInFromText
    )
import Amaru.Treasury.Redeemer
    ( RawPlutusData (..)
    , emptyListRedeemer
    )
import Amaru.Treasury.Registry.Derive
    ( scriptHashToHex
    )
import Amaru.Treasury.Tx.Submit (renderTxId)

data NoCtx a

-- | Live DevNet inputs needed to sign and fund setup.
data DevnetStakeRewardInitConfig = DevnetStakeRewardInitConfig
    { dsricNetwork :: !Network
    , dsricFundingAddress :: !Addr
    , dsricSignTx :: !(ConwayTx -> ConwayTx)
    }

-- | Minimal projection consumed from @registry-init/registry.json@.
data DevnetStakeRewardRegistry = DevnetStakeRewardRegistry
    { dsrrPermissionsRef :: !TxIn
    , dsrrTreasuryRef :: !TxIn
    , dsrrPermissionsScriptHash :: !ScriptHash
    , dsrrTreasuryScriptHash :: !ScriptHash
    }
    deriving stock (Eq, Show)

instance FromJSON DevnetStakeRewardRegistry where
    parseJSON = withObject "DevnetStakeRewardRegistry" $ \o -> do
        phase <- o .: "phase"
        network <- o .: "network"
        unless (phase == ("registry-init" :: T.Text)) $
            fail "expected registry-init phase"
        unless (network == ("devnet" :: T.Text)) $
            fail "expected devnet registry"
        anchors <- o .: "anchors"
        scripts <- o .: "scripts"
        permissionsRefText <- anchors .: "permissionsDeployedAt"
        treasuryRefText <- anchors .: "treasuryDeployedAt"
        permissionsHashText <- scripts .: "permissionsScriptHash"
        treasuryHashText <- scripts .: "treasuryScriptHash"
        DevnetStakeRewardRegistry
            <$> parseEitherText
                "permissionsDeployedAt"
                txInFromText
                permissionsRefText
            <*> parseEitherText "treasuryDeployedAt" txInFromText treasuryRefText
            <*> parseEitherText
                "permissionsScriptHash"
                scriptHashFromHex
                permissionsHashText
            <*> parseEitherText
                "treasuryScriptHash"
                scriptHashFromHex
                treasuryHashText

readDevnetStakeRewardRegistry
    :: FilePath -> IO (Either String DevnetStakeRewardRegistry)
readDevnetStakeRewardRegistry =
    eitherDecodeFileStrict

-- | Account projection written to @accounts.json@.
data DevnetStakeRewardAccount = DevnetStakeRewardAccount
    { dsraScriptHash :: !T.Text
    , dsraRewardAccount :: !T.Text
    , dsraLedgerNetwork :: !Network
    , dsraRegistered :: !Bool
    , dsraRewardsLovelace :: !Integer
    }
    deriving stock (Eq, Show)

-- | Submitted setup tx and resulting account projections.
data DevnetStakeRewardInitResult = DevnetStakeRewardInitResult
    { dsrirSetupTxId :: !TxId
    , dsrirTreasury :: !DevnetStakeRewardAccount
    , dsrirPermissions :: !DevnetStakeRewardAccount
    , dsrirDiagnostics :: ![StakeRewardInitDiagnostic]
    }
    deriving stock (Eq, Show)

-- | Explicit limitations or notable verification facts for this phase.
data StakeRewardInitDiagnostic
    = RewardAccountRegistrationInferredFromAcceptedTx
    | PermissionsRewardAccountAvailableForWithdrawZero
    deriving stock (Eq, Show)

data StakeRewardInitFailureStep
    = StakeRewardInitValidateInputs
    | StakeRewardInitBuild
    | StakeRewardInitSubmit
    | StakeRewardInitVerify
    deriving stock (Eq, Show)

data StakeRewardInitFailure = StakeRewardInitFailure
    { srifCode :: !T.Text
    , srifMessage :: !T.Text
    , srifFailedStep :: !StakeRewardInitFailureStep
    , srifObservedSetupTxId :: !(Maybe TxId)
    }
    deriving stock (Eq, Show)

-- | Submit one setup transaction for the treasury reward account.
setupDevnetStakeRewards
    :: DevnetStakeRewardInitConfig
    -> DevnetStakeRewardRegistry
    -> Provider IO
    -> Submitter IO
    -> PParams ConwayEra
    -> [(TxIn, TxOut ConwayEra)]
    -> IO DevnetStakeRewardInitResult
setupDevnetStakeRewards config registry provider submitter pp utxos = do
    seed <- selectLargestAdaUtxo "stake/reward setup" utxos
    refUtxos <- resolveAndVerifyRegistryRefs provider registry
    txId <-
        submitStakeRewardSetup
            config
            registry
            provider
            submitter
            pp
            seed
            refUtxos
    verifyStakeRewardSetup config registry provider txId

submitStakeRewardSetup
    :: DevnetStakeRewardInitConfig
    -> DevnetStakeRewardRegistry
    -> Provider IO
    -> Submitter IO
    -> PParams ConwayEra
    -> (TxIn, TxOut ConwayEra)
    -> [(TxIn, TxOut ConwayEra)]
    -> IO TxId
submitStakeRewardSetup
    config
    registry
    provider
    submitter
    pp
    seed@(seedIn, _)
    refUtxos = do
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
            stakeDeposit =
                pp ^. ppKeyDepositL
            treasuryCredential =
                ScriptHashObj (dsrrTreasuryScriptHash registry)
            prog :: TxBuild NoCtx Void ()
            prog =
                stakeRewardSetupProgram
                    seedIn
                    (dsrrTreasuryRef registry)
                    (dsrrPermissionsRef registry)
                    treasuryCredential
                    stakeDeposit
                    upperSlot
        build
            (mkPParamsBound pp)
            interpret
            eval
            [seed]
            refUtxos
            (dsricFundingAddress config)
            prog
            >>= \case
                Left err ->
                    throwIO . userError $
                        "stake-reward-init build: " <> show err
                Right tx -> do
                    let signed =
                            dsricSignTx config tx
                        txId =
                            txIdTx signed
                    submitTx submitter signed >>= \case
                        Submitted _ -> pure ()
                        Rejected reason ->
                            throwIO . userError $
                                "stake-reward-init rejected: "
                                    <> BS8.unpack reason
                    waitForTxChange
                        provider
                        txId
                        (dsricFundingAddress config)
                        60
                    pure txId

stakeRewardSetupProgram
    :: TxIn
    -> TxIn
    -> TxIn
    -> Credential Staking
    -> Coin
    -> SlotNo
    -> TxBuild q e ()
stakeRewardSetupProgram
    seedIn
    treasuryRef
    permissionsRef
    treasuryCredential
    stakeDeposit
    upperSlot = do
        _ <- spend seedIn
        collateral seedIn
        reference treasuryRef
        reference permissionsRef
        registerScriptRewardAccount
            treasuryCredential
            stakeDeposit
        validTo upperSlot

registerScriptRewardAccount
    :: Credential Staking -> Coin -> TxBuild q e ()
registerScriptRewardAccount credential deposit = do
    _ <-
        certify
            ( ConwayTxCertDeleg $
                ConwayRegDelegCert
                    credential
                    (DelegVote DRepAlwaysAbstain)
                    deposit
            )
            (ScriptCert (RawPlutusData emptyListRedeemer))
    pure ()

verifyStakeRewardSetup
    :: DevnetStakeRewardInitConfig
    -> DevnetStakeRewardRegistry
    -> Provider IO
    -> TxId
    -> IO DevnetStakeRewardInitResult
verifyStakeRewardSetup config registry provider txId = do
    let treasuryAccount =
            accountFromScriptHash
                (dsricNetwork config)
                (dsrrTreasuryScriptHash registry)
        permissionsAccount =
            accountFromScriptHash
                (dsricNetwork config)
                (dsrrPermissionsScriptHash registry)
    rewards <-
        queryRewardAccounts
            provider
            (Set.fromList [treasuryAccount, permissionsAccount])
    pure
        DevnetStakeRewardInitResult
            { dsrirSetupTxId = txId
            , dsrirTreasury =
                accountProjection
                    True
                    treasuryAccount
                    (dsrrTreasuryScriptHash registry)
                    rewards
            , dsrirPermissions =
                accountProjection
                    False
                    permissionsAccount
                    (dsrrPermissionsScriptHash registry)
                    rewards
            , dsrirDiagnostics =
                [ RewardAccountRegistrationInferredFromAcceptedTx
                , PermissionsRewardAccountAvailableForWithdrawZero
                ]
            }

resolveAndVerifyRegistryRefs
    :: Provider IO
    -> DevnetStakeRewardRegistry
    -> IO [(TxIn, TxOut ConwayEra)]
resolveAndVerifyRegistryRefs provider registry = do
    let refs =
            [ dsrrPermissionsRef registry
            , dsrrTreasuryRef registry
            ]
    found <- queryUTxOByTxIn provider (Set.fromList refs)
    let missing =
            filter (`Map.notMember` found) refs
    unless (null missing) $
        throwIO . userError $
            "stake-reward-init missing registry reference UTxOs: "
                <> show missing
    verifyReferenceScript
        found
        "permissions"
        (dsrrPermissionsRef registry)
        (dsrrPermissionsScriptHash registry)
    verifyReferenceScript
        found
        "treasury"
        (dsrrTreasuryRef registry)
        (dsrrTreasuryScriptHash registry)
    pure
        [ (ref, found Map.! ref)
        | ref <- refs
        ]

verifyReferenceScript
    :: Map.Map TxIn (TxOut ConwayEra)
    -> String
    -> TxIn
    -> ScriptHash
    -> IO ()
verifyReferenceScript found label ref expectedHash =
    case Map.lookup ref found of
        Nothing ->
            throwIO . userError $
                "stake-reward-init missing "
                    <> label
                    <> " reference script UTxO"
        Just txOut ->
            case txOut ^. referenceScriptTxOutL of
                SJust script ->
                    unless (Core.hashScript @ConwayEra script == expectedHash) $
                        throwIO . userError $
                            "stake-reward-init "
                                <> label
                                <> " reference script hash mismatch"
                SNothing ->
                    throwIO . userError $
                        "stake-reward-init "
                            <> label
                            <> " UTxO has no reference script"

accountProjection
    :: Bool
    -> AccountAddress
    -> ScriptHash
    -> Map.Map AccountAddress Coin
    -> DevnetStakeRewardAccount
accountProjection registered account scriptHash rewards =
    DevnetStakeRewardAccount
        { dsraScriptHash = scriptHashToHex scriptHash
        , dsraRewardAccount = scriptHashToHex scriptHash
        , dsraLedgerNetwork = accountNetwork account
        , dsraRegistered = registered
        , dsraRewardsLovelace = coinLovelace rewardCoin
        }
  where
    rewardCoin =
        Map.findWithDefault (Coin 0) account rewards

accountFromScriptHash :: Network -> ScriptHash -> AccountAddress
accountFromScriptHash network scriptHash =
    AccountAddress network (AccountId (ScriptHashObj scriptHash))

accountNetwork :: AccountAddress -> Network
accountNetwork (AccountAddress network _) =
    network

stakeRewardInitDirectory :: FilePath -> FilePath
stakeRewardInitDirectory runDir =
    runDir </> "stake-reward-init"

stakeRewardInitSummaryPath :: FilePath -> FilePath
stakeRewardInitSummaryPath runDir =
    stakeRewardInitDirectory runDir </> "summary.json"

stakeRewardInitAccountsPath :: FilePath -> FilePath
stakeRewardInitAccountsPath runDir =
    stakeRewardInitDirectory runDir </> "accounts.json"

stakeRewardInitProvenancePath :: FilePath -> FilePath
stakeRewardInitProvenancePath runDir =
    stakeRewardInitDirectory runDir </> "provenance.json"

stakeRewardInitFailurePath :: FilePath -> FilePath
stakeRewardInitFailurePath runDir =
    stakeRewardInitDirectory runDir </> "failure.json"

stakeRewardInitSummaryValue
    :: Int
    -> FilePath
    -> FilePath
    -> DevnetStakeRewardInitResult
    -> Value
stakeRewardInitSummaryValue networkMagic runDir registryPath result =
    object
        [ "phase" .= ("stake-reward-init" :: T.Text)
        , "network" .= ("devnet" :: T.Text)
        , "networkMagic" .= networkMagic
        , "registryPath" .= registryPath
        , "setupTxId" .= renderTxId (dsrirSetupTxId result)
        , "accountsPath" .= stakeRewardInitAccountsPath runDir
        , "provenancePath" .= stakeRewardInitProvenancePath runDir
        ]

stakeRewardInitAccountsValue
    :: DevnetStakeRewardInitResult -> Value
stakeRewardInitAccountsValue result =
    object
        [ "phase" .= ("stake-reward-init" :: T.Text)
        , "network" .= ("devnet" :: T.Text)
        , "accounts"
            .= object
                [ "treasury" .= accountValue (dsrirTreasury result)
                , "permissions" .= accountValue (dsrirPermissions result)
                ]
        ]

stakeRewardInitProvenanceValue :: Value
stakeRewardInitProvenanceValue =
    object
        [ "phase" .= ("stake-reward-init" :: T.Text)
        , "source" .= ("amaru-treasury-tx" :: T.Text)
        , "issue" .= (148 :: Int)
        , "parentIssue" .= (151 :: Int)
        , "dependsOnIssue" .= (147 :: Int)
        ]

stakeRewardInitFailureValue
    :: FilePath -> StakeRewardInitFailure -> Value
stakeRewardInitFailureValue runDir failure =
    object
        [ "phase" .= ("stake-reward-init" :: T.Text)
        , "code" .= srifCode failure
        , "message" .= srifMessage failure
        , "failedStep" .= failureStepText (srifFailedStep failure)
        , "observedTxIds"
            .= object
                [ "setup" .= fmap renderTxId (srifObservedSetupTxId failure)
                ]
        , "summaryPath" .= stakeRewardInitFailurePath runDir
        ]

stakeRewardInitCommandLines
    :: Int -> FilePath -> DevnetStakeRewardInitResult -> [String]
stakeRewardInitCommandLines networkMagic runDir result =
    [ "stake-reward-init: run-dir " <> runDir
    , "stake-reward-init: network devnet magic " <> show networkMagic
    , "stake-reward-init: phase stake-reward-init passed"
    , "stake-reward-init: setup-tx-id "
        <> T.unpack (renderTxId (dsrirSetupTxId result))
    , "stake-reward-init: treasury-reward-account "
        <> T.unpack (dsraRewardAccount (dsrirTreasury result))
    , "stake-reward-init: permissions-reward-account "
        <> T.unpack (dsraRewardAccount (dsrirPermissions result))
    , "stake-reward-init: summary "
        <> stakeRewardInitSummaryPath runDir
    , "stake-reward-init: accounts "
        <> stakeRewardInitAccountsPath runDir
    ]

writeStakeRewardInitArtifacts
    :: Int
    -> FilePath
    -> FilePath
    -> DevnetStakeRewardInitResult
    -> IO ()
writeStakeRewardInitArtifacts networkMagic runDir registryPath result =
    writeStakeRewardInitArtifactsWithLines
        networkMagic
        runDir
        registryPath
        result
        (stakeRewardInitCommandLines networkMagic runDir result)

writeStakeRewardInitArtifactsWithLines
    :: Int
    -> FilePath
    -> FilePath
    -> DevnetStakeRewardInitResult
    -> [String]
    -> IO ()
writeStakeRewardInitArtifactsWithLines
    networkMagic
    runDir
    registryPath
    result
    linesOut = do
        let summary =
                stakeRewardInitSummaryValue
                    networkMagic
                    runDir
                    registryPath
                    result
        createDirectoryIfMissing True (stakeRewardInitDirectory runDir)
        BSL.writeFile (stakeRewardInitSummaryPath runDir) (encode summary)
        BSL.writeFile
            (stakeRewardInitAccountsPath runDir)
            (encode (stakeRewardInitAccountsValue result))
        BSL.writeFile
            (stakeRewardInitProvenancePath runDir)
            (encode stakeRewardInitProvenanceValue)
        BSL.writeFile (runDir </> "summary.json") (encode summary)
        writeFile
            (runDir </> "summary.log")
            (unlines linesOut)

accountValue :: DevnetStakeRewardAccount -> Value
accountValue account =
    object
        [ "scriptHash" .= dsraScriptHash account
        , "rewardAccount" .= dsraRewardAccount account
        , "ledgerNetwork" .= networkText (dsraLedgerNetwork account)
        , "registered" .= dsraRegistered account
        , "rewardsLovelace" .= dsraRewardsLovelace account
        ]

failureStepText :: StakeRewardInitFailureStep -> T.Text
failureStepText = \case
    StakeRewardInitValidateInputs -> "validate-inputs"
    StakeRewardInitBuild -> "build"
    StakeRewardInitSubmit -> "submit"
    StakeRewardInitVerify -> "verify"

networkText :: Network -> T.Text
networkText = \case
    Mainnet -> "Mainnet"
    Testnet -> "Testnet"

coinLovelace :: Coin -> Integer
coinLovelace (Coin lovelace) =
    lovelace

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
        throwIO . userError $
            "timed out waiting for stake-reward-init tx change output: "
                <> show txId
waitForTxChange provider txId addr attempts = do
    utxos <- queryUTxOs provider addr
    if any (hasTxId txId . fst) utxos
        then pure ()
        else do
            threadDelay 500_000
            waitForTxChange provider txId addr (attempts - 1)

hasTxId :: TxId -> TxIn -> Bool
hasTxId txId txIn =
    txId == txInTxId txIn

txInTxId :: TxIn -> TxId
txInTxId = \case
    TxIn txId _ -> txId

addSlots :: Word64 -> SlotNo -> SlotNo
addSlots delta (SlotNo slot) =
    SlotNo (slot + delta)

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
