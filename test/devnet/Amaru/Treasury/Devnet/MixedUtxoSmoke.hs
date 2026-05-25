{-# LANGUAGE DataKinds #-}
{-# LANGUAGE EmptyCase #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Amaru.Treasury.Devnet.MixedUtxoSmoke
    ( mixedUtxoSmoke
    )
where

import Cardano.Crypto.DSIGN
    ( Ed25519DSIGN
    , SignKeyDSIGN
    , deriveVerKeyDSIGN
    , rawSerialiseSignKeyDSIGN
    )
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
import Cardano.Ledger.Api.Tx.Body (outputsTxBodyL)
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
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose)
import Cardano.Ledger.Core (PParams, Script)
import Cardano.Ledger.Core qualified as Core
import Cardano.Ledger.Credential
    ( Credential (..)
    , StakeReference (..)
    )
import Cardano.Ledger.Hashes (KeyHash, ScriptHash)
import Cardano.Ledger.Keys
    ( KeyRole (Payment)
    , VKey (..)
    , hashKey
    )
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.Metadata (Metadatum)
import Cardano.Ledger.Plutus.ExUnits (ExUnits)
import Cardano.Ledger.Plutus.Language
    ( Language (PlutusV3)
    , Plutus (..)
    , PlutusBinary (..)
    )
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Cardano.Node.Client.E2E.Devnet (withCardanoNode)
import Cardano.Node.Client.E2E.Setup
    ( addKeyWitness
    , devnetMagic
    , genesisAddr
    , genesisDir
    , genesisSignKey
    )
import Cardano.Node.Client.N2C.Connection
    ( newLSQChannel
    , newLTxSChannel
    , runNodeClient
    )
import Cardano.Node.Client.N2C.Provider (mkN2CProvider)
import Cardano.Node.Client.N2C.Submitter (mkN2CSubmitter)
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
    ( InterpretIO (..)
    , TxBuild
    , attachScript
    , build
    , collateral
    , mint
    , mkPParamsBound
    , payTo
    , spend
    , validTo
    )
import Cardano.Tx.Ledger (ConwayTx)
import Codec.Binary.Bech32 qualified as Bech32
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (poll, withAsync)
import Control.Monad (unless, when)
import Control.Monad.Trans.Except (runExceptT)
import Data.Aeson
    ( FromJSON (..)
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
import Data.Foldable (toList, traverse_)
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Data.Void (Void)
import Data.Word (Word64)
import Lens.Micro ((^.))
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
import System.FilePath (takeDirectory, (</>))
import System.Posix.Files
    ( ownerReadMode
    , setFileMode
    )
import Test.Hspec
    ( expectationFailure
    , shouldBe
    )

import Amaru.Treasury.AuxData
    ( RationaleBody (..)
    , rationaleMetadatum
    )
import Amaru.Treasury.Backend.N2C
    ( probeNetworkMagic
    )
import Amaru.Treasury.Build.Reorganize
    ( runReorganizeAction
    )
import Amaru.Treasury.Build.Result
    ( BuildResult (..)
    , ScriptResult (..)
    )
import Amaru.Treasury.Build.Swap
    ( runSwapAction
    )
import Amaru.Treasury.ChainContext
    ( withLiveContext
    )
import Amaru.Treasury.Cli.Common
    ( GlobalOpts (..)
    )
import Amaru.Treasury.Constants
    ( nativeAssetMinUtxoDepositLovelace
    )
import Amaru.Treasury.Devnet.RegistryInit
    ( DevnetRegistryAnchors (..)
    , TreasuryTarget (..)
    )
import Amaru.Treasury.Devnet.RegistryInit qualified as RegistryInit
import Amaru.Treasury.Devnet.Runner
    ( DevnetStakeRewardInitOpts (..)
    , runDevnetStakeRewardInit
    )
import Amaru.Treasury.IntentJSON.Common
    ( parseGuardKeyHash
    )
import Amaru.Treasury.Redeemer
    ( RawPlutusData (..)
    , emptyListRedeemer
    )
import Amaru.Treasury.Tx.Reorganize
    ( ReorganizeIntent (..)
    )
import Amaru.Treasury.Tx.Swap
    ( SwapIntent (..)
    , SwapOrderDatumParams (..)
    , SwapOrderOut (..)
    , swapOrderDatum
    )
import Amaru.Treasury.Tx.SwapWizard (txInToText)

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

data NoCtx a

data MixedAsset = MixedAsset
    { maPolicy :: !PolicyID
    , maAssetName :: !AssetName
    }

mixedUtxoSmoke :: IO ()
mixedUtxoSmoke = do
    runDir <- resolveRunDir
    prepareRunDir runDir
    createDirectoryIfMissing True (runDir </> "mixed-utxo")

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
        withGovernanceNode socket $ \provider submitter -> do
            pp <- queryProtocolParams provider
            utxos <- queryUTxOs provider genesisAddr
            publication <-
                RegistryInit.publishDevnetRegistryInit
                    (mixedRegistryConfig genesisAddr)
                    provider
                    submitter
                    pp
                    utxos
            RegistryInit.writeRegistryInitArtifacts
                (sgtNetworkMagic timing)
                runDir
                publication
            let registryPath =
                    RegistryInit.registryInitRegistryPath runDir
                fundingAddress =
                    T.unpack (renderAddr genesisAddr)
                globals =
                    GlobalOpts
                        { goSocketPath = Just socket
                        , goNetworkMagic = devnetMagic
                        , goNetworkName = Just "devnet"
                        }
                anchors =
                    RegistryInit.drpAnchors publication
            runDevnetStakeRewardInit
                globals
                DevnetStakeRewardInitOpts
                    { dsrioRegistryFile = registryPath
                    , dsrioFundingAddress = fundingAddress
                    , dsrioSigningKeyFile = signingKeyFile
                    , dsrioRunDir = runDir
                    }
            fundingUtxos <- queryUTxOs provider genesisAddr
            (reorganizeInput, swapInput, mixedAsset) <-
                fundMixedTreasuryUtxos
                    provider
                    submitter
                    pp
                    (draTreasuryTarget anchors)
                    fundingUtxos
            walletUtxos <- queryUTxOs provider genesisAddr
            walletInput <-
                selectLargestAdaUtxo "mixed treasury validator fuel" walletUtxos
            verifyMixedReorganize
                provider
                anchors
                walletInput
                reorganizeInput
                swapInput
                mixedAsset
            verifyMixedSwap
                provider
                anchors
                walletInput
                swapInput
                mixedAsset

mixedRegistryConfig :: Addr -> RegistryInit.DevnetRegistryInitConfig
mixedRegistryConfig fundingAddress =
    RegistryInit.DevnetRegistryInitConfig
        { RegistryInit.dricNetwork = Testnet
        , RegistryInit.dricFundingAddress = fundingAddress
        , RegistryInit.dricOwnerKeyHash =
            paymentKeyHashFromSignKey genesisSignKey
        , RegistryInit.dricSignTx =
            addKeyWitness genesisSignKey
        }

fundMixedTreasuryUtxos
    :: Provider IO
    -> Submitter IO
    -> PParams ConwayEra
    -> TreasuryTarget
    -> [(TxIn, TxOut ConwayEra)]
    -> IO
        ( (TxIn, TxOut ConwayEra)
        , (TxIn, TxOut ConwayEra)
        , MixedAsset
        )
fundMixedTreasuryUtxos provider submitter pp target utxos = do
    seed@(seedIn, _) <-
        selectLargestAdaUtxo "mixed treasury funding" utxos
    snapshot <- queryLedgerSnapshot provider
    let tokenScript =
            alwaysTrueScript
        policy =
            PolicyID (Core.hashScript @ConwayEra tokenScript)
        assetName =
            AssetName (SBS.toShort "MIXED")
        asset =
            MixedAsset policy assetName
        upperSlot =
            addSlots 20 (ledgerTipSlot snapshot)
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
            attachScript tokenScript
            mint
                policy
                (Map.singleton assetName 300)
                (RawPlutusData emptyListRedeemer)
            _ <-
                payTo
                    (ttAddress target)
                    (mixedValue 20_000_000 asset 100)
            _ <-
                payTo
                    (ttAddress target)
                    (mixedValue 20_000_000 asset 200)
            validTo upperSlot
    txId <-
        buildSubmitAndWait
            "fund mixed treasury UTxOs"
            provider
            submitter
            pp
            interpret
            eval
            [seed]
            []
            genesisAddr
            prog
    found <- waitForTxIns provider [txOutRef txId 0, txOutRef txId 1] 60
    case found of
        [first, second] -> do
            assertMixedTreasuryValue
                "mixed treasury funding output #0"
                (ttAddress target)
                asset
                100
                first
            assertMixedTreasuryValue
                "mixed treasury funding output #1"
                (ttAddress target)
                asset
                200
                second
            pure (first, second, asset)
        _ ->
            expectationFailure "mixed treasury funding outputs not found"
                *> error "unreachable"

verifyMixedReorganize
    :: Provider IO
    -> DevnetRegistryAnchors
    -> (TxIn, TxOut ConwayEra)
    -> (TxIn, TxOut ConwayEra)
    -> (TxIn, TxOut ConwayEra)
    -> MixedAsset
    -> IO ()
verifyMixedReorganize provider anchors walletInput firstTreasuryInput secondTreasuryInput asset = do
    snapshot <- queryLedgerSnapshot provider
    signer <-
        expectEither
            "mixed reorganize owner signer"
            (parseGuardKeyHash (draOwnerKeyHash anchors))
    let walletRef = fst walletInput
        firstTreasuryRef = fst firstTreasuryInput
        secondTreasuryRef = fst secondTreasuryInput
        target = draTreasuryTarget anchors
        needed =
            Set.fromList
                [ walletRef
                , firstTreasuryRef
                , secondTreasuryRef
                , draScopesRef anchors
                , draPermissionsRef anchors
                , draTreasuryRef anchors
                , draRegistryRef anchors
                ]
        intent =
            ReorganizeIntent
                { rgiWalletUtxo = walletRef
                , rgiTreasuryUtxos = firstTreasuryRef :| [secondTreasuryRef]
                , rgiTreasuryAddress = ttAddress target
                , rgiTreasuryDeployedAt = draTreasuryRef anchors
                , rgiRegistryDeployedAt = draRegistryRef anchors
                , rgiPermissionsRewardAccount =
                    permissionsRewardAccount anchors
                , rgiPermissionsDeployedAt = draPermissionsRef anchors
                , rgiScopesDeployedAt = draScopesRef anchors
                , rgiScopeOwnerSigner = signer
                , rgiUpperBound = addSlots 20 (ledgerTipSlot snapshot)
                , rgiSplitNativeAssets = True
                }
    withLiveContext Testnet provider needed $ \ctx -> do
        result <-
            runExceptT $
                runReorganizeAction
                    ctx
                    intent
                    (mixedRationale "reorganize")
                    genesisAddr
        buildResult <- case result of
            Left err ->
                expectationFailure
                    ("mixed reorganize build failed: " <> show err)
                    *> error "unreachable"
            Right ok -> pure ok
        assertScriptResultsOk "mixed reorganize" buildResult
        let outputs = toList (brFinalTxBody buildResult ^. outputsTxBodyL)
        case outputs of
            pureTreasury : nativeTreasury : _ -> do
                pureTreasury ^. addrTxOutL `shouldBe` ttAddress target
                nativeTreasury ^. addrTxOutL `shouldBe` ttAddress target
                txOutValue pureTreasury
                    `shouldBe` MaryValue
                        ( Coin
                            ( 40_000_000
                                - nativeAssetMinUtxoDepositLovelace
                            )
                        )
                        (MultiAsset Map.empty)
                txOutValue nativeTreasury
                    `shouldBe` mixedValue
                        nativeAssetMinUtxoDepositLovelace
                        asset
                        300
            _ ->
                expectationFailure
                    "mixed reorganize did not produce two treasury outputs"

verifyMixedSwap
    :: Provider IO
    -> DevnetRegistryAnchors
    -> (TxIn, TxOut ConwayEra)
    -> (TxIn, TxOut ConwayEra)
    -> MixedAsset
    -> IO ()
verifyMixedSwap provider anchors walletInput treasuryInput asset = do
    snapshot <- queryLedgerSnapshot provider
    signer <-
        expectEither
            "mixed swap owner signer"
            (parseGuardKeyHash (draOwnerKeyHash anchors))
    let walletRef = fst walletInput
        treasuryRef = fst treasuryInput
        target = draTreasuryTarget anchors
        chunkLovelace = 14_414_000
        extraLovelace = 3_280_000
        leftoverLovelace = nativeAssetMinUtxoDepositLovelace
        needed =
            Set.fromList
                [ walletRef
                , treasuryRef
                , draScopesRef anchors
                , draPermissionsRef anchors
                , draTreasuryRef anchors
                , draRegistryRef anchors
                ]
        intent =
            SwapIntent
                { siWalletUtxo = walletRef
                , siExtraWalletInputs = []
                , siSwapOrderAddress =
                    scriptAddr Testnet (ttScriptHash target)
                , siSwapOrders =
                    [ SwapOrderOut
                        (Coin chunkLovelace)
                        (swapOrderDatum mixedSwapDatumParams chunkLovelace 1)
                    ]
                , siSwapOrderExtraLovelace = Coin extraLovelace
                , siTreasuryUtxos = [treasuryRef]
                , siTreasuryAddress = ttAddress target
                , siTreasuryLeftoverLovelace = Coin leftoverLovelace
                , siTreasuryLeftoverAssets = MultiAsset Map.empty
                , siRedeemerAmountLovelace = Coin chunkLovelace
                , siPermissionsRewardAccount =
                    permissionsRewardAccount anchors
                , siScopesDeployedAt = draScopesRef anchors
                , siPermissionsDeployedAt = draPermissionsRef anchors
                , siTreasuryDeployedAt = draTreasuryRef anchors
                , siRegistryDeployedAt = draRegistryRef anchors
                , siSigners = [signer]
                , siUpperBound = addSlots 20 (ledgerTipSlot snapshot)
                }
    withLiveContext Testnet provider needed $ \ctx -> do
        result <-
            runExceptT $
                runSwapAction
                    ctx
                    intent
                    (mixedRationale "swap")
                    walletRef
                    genesisAddr
        buildResult <- case result of
            Left err ->
                expectationFailure
                    ("mixed swap build failed: " <> show err)
                    *> error "unreachable"
            Right ok -> pure ok
        assertScriptResultsOk "mixed swap" buildResult
        case brTreasuryLeftoverOutput buildResult of
            Just (_, txOut) -> do
                txOut ^. addrTxOutL `shouldBe` ttAddress target
                txOutValue txOut
                    `shouldBe` mixedValue leftoverLovelace asset 200
            Nothing ->
                expectationFailure "mixed swap did not produce treasury leftover"

assertScriptResultsOk :: String -> BuildResult -> IO ()
assertScriptResultsOk label buildResult = do
    let results = brScriptResults buildResult
    when (null results) $
        expectationFailure (label <> " did not evaluate any scripts")
    traverse_
        ( \scriptResult ->
            case srOutcome scriptResult of
                Right{} -> pure ()
                Left err ->
                    expectationFailure $
                        label
                            <> " phase-2 failed for "
                            <> show (srPurpose scriptResult)
                            <> ": "
                            <> err
        )
        results

assertMixedTreasuryValue
    :: String
    -> Addr
    -> MixedAsset
    -> Integer
    -> (TxIn, TxOut ConwayEra)
    -> IO ()
assertMixedTreasuryValue _label expectedAddress asset expectedQuantity (_, txOut) = do
    txOut ^. addrTxOutL `shouldBe` expectedAddress
    txOutLovelace txOut `shouldBe` 20_000_000
    assetQuantity asset (txOutValue txOut)
        `shouldBe` expectedQuantity

permissionsRewardAccount :: DevnetRegistryAnchors -> AccountAddress
permissionsRewardAccount anchors =
    AccountAddress
        Testnet
        (AccountId (ScriptHashObj (draPermissionsHash anchors)))

mixedValue :: Integer -> MixedAsset -> Integer -> MaryValue
mixedValue lovelace asset quantity =
    MaryValue
        (Coin lovelace)
        ( singleAsset
            (maPolicy asset)
            (maAssetName asset)
            quantity
        )

singleAsset :: PolicyID -> AssetName -> Integer -> MultiAsset
singleAsset policy asset quantity =
    MultiAsset $
        Map.singleton policy $
            Map.singleton asset quantity

assetQuantity :: MixedAsset -> MaryValue -> Integer
assetQuantity asset (MaryValue _ (MultiAsset assets)) =
    Map.findWithDefault 0 (maAssetName asset) $
        Map.findWithDefault Map.empty (maPolicy asset) assets

txOutValue :: TxOut ConwayEra -> MaryValue
txOutValue txOut =
    txOut ^. valueTxOutL

txOutLovelace :: TxOut ConwayEra -> Integer
txOutLovelace txOut =
    let MaryValue (Coin lovelace) _ = txOutValue txOut
    in  lovelace

mixedRationale :: T.Text -> Metadatum
mixedRationale action =
    rationaleMetadatum
        RationaleBody
            { rbEvent = "mixed-utxo-devnet"
            , rbLabel = "mixed treasury " <> action
            , rbReferences = []
            , rbDescription =
                [ "Devnet phase-2 smoke for mixed treasury UTxOs."
                ]
            , rbDestinationLabel = "devnet treasury"
            , rbJustification =
                [ "Issue #291 requires native assets to survive treasury spends."
                ]
            }
        (BS.replicate 28 0)

mixedSwapDatumParams :: SwapOrderDatumParams
mixedSwapDatumParams =
    SwapOrderDatumParams
        { sodPoolId = "devnet-mixed-pool"
        , sodCoreOwner = "core"
        , sodOpsOwner = "ops"
        , sodNetworkComplianceOwner = "network"
        , sodMiddlewareOwner = "middleware"
        , sodSundaeProtocolFeeLovelace = 1_280_000
        , sodTreasuryScriptHash = "treasury"
        , sodUsdmPolicy = "policy"
        , sodUsdmToken = "MIXED"
        }

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

alwaysTrueScript :: Script ConwayEra
alwaysTrueScript =
    let bytes =
            either error id $
                B16.decode (BS8.filter (/= '\n') alwaysTrueHex)
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

scriptAddr :: Network -> ScriptHash -> Addr
scriptAddr network scriptHash =
    Addr
        network
        (ScriptHashObj scriptHash)
        (StakeRefBase (ScriptHashObj scriptHash))

txOutRef :: TxId -> Integer -> TxIn
txOutRef txId ix =
    TxIn txId (mkTxIxPartial ix)

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
        expectationFailure $
            "timed out waiting for tx change output: " <> show txId
waitForTxChange provider txId addr attempts = do
    utxos <- queryUTxOs provider addr
    if any (hasTxId txId . fst) utxos
        then pure ()
        else do
            threadDelay 500_000
            waitForTxChange provider txId addr (attempts - 1)

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

hasTxId :: TxId -> TxIn -> Bool
hasTxId txId (TxIn utxoTxId _) =
    txId == utxoTxId

addSlots :: Word64 -> SlotNo -> SlotNo
addSlots delta (SlotNo slot) =
    SlotNo (slot + delta)

paymentKeyHashFromSignKey
    :: SignKeyDSIGN Ed25519DSIGN
    -> KeyHash Payment
paymentKeyHashFromSignKey =
    hashKey
        . VKey
        . deriveVerKeyDSIGN

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

expectEither :: String -> Either String a -> IO a
expectEither label =
    either
        ( \err ->
            expectationFailure (label <> ": " <> err)
                *> error "unreachable"
        )
        pure

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
            ( object
                [ "network" .= ("devnet" :: String)
                , "networkMagic" .= sgtNetworkMagic timing
                , "epochLength" .= sgtEpochLength timing
                , "slotLengthSeconds" .= sgtSlotLength timing
                , "epochDurationSeconds"
                    .= ( fromIntegral (sgtEpochLength timing)
                            * sgtSlotLength timing
                       )
                , "systemStartMs" .= startMs
                , "socket" .= socket
                ]
            )
        )

utcStamp :: IO FilePath
utcStamp =
    formatTime defaultTimeLocale "%Y%m%dT%H%M%SZ"
        <$> getCurrentTime
