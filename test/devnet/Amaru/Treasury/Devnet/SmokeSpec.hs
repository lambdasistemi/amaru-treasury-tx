{-# LANGUAGE DataKinds #-}
{-# LANGUAGE EmptyCase #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

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
import Cardano.Ledger.Address
    ( AccountAddress (..)
    , AccountId (..)
    , Addr (..)
    )
import Cardano.Ledger.Alonzo.Scripts
    ( fromPlutusScript
    , mkPlutusScript
    )
import Cardano.Ledger.Api.Tx (txIdTx)
import Cardano.Ledger.Api.Tx.Out (TxOut)
import Cardano.Ledger.BaseTypes
    ( Inject (..)
    , Network (..)
    , StrictMaybe (SNothing)
    , textToUrl
    )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Conway.Governance (Anchor (..))
import Cardano.Ledger.Core (PParams, Script)
import Cardano.Ledger.Credential
    ( Credential (..)
    , StakeReference (..)
    )
import Cardano.Ledger.Hashes
    ( unsafeMakeSafeHash
    )
import Cardano.Ledger.Keys
    ( KeyHash
    , KeyRole (DRepRole, Payment, Staking)
    , VKey (..)
    , hashKey
    )
import Cardano.Ledger.Plutus.Language
    ( Language (PlutusV3)
    , Plutus (..)
    , PlutusBinary (..)
    )
import Cardano.Ledger.TxIn (TxId, TxIn (..))
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
import Cardano.Node.Client.TxBuild
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
    , collateral
    , payTo
    , proposeTreasuryWithdrawal
    , registerAndVoteAbstain
    , spend
    , validTo
    , vote
    )
import Cardano.Slotting.Slot (SlotNo (..))
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (poll, withAsync)
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
import Data.ByteString.Short qualified as SBS
import Data.Foldable (traverse_)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromJust, fromMaybe)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Data.Void (Void)
import Data.Word (Word64, Word8)
import System.Directory
    ( copyFile
    , createDirectoryIfMissing
    , doesDirectoryExist
    , doesFileExist
    , getCurrentDirectory
    , listDirectory
    , makeAbsolute
    )
import System.Environment (lookupEnv)
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
import Amaru.Treasury.Redeemer
    ( RawPlutusData (..)
    , emptyListRedeemer
    )
import Amaru.Treasury.Registry.Derive
    ( derivedTreasuryScriptBlob
    , derivedTreasuryScriptHash
    , scriptHashToHex
    )
import Amaru.Treasury.Scope
    ( ScopeId (CoreDevelopment)
    )

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
        it
            "node: starts cardano-node-clients devnet and records short-epoch timing evidence"
            (runForPhases ["node", "all"] nodeSmoke)
        it
            "governance: funds the treasury script reward account"
            (runForPhases ["governance", "all"] governanceSmoke)
        it
            "withdraw: refuses without governance prerequisite evidence"
            (runForPhases ["withdraw"] withdrawSmoke)

runForPhases :: [String] -> IO () -> IO ()
runForPhases accepted action = do
    phase <- fromMaybe "node" <$> lookupEnv "DEVNET_SMOKE_PHASE"
    when (phase `elem` accepted) action

governanceSmoke :: IO ()
governanceSmoke = do
    runDir <- resolveRunDir
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
            evidence <-
                submitTreasuryWithdrawal
                    provider
                    submitter
                    pp
                    utxos
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
    let govSummaryPath =
            runDir </> "governance" </> "summary.json"
    createDirectoryIfMissing True (runDir </> "withdraw")
    hasGovernance <- doesFileExist govSummaryPath
    unless hasGovernance $ do
        message <-
            writeWithdrawalFailure
                runDir
                (MissingGovernancePrerequisite govSummaryPath)
        intentExists <-
            doesFileExist (withdrawIntentPath runDir)
        txBodyExists <-
            doesFileExist (withdrawTxBodyPath runDir)
        intentExists `shouldBe` False
        txBodyExists `shouldBe` False
        expectationFailure message

data GovernancePrerequisiteFailure
    = MissingGovernancePrerequisite !FilePath
    | StaleGovernancePrerequisite !FilePath !String
    deriving stock (Eq, Show)

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

submitTreasuryWithdrawal
    :: Provider IO
    -> Submitter IO
    -> PParams ConwayEra
    -> [(TxIn, TxOut ConwayEra)]
    -> IO GovernanceEvidence
