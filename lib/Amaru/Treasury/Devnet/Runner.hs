{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

{- |
Module      : Amaru.Treasury.Devnet.Runner
Description : DevNet bootstrap IO runners
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Relocation target for the four DevNet bootstrap IO drivers and
their option records, originally hosted alongside the retired
@devnet@ supercommand parser under the @Cli@ tree. The
@optparse-applicative@ supercommand has been dropped (#157); the
runners survive here as a library entry point for the DevNet smoke
suite and any future direct caller. There is no
@Options.Applicative@ dependency in this module — callers are
expected to construct the @DevnetXxxOpts@ records directly.

Each runner is still gated to @--network devnet@ via the
preserved @requireDevnet*Network@ predicates, so accidental
mainnet/preprod use aborts before any key material is read or
any node connection is opened.
-}
module Amaru.Treasury.Devnet.Runner
    ( DevnetDisburseSubmitOpts (..)
    , DevnetGovernanceWithdrawalInitOpts (..)
    , DevnetRegistryInitOpts (..)
    , DevnetStakeRewardInitOpts (..)
    , registryInitCommandLines
    , runDevnetDisburseSubmit
    , runDevnetGovernanceWithdrawalInit
    , runDevnetRegistryInit
    , runDevnetStakeRewardInit
    ) where

import Control.Monad (unless)
import Data.Aeson
    ( Value
    , eitherDecodeFileStrict
    )
import Data.Text qualified as T
import Ouroboros.Network.Magic (NetworkMagic (..))
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

import Cardano.Crypto.DSIGN.Class (SignKeyDSIGN)
import Cardano.Ledger.Address (Addr, getNetwork)
import Cardano.Ledger.BaseTypes (Network (Testnet))
import Cardano.Ledger.Keys (DSIGN)
import Cardano.Node.Client.Provider (Provider (..))

import Amaru.Treasury.Backend.N2C
    ( withLocalNodeClient
    )
import Amaru.Treasury.Cli.Common
    ( GlobalOpts (..)
    , resolveSocket
    )
import Amaru.Treasury.Devnet.DisburseSubmit
    ( DevnetDisburseSubmitConfig (..)
    )
import Amaru.Treasury.Devnet.DisburseSubmit qualified as DisburseSubmit
import Amaru.Treasury.Devnet.GovernanceWithdrawalInit
    ( DevnetGovernanceWithdrawalInitConfig (..)
    )
import Amaru.Treasury.Devnet.GovernanceWithdrawalInit qualified as GovernanceWithdrawalInit
import Amaru.Treasury.Devnet.RegistryInit
    ( DevnetRegistryInitConfig (..)
    )
import Amaru.Treasury.Devnet.RegistryInit qualified as RegistryInit
import Amaru.Treasury.Devnet.StakeRewardInit
    ( DevnetStakeRewardInitConfig (..)
    )
import Amaru.Treasury.Devnet.StakeRewardInit qualified as StakeRewardInit
import Amaru.Treasury.IntentJSON.Common
    ( parseAddr
    )
import Amaru.Treasury.Tx.Submit
    ( renderTxId
    )
import Amaru.Treasury.Tx.Witness
    ( addCardanoCliPaymentKeyWitness
    , cardanoCliPaymentKeyHash
    , decodeCardanoCliSigningKey
    , renderTxWitnessError
    )

-- | Options for the DevNet @registry-init@ runner.
data DevnetRegistryInitOpts = DevnetRegistryInitOpts
    { drioFundingAddress :: !String
    , drioSigningKeyFile :: !FilePath
    , drioRunDir :: !FilePath
    }
    deriving stock (Eq, Show)

-- | Options for the DevNet @stake-reward-init@ runner.
data DevnetStakeRewardInitOpts = DevnetStakeRewardInitOpts
    { dsrioRegistryFile :: !FilePath
    , dsrioFundingAddress :: !String
    , dsrioSigningKeyFile :: !FilePath
    , dsrioRunDir :: !FilePath
    }
    deriving stock (Eq, Show)

-- | Options for the DevNet @governance-withdrawal-init@ runner.
data DevnetGovernanceWithdrawalInitOpts = DevnetGovernanceWithdrawalInitOpts
    { dgwioRegistryFile :: !FilePath
    , dgwioStakeRewardFile :: !FilePath
    , dgwioFundingAddress :: !String
    , dgwioSigningKeyFile :: !FilePath
    , dgwioRunDir :: !FilePath
    , dgwioAmountLovelace :: !Integer
    , dgwioRewardTimeoutSeconds :: !Int
    }
    deriving stock (Eq, Show)

-- | Options for the DevNet @disburse-submit@ runner.
data DevnetDisburseSubmitOpts = DevnetDisburseSubmitOpts
    { ddsioRegistryFile :: !FilePath
    , ddsioMaterializedFile :: !FilePath
    , ddsioFundingAddress :: !String
    , ddsioSigningKeyFile :: !FilePath
    , ddsioBeneficiaryAddress :: !String
    , ddsioRunDir :: !FilePath
    , ddsioAmountLovelace :: !Integer
    }
    deriving stock (Eq, Show)

-- | Validate that the global network selection is exactly DevNet.
requireDevnetRegistryInitNetwork :: GlobalOpts -> Either String ()
requireDevnetRegistryInitNetwork GlobalOpts{..}
    | goNetworkName == Just "devnet"
        && goNetworkMagic == NetworkMagic 42 =
        Right ()
    | otherwise =
        Left "registry-init: --network must be devnet"

-- | Validate that the stake/reward setup is only run on DevNet.
requireDevnetStakeRewardInitNetwork :: GlobalOpts -> Either String ()
requireDevnetStakeRewardInitNetwork GlobalOpts{..}
    | goNetworkName == Just "devnet"
        && goNetworkMagic == NetworkMagic 42 =
        Right ()
    | otherwise =
        Left "stake-reward-init: --network must be devnet"

-- | Validate that governance/withdrawal setup is only run on DevNet.
requireDevnetGovernanceWithdrawalInitNetwork
    :: GlobalOpts -> Either String ()
requireDevnetGovernanceWithdrawalInitNetwork GlobalOpts{..}
    | goNetworkName == Just "devnet"
        && goNetworkMagic == NetworkMagic 42 =
        Right ()
    | otherwise =
        Left "governance-withdrawal-init: --network must be devnet"

-- | Validate that disburse submit is only run on DevNet.
requireDevnetDisburseSubmitNetwork :: GlobalOpts -> Either String ()
requireDevnetDisburseSubmitNetwork GlobalOpts{..}
    | goNetworkName == Just "devnet"
        && goNetworkMagic == NetworkMagic 42 =
        Right ()
    | otherwise =
        Left "disburse-submit: --network must be devnet"

-- | Run the DevNet @registry-init@ flow against a local DevNet node.
runDevnetRegistryInit
    :: GlobalOpts
    -> DevnetRegistryInitOpts
    -> IO ()
runDevnetRegistryInit globals DevnetRegistryInitOpts{..} = do
    case requireDevnetRegistryInitNetwork globals of
        Left err -> abort err
        Right () -> pure ()
    fundingAddress <-
        parseFundingAddress "registry-init" drioFundingAddress
    signingKey <- readPaymentSigningKey "registry-init" drioSigningKeyFile
    socket <- resolveSocket (goSocketPath globals)
    let networkMagic =
            fromIntegral (unNetworkMagic (goNetworkMagic globals))
        config =
            DevnetRegistryInitConfig
                { dricNetwork = Testnet
                , dricFundingAddress = fundingAddress
                , dricOwnerKeyHash =
                    cardanoCliPaymentKeyHash signingKey
                , dricSignTx =
                    addCardanoCliPaymentKeyWitness signingKey
                }
    withLocalNodeClient (goNetworkMagic globals) socket $
        \provider submitter -> do
            pp <- queryProtocolParams provider
            utxos <- queryUTxOs provider fundingAddress
            publication <-
                RegistryInit.publishDevnetRegistryInit
                    config
                    provider
                    submitter
                    pp
                    utxos
            RegistryInit.verifyRegistryInitPublication
                provider
                publication
            let linesOut =
                    registryInitCommandLines
                        networkMagic
                        drioRunDir
                        ( T.unpack
                            ( renderTxId
                                (RegistryInit.drpSeedSplitTxId publication)
                            )
                        )
                        ( T.unpack
                            ( renderTxId
                                ( RegistryInit.drpRegistryMintTxId
                                    publication
                                )
                            )
                        )
                        ( T.unpack
                            ( renderTxId
                                ( RegistryInit.drpReferenceScriptsTxId
                                    publication
                                )
                            )
                        )
            RegistryInit.writeRegistryInitArtifactsWithLines
                networkMagic
                drioRunDir
                publication
                linesOut
            mapM_
                putStrLn
                linesOut

-- | Run the DevNet @stake-reward-init@ flow against a local DevNet node.
runDevnetStakeRewardInit
    :: GlobalOpts
    -> DevnetStakeRewardInitOpts
    -> IO ()
runDevnetStakeRewardInit globals DevnetStakeRewardInitOpts{..} = do
    case requireDevnetStakeRewardInitNetwork globals of
        Left err -> abort err
        Right () -> pure ()
    registry <-
        StakeRewardInit.readDevnetStakeRewardRegistry dsrioRegistryFile
            >>= \case
                Left err ->
                    abort $
                        "stake-reward-init: --registry-file: " <> err
                Right ok -> pure ok
    fundingAddress <-
        parseFundingAddress "stake-reward-init" dsrioFundingAddress
    signingKey <-
        readPaymentSigningKey
            "stake-reward-init"
            dsrioSigningKeyFile
    socket <- resolveSocket (goSocketPath globals)
    let networkMagic =
            fromIntegral (unNetworkMagic (goNetworkMagic globals))
        config =
            DevnetStakeRewardInitConfig
                { dsricNetwork = Testnet
                , dsricFundingAddress = fundingAddress
                , dsricSignTx =
                    addCardanoCliPaymentKeyWitness signingKey
                }
    withLocalNodeClient (goNetworkMagic globals) socket $
        \provider submitter -> do
            pp <- queryProtocolParams provider
            utxos <- queryUTxOs provider fundingAddress
            result <-
                StakeRewardInit.setupDevnetStakeRewards
                    config
                    registry
                    provider
                    submitter
                    pp
                    utxos
            let linesOut =
                    StakeRewardInit.stakeRewardInitCommandLines
                        networkMagic
                        dsrioRunDir
                        result
            StakeRewardInit.writeStakeRewardInitArtifactsWithLines
                networkMagic
                dsrioRunDir
                dsrioRegistryFile
                result
                linesOut
            mapM_ putStrLn linesOut

{- | Run the DevNet @governance-withdrawal-init@ flow against a local
DevNet node.
-}
runDevnetGovernanceWithdrawalInit
    :: GlobalOpts
    -> DevnetGovernanceWithdrawalInitOpts
    -> IO ()
runDevnetGovernanceWithdrawalInit
    globals
    DevnetGovernanceWithdrawalInitOpts{..} = do
        case requireDevnetGovernanceWithdrawalInitNetwork globals of
            Left err -> abort err
            Right () -> pure ()
        case GovernanceWithdrawalInit.validateGovernanceWithdrawalInitInputs
            dgwioAmountLovelace
            dgwioRewardTimeoutSeconds of
            Left failure -> do
                GovernanceWithdrawalInit.writeGovernanceWithdrawalInitFailure
                    dgwioRunDir
                    failure
                mapM_
                    (hPutStrLn stderr)
                    ( GovernanceWithdrawalInit.governanceWithdrawalInitFailureLines
                        dgwioRunDir
                        failure
                    )
                exitFailure
            Right () -> pure ()
        registry <-
            GovernanceWithdrawalInit.readDevnetGovernanceWithdrawalRegistry
                dgwioRegistryFile
                >>= \case
                    Left err ->
                        abort $
                            "governance-withdrawal-init: --registry-file: "
                                <> err
                    Right ok -> pure ok
        stakeRewardAccounts <-
            GovernanceWithdrawalInit.readDevnetGovernanceStakeRewardAccounts
                dgwioStakeRewardFile
                >>= \case
                    Left err ->
                        abort $
                            "governance-withdrawal-init: --stake-reward-file: "
                                <> err
                    Right ok -> pure ok
        prereqs <-
            case GovernanceWithdrawalInit.validateGovernanceWithdrawalPrerequisites
                registry
                stakeRewardAccounts of
                Left failure -> do
                    GovernanceWithdrawalInit.writeGovernanceWithdrawalInitFailure
                        dgwioRunDir
                        failure
                    mapM_
                        (hPutStrLn stderr)
                        ( GovernanceWithdrawalInit.governanceWithdrawalInitFailureLines
                            dgwioRunDir
                            failure
                        )
                    exitFailure
                Right ok -> pure ok
        fundingAddress <-
            parseFundingAddress
                "governance-withdrawal-init"
                dgwioFundingAddress
        signingKey <-
            readPaymentSigningKey
                "governance-withdrawal-init"
                dgwioSigningKeyFile
        socket <- resolveSocket (goSocketPath globals)
        let networkMagic =
                fromIntegral (unNetworkMagic (goNetworkMagic globals))
            config =
                DevnetGovernanceWithdrawalInitConfig
                    { dgwicNetworkMagic = networkMagic
                    , dgwicSocketPath = socket
                    , dgwicFundingAddress = fundingAddress
                    , dgwicSigningKey = signingKey
                    , dgwicRunDir = dgwioRunDir
                    , dgwicAmountLovelace = dgwioAmountLovelace
                    , dgwicRewardTimeoutSeconds =
                        dgwioRewardTimeoutSeconds
                    }
        withLocalNodeClient (goNetworkMagic globals) socket $
            \provider submitter -> do
                GovernanceWithdrawalInit.runDevnetGovernanceWithdrawalInit
                    config
                    dgwioRegistryFile
                    dgwioStakeRewardFile
                    prereqs
                    provider
                    submitter
                    >>= \case
                        Left failure -> do
                            mapM_
                                (hPutStrLn stderr)
                                ( GovernanceWithdrawalInit.governanceWithdrawalInitFailureLines
                                    dgwioRunDir
                                    failure
                                )
                            exitFailure
                        Right result -> do
                            let linesOut =
                                    GovernanceWithdrawalInit.governanceWithdrawalInitCommandLines
                                        networkMagic
                                        dgwioRunDir
                                        result
                            mapM_ putStrLn linesOut

-- | Run the DevNet @disburse-submit@ flow against a local DevNet node.
runDevnetDisburseSubmit
    :: GlobalOpts
    -> DevnetDisburseSubmitOpts
    -> IO ()
runDevnetDisburseSubmit globals DevnetDisburseSubmitOpts{..} = do
    case requireDevnetDisburseSubmitNetwork globals of
        Left err -> abort err
        Right () -> pure ()
    case DisburseSubmit.validateDisburseSubmitInputs
        ddsioAmountLovelace of
        Left failure -> do
            DisburseSubmit.writeDisburseSubmitFailure
                ddsioRunDir
                failure
            mapM_
                (hPutStrLn stderr)
                ( DisburseSubmit.disburseSubmitFailureLines
                    ddsioRunDir
                    failure
                )
            exitFailure
        Right () -> pure ()
    registry <-
        DisburseSubmit.readDevnetDisburseSubmitRegistry
            ddsioRegistryFile
            >>= \case
                Left err ->
                    abort $
                        "disburse-submit: --registry-file: "
                            <> err
                Right ok -> pure ok
    materialized <-
        DisburseSubmit.readDevnetDisburseSubmitMaterialized
            ddsioMaterializedFile
            >>= \case
                Left err ->
                    abort $
                        "disburse-submit: --materialized-file: "
                            <> err
                Right ok -> pure ok
    prereqs <-
        case DisburseSubmit.validateDisburseSubmitPrerequisites
            ddsioRegistryFile
            ddsioAmountLovelace
            registry
            materialized of
            Left failure -> do
                DisburseSubmit.writeDisburseSubmitFailure
                    ddsioRunDir
                    failure
                mapM_
                    (hPutStrLn stderr)
                    ( DisburseSubmit.disburseSubmitFailureLines
                        ddsioRunDir
                        failure
                    )
                exitFailure
            Right ok -> pure ok
    fundingAddress <-
        parseFundingAddress "disburse-submit" ddsioFundingAddress
    beneficiaryAddress <-
        parseTestnetAddress
            "disburse-submit"
            "--beneficiary-address"
            ddsioBeneficiaryAddress
    signingKey <-
        readPaymentSigningKey "disburse-submit" ddsioSigningKeyFile
    socket <- resolveSocket (goSocketPath globals)
    let networkMagic =
            fromIntegral (unNetworkMagic (goNetworkMagic globals))
        config =
            DevnetDisburseSubmitConfig
                { ddsicNetworkMagic = networkMagic
                , ddsicSocketPath = socket
                , ddsicFundingAddress = fundingAddress
                , ddsicSigningKey = signingKey
                , ddsicBeneficiaryAddress = beneficiaryAddress
                , ddsicRunDir = ddsioRunDir
                , ddsicAmountLovelace = ddsioAmountLovelace
                }
    withLocalNodeClient (goNetworkMagic globals) socket $
        \provider submitter ->
            DisburseSubmit.runDevnetDisburseSubmit
                config
                ddsioRegistryFile
                ddsioMaterializedFile
                prereqs
                provider
                submitter
                >>= \case
                    Left failure -> do
                        mapM_
                            (hPutStrLn stderr)
                            ( DisburseSubmit.disburseSubmitFailureLines
                                ddsioRunDir
                                failure
                            )
                        exitFailure
                    Right result -> do
                        let linesOut =
                                DisburseSubmit.disburseSubmitCommandLines
                                    networkMagic
                                    ddsioRunDir
                                    result
                        mapM_ putStrLn linesOut

{- | Human-readable success lines for the shipped @registry-init@
runner.
-}
registryInitCommandLines
    :: Int
    -> FilePath
    -> String
    -> String
    -> String
    -> [String]
registryInitCommandLines
    networkMagic
    runDir
    seedSplitTxId
    registryMintTxId
    referenceScriptsTxId =
        [ "registry-init: run-dir " <> runDir
        , "registry-init: network devnet magic " <> show networkMagic
        , "registry-init: phase registry-init passed"
        , "registry-init: seed-split-tx-id " <> seedSplitTxId
        , "registry-init: registry-mint-tx-id " <> registryMintTxId
        , "registry-init: reference-scripts-tx-id "
            <> referenceScriptsTxId
        , "registry-init: summary "
            <> RegistryInit.registryInitSummaryPath runDir
        , "registry-init: registry "
            <> RegistryInit.registryInitRegistryPath runDir
        ]

-- | Parse a DevNet funding address (must be a testnet address).
parseFundingAddress :: String -> String -> IO Addr
parseFundingAddress prefix =
    parseTestnetAddress prefix "--funding-address"

{- | Parse a testnet address from the given option, aborting on
non-testnet input.
-}
parseTestnetAddress :: String -> String -> String -> IO Addr
parseTestnetAddress prefix optionName raw =
    case parseAddr (T.pack raw) of
        Left err ->
            abort $
                prefix <> ": " <> optionName <> ": " <> err
        Right addr -> do
            unless (getNetwork addr == Testnet) $
                abort
                    ( prefix
                        <> ": "
                        <> optionName
                        <> " must be a testnet address"
                    )
            pure addr

-- | Read and decode a @cardano-cli@ payment signing key JSON file.
readPaymentSigningKey
    :: String
    -> FilePath
    -> IO (SignKeyDSIGN DSIGN)
readPaymentSigningKey prefix path = do
    decoded <- eitherDecodeFileStrict path :: IO (Either String Value)
    jsonValue <- case decoded of
        Left err ->
            abort $
                prefix <> ": --signing-key-file: " <> err
        Right ok -> pure ok
    case decodeCardanoCliSigningKey jsonValue of
        Left err ->
            abort $
                prefix
                    <> ": --signing-key-file: "
                    <> T.unpack (renderTxWitnessError err)
        Right signingKey -> pure signingKey

-- | Print an error message to stderr and exit with failure.
abort :: String -> IO a
abort message = do
    hPutStrLn stderr message
    exitFailure