submitTreasuryWithdrawal provider submitter pp utxos = do
    seed@(seedIn, _) <- case utxos of
        u : _ -> pure u
        [] -> fail "no genesis UTxOs"

    treasuryScript <-
        scriptFromBlob
            =<< expectEither
                "derive treasury script"
                (derivedTreasuryScriptBlob CoreDevelopment)
    treasuryHash <-
        expectEither
            "derive treasury script hash"
            (derivedTreasuryScriptHash CoreDevelopment)
    buildSnapshot <- queryLedgerSnapshot provider
    let treasuryHashText =
            scriptHashToHex treasuryHash
        upperSlot =
            addSlots 20 (ledgerTipSlot buildSnapshot)
        treasuryCredential =
            ScriptHashObj treasuryHash
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
            attachScript treasuryScript
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
    build pp interpret eval [seed] [] genesisAddr prog
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
            pp
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

writeWithdrawalFailure
    :: FilePath
    -> GovernancePrerequisiteFailure
    -> IO String
writeWithdrawalFailure runDir failure = do
    let withdrawDir = runDir </> "withdraw"
        message = governancePrerequisiteFailureMessage failure
        value = withdrawalFailureValue runDir failure
        linesOut = withdrawalFailureLines runDir message
    createDirectoryIfMissing True withdrawDir
    BSL.writeFile (withdrawDir </> "failure.json") (encode value)
    BSL.writeFile (withdrawDir </> "summary.json") (encode value)
    BSL.writeFile (runDir </> "summary.json") (encode value)
    writeFile (runDir </> "summary.log") (unlines linesOut)
    mapM_ putStrLn linesOut
    pure message

withdrawalFailureValue
    :: FilePath
    -> GovernancePrerequisiteFailure
    -> Value
withdrawalFailureValue runDir failure =
    object
        [ "phase" .= ("withdraw" :: String)
        , "status" .= ("failed" :: String)
        , "code" .= governancePrerequisiteFailureCode failure
        , "message" .= governancePrerequisiteFailureMessage failure
        , "runDirectory" .= runDir
        , "governanceSummaryPath"
            .= governancePrerequisiteFailurePath failure
        , "intentPath" .= withdrawIntentPath runDir
        , "txBodyPath" .= withdrawTxBodyPath runDir
        , "reportJsonPath" .= (runDir </> "withdraw" </> "report.json")
        , "reportMarkdownPath" .= (runDir </> "withdraw" </> "report.md")
        , "withdrawSummaryPath"
            .= (runDir </> "withdraw" </> "summary.json")
        , "lastObservedRewardLovelace" .= (Nothing :: Maybe Integer)
        , "epoch" .= (Nothing :: Maybe Word64)
        , "tipSlot" .= (Nothing :: Maybe Word64)
        ]

withdrawalFailureLines :: FilePath -> String -> [String]
withdrawalFailureLines runDir message =
    [ "devnet-smoke: run-dir " <> runDir
    , "devnet-smoke: phase withdraw failed"
    , "devnet-smoke: " <> message
    , "devnet-smoke: failure "
        <> (runDir </> "withdraw" </> "failure.json")
    ]

governancePrerequisiteFailureCode
    :: GovernancePrerequisiteFailure -> String
governancePrerequisiteFailureCode = \case
    MissingGovernancePrerequisite{} ->
        "missing-governance-prerequisite"
    StaleGovernancePrerequisite{} ->
        "stale-governance-prerequisite"

governancePrerequisiteFailureMessage
    :: GovernancePrerequisiteFailure -> String
governancePrerequisiteFailureMessage = \case
    MissingGovernancePrerequisite path ->
        "missing governance prerequisite evidence: " <> path
    StaleGovernancePrerequisite path reason ->
        "stale governance prerequisite evidence: "
            <> path
            <> ": "
            <> reason

governancePrerequisiteFailurePath
    :: GovernancePrerequisiteFailure -> FilePath
governancePrerequisiteFailurePath = \case
    MissingGovernancePrerequisite path -> path
    StaleGovernancePrerequisite path _ -> path

withdrawIntentPath :: FilePath -> FilePath
withdrawIntentPath runDir =
    runDir </> "withdraw" </> "intent.json"

withdrawTxBodyPath :: FilePath -> FilePath
withdrawTxBodyPath runDir =
    runDir </> "withdraw" </> "tx-body.cbor.hex"

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
