{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

{- |
Module      : Amaru.Treasury.Build.SwapRerateSpec
Description : ChainContext-backed swap re-rate build runner tests
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0
-}
module Amaru.Treasury.Build.SwapRerateSpec (spec) where

import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as BSL
import Data.ByteString.Short qualified as SBS
import Data.Foldable (toList)
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    , shouldSatisfy
    , shouldThrow
    )

import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Alonzo.Scripts
    ( fromPlutusScript
    , mkPlutusScript
    )
import Cardano.Ledger.Api.Era (eraProtVerLow)
import Cardano.Ledger.Api.Tx.Body
    ( inputsTxBodyL
    , outputsTxBodyL
    , referenceInputsTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , addrTxOutL
    , datumTxOutL
    , mkBasicTxOut
    , referenceScriptTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.BaseTypes (Network (..), StrictMaybe (..))
import Cardano.Ledger.Binary
    ( DecCBOR (..)
    , decodeFullAnnotator
    )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (Script, bodyTxL)
import Cardano.Ledger.Core qualified as Core
import Cardano.Ledger.Credential
    ( Credential (..)
    , StakeReference (..)
    )
import Cardano.Ledger.Hashes (KeyHash, ScriptHash)
import Cardano.Ledger.Keys (KeyRole (..))
import Cardano.Ledger.Mary.Value
    ( MaryValue (..)
    , MultiAsset (..)
    )
import Cardano.Ledger.Plutus.Data
    ( Datum (..)
    , binaryDataToData
    , getPlutusData
    )
import Cardano.Ledger.Plutus.Language
    ( Language (PlutusV2)
    , Plutus (..)
    , PlutusBinary (..)
    )
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Tx.Ledger (ConwayTx)
import Lens.Micro ((&), (.~), (^.))
import PlutusCore.Data (Data)

import Amaru.Treasury.Build.Common (validateFinalPhase1)
import Amaru.Treasury.Build.Error
    ( BuildDiagnostic (..)
    , BuildError (..)
    , BuildException (..)
    , BuildFailurePhase (..)
    )
import Amaru.Treasury.Build.Result
    ( BuildResult (..)
    , ScriptResult (..)
    )
import Amaru.Treasury.Build.SwapRerate (runSwapRerate)
import Amaru.Treasury.ChainContext (ChainContext (..))
import Amaru.Treasury.ChainContext.Fixture
    ( readSwapFixture
    , toFrozenContext
    )
import Amaru.Treasury.Constants
    ( sundaeOrderScriptHashMainnet
    )
import Amaru.Treasury.IntentJSON
    ( SAction (..)
    , SomeTreasuryIntent (..)
    , decodeTreasuryIntentFile
    , translateIntent
    )
import Amaru.Treasury.IntentJSON.Common
    ( parseGuardKeyHash
    , parseTxIn
    )
import Amaru.Treasury.LedgerParse
    ( scriptHashFromHex
    )
import Amaru.Treasury.Scope (ScopeId (..))
import Amaru.Treasury.Sundae.Contracts (sundaeOrderValidatorBlob)
import Amaru.Treasury.Swap.Rerate
    ( RerateProgramInputs (..)
    )
import Amaru.Treasury.Swap.Rerate.Plan (planRerate)
import Amaru.Treasury.Swap.Rerate.Types
    ( PlannedRerate (..)
    , PlannedRerateOrder (..)
    , RerateIntent (..)
    , RerateOrder (..)
    , RerateScopeContext (..)
    )
import Amaru.Treasury.Tx.Swap
    ( SwapIntent (..)
    , SwapOrderDatumParams (..)
    )

data RerateFixture = RerateFixture
    { rfContext :: !ChainContext
    , rfInputs :: !RerateProgramInputs
    , rfIntent :: !RerateIntent
    , rfOrderTxIn :: !TxIn
    , rfOrderScriptRef :: !TxIn
    , rfExpectedOrder :: !PlannedRerateOrder
    }

spec :: Spec
spec = describe "Amaru.Treasury.Build.SwapRerate" $ do
    it "wraps the Sundae order script as PlutusV2" $ do
        orderScript <- orderScriptFromBlob sundaeOrderValidatorBlob
        expectedHash <-
            expectRightIO $
                scriptHashFromHex sundaeOrderScriptHashMainnet
        Core.hashScript @ConwayEra orderScript `shouldBe` expectedHash

    it "reports missing required UTxOs before balancing" $ do
        fixture <- rerateFixture
        let ctx =
                (rfContext fixture)
                    { ccUtxos =
                        Map.delete
                            (rfOrderScriptRef fixture)
                            (ccUtxos (rfContext fixture))
                    }
        runSwapRerate
            ctx
            (rfInputs fixture)
            (rfIntent fixture)
            `shouldThrow` missingOrderScriptRef fixture

    it "builds a phase-1-valid re-rate body from a frozen context" $ do
        fixture <- rerateFixture
        result <-
            runSwapRerate
                (rfContext fixture)
                (rfInputs fixture)
                (rfIntent fixture)
        brCborBytes result `shouldSatisfy` (not . BSL.null)
        brWalletInputs result `shouldSatisfy` (not . null)
        brCollateralInput result `shouldSatisfy` isJust
        brWalletChangeOutput result `shouldSatisfy` isJust
        brScriptResults result `shouldSatisfy` (not . null)
        brScriptResults result `shouldSatisfy` allScriptsSucceeded

        tx <- expectRightIO (decodeFinalTx result)
        validateFinalPhase1 (rfContext fixture) tx `shouldBe` Right ()
        assertRerateBody fixture result

    it "accounts for extra wallet fuel as wallet inputs" $ do
        fixture <- rerateFixture
        extraWalletTxIn <- expectRightIO $ parseTxIn syntheticExtraWalletTxIn
        let walletHead = rpiWalletTxIn (rfInputs fixture)
            walletHeadOut = ccUtxos (rfContext fixture) Map.! walletHead
            ctx =
                (rfContext fixture)
                    { ccUtxos =
                        Map.insert
                            extraWalletTxIn
                            walletHeadOut
                            (ccUtxos (rfContext fixture))
                    }
            inputs =
                (rfInputs fixture)
                    { rpiExtraWalletTxIns = [extraWalletTxIn]
                    }
        result <- runSwapRerate ctx inputs (rfIntent fixture)
        fmap fst (brWalletInputs result)
            `shouldBe` [walletHead, extraWalletTxIn]
        brFinalTxBody result
            ^. inputsTxBodyL
            `shouldBe` Set.fromList
                [ walletHead
                , extraWalletTxIn
                , rfOrderTxIn fixture
                ]
        fmap fst (brCollateralInput result) `shouldBe` Just walletHead

decodeFinalTx :: BuildResult -> Either String ConwayTx
decodeFinalTx result =
    case decodeFullAnnotator
        (eraProtVerLow @ConwayEra)
        "ConwayTx"
        decCBOR
        (brCborBytes result) of
        Right tx -> Right tx
        Left err -> Left (show err)

missingOrderScriptRef :: RerateFixture -> BuildException -> Bool
missingOrderScriptRef fixture (BuildException BuildError{bePhase, beDiagnostic}) =
    bePhase == BuildPhaseGatherInputs
        && case beDiagnostic of
            DiagnosticMissingUtxos missing ->
                showTxInText (rfOrderScriptRef fixture) `elem` missing
            _ -> False

assertRerateBody :: RerateFixture -> BuildResult -> IO ()
assertRerateBody fixture result = do
    let body = brFinalTxBody result
        inputs = body ^. inputsTxBodyL
        refs = body ^. referenceInputsTxBodyL
    inputs
        `shouldBe` Set.fromList
            [ rpiWalletTxIn (rfInputs fixture)
            , rfOrderTxIn fixture
            ]
    refs
        `shouldBe` Set.fromList
            [ rpiOrderScriptRef (rfInputs fixture)
            , rpiScopesDeployedAt (rfInputs fixture)
            , rpiPermissionsDeployedAt (rfInputs fixture)
            , rpiTreasuryDeployedAt (rfInputs fixture)
            , rpiRegistryDeployedAt (rfInputs fixture)
            ]
    case brSundaeOrderOutputs result of
        [(0, out)] -> do
            out ^. valueTxOutL
                `shouldBe` proReplacementValue (rfExpectedOrder fixture)
            inlineDatumData out
                `shouldBe` Just
                    (proReplacementDatum (rfExpectedOrder fixture))
        other ->
            expectationFailure $
                "expected one replacement order output, got: " <> show (length other)
    case toList (body ^. outputsTxBodyL) of
        _replacement : treasuryReturn : _change -> do
            treasuryReturn
                ^. addrTxOutL
                `shouldBe` rpiTreasuryAddress (rfInputs fixture)
            treasuryReturn
                ^. valueTxOutL
                `shouldBe` proOriginalValue (rfExpectedOrder fixture)
        outputs ->
            expectationFailure $
                "expected replacement, treasury return, and change outputs, got: "
                    <> show (length outputs)

rerateFixture :: IO RerateFixture
rerateFixture = do
    swapIntent <- fixtureSwapIntent
    base <- toFrozenContext <$> readSwapFixture "test/fixtures/swap"
    orderTxIn <- expectRightIO $ parseTxIn syntheticOrderTxIn
    orderOut0 <- firstSwapOrderOutput
    orderDatum <- case inlineDatumData orderOut0 of
        Just datum -> pure datum
        Nothing ->
            expectationFailure "fixture swap order has no inline datum"
                *> error "unreachable"
    orderScriptRef <- expectRightIO $ parseTxIn syntheticOrderScriptRef
    orderScript <- orderScriptFromBlob sundaeOrderValidatorBlob
    let orderAddress =
            scriptAddr
                Mainnet
                (Core.hashScript @ConwayEra orderScript)
        orderOut = orderOut0 & addrTxOutL .~ orderAddress
    let intent =
            RerateIntent
                { riScopeContext = scopeContext swapIntent
                , riOrders =
                    [ RerateOrder
                        { rroTxIn = orderTxIn
                        , rroScope = NetworkCompliance
                        , rroValue = orderOut ^. valueTxOutL
                        , rroDatum = orderDatum
                        }
                    ]
                , riRateNumerator = 3
                , riRateDenominator = 10
                }
        planned = expectRight $ planRerate intent
        ctx =
            base
                { ccUtxos =
                    Map.insert
                        orderScriptRef
                        (refScriptTxOut orderAddress orderScript)
                        ( Map.insert
                            orderTxIn
                            orderOut
                            (ccUtxos base)
                        )
                }
        inputs =
            RerateProgramInputs
                { rpiWalletTxIn = siWalletUtxo swapIntent
                , rpiExtraWalletTxIns = []
                , rpiOrderScriptRef = orderScriptRef
                , rpiSwapOrderAddress = orderAddress
                , rpiTreasuryAddress = siTreasuryAddress swapIntent
                , rpiPermissionsRewardAccount =
                    siPermissionsRewardAccount swapIntent
                , rpiScopesDeployedAt = siScopesDeployedAt swapIntent
                , rpiPermissionsDeployedAt =
                    siPermissionsDeployedAt swapIntent
                , rpiTreasuryDeployedAt = siTreasuryDeployedAt swapIntent
                , rpiRegistryDeployedAt = siRegistryDeployedAt swapIntent
                , rpiUpperBound = siUpperBound swapIntent
                }
    case prOrders planned of
        [expectedOrder] ->
            pure
                RerateFixture
                    { rfContext = ctx
                    , rfInputs = inputs
                    , rfIntent = intent
                    , rfOrderTxIn = orderTxIn
                    , rfOrderScriptRef = orderScriptRef
                    , rfExpectedOrder = expectedOrder
                    }
        other ->
            expectationFailure
                ("expected one planned order, got: " <> show (length other))
                *> error "unreachable"

fixtureSwapIntent :: IO SwapIntent
fixtureSwapIntent = do
    some <- expectRightIO =<< decodeTreasuryIntentFile swapIntentPath
    case some of
        SomeTreasuryIntent SSwap typed -> do
            (_, swapIntent) <- expectRightIO $ translateIntent SSwap typed
            pure swapIntent
        other ->
            expectationFailure ("expected swap intent, got: " <> show other)
                *> error "unreachable"

firstSwapOrderOutput :: IO (TxOut ConwayEra)
firstSwapOrderOutput = do
    tx <-
        expectRightIO . decodeHexConwayTx =<< BS.readFile swapExpectedCbor
    case listToMaybe (toList (tx ^. bodyTxL . outputsTxBodyL)) of
        Just out -> pure out
        Nothing ->
            expectationFailure "swap fixture transaction has no outputs"
                *> error "unreachable"

decodeHexConwayTx :: BS.ByteString -> Either String ConwayTx
decodeHexConwayTx rawHex = do
    raw <- case B16.decode (BS.filter (/= 10) rawHex) of
        Right bytes -> Right (BSL.fromStrict bytes)
        Left err -> Left err
    case decodeFullAnnotator
        (eraProtVerLow @ConwayEra)
        "ConwayTx"
        decCBOR
        raw of
        Right tx -> Right tx
        Left err -> Left (show err)

scopeContext :: SwapIntent -> RerateScopeContext
scopeContext swapIntent =
    RerateScopeContext
        { rscScope = NetworkCompliance
        , rscExpectedOwners = expectRight fixtureOwnerKeys
        , rscTreasuryScriptHash = expectRight fixtureTreasuryScriptHash
        , rscOrderExtraLovelace = siSwapOrderExtraLovelace swapIntent
        , rscDatumParams = fixtureDatumParams
        }

fixtureDatumParams :: SwapOrderDatumParams
fixtureDatumParams =
    SwapOrderDatumParams
        { sodPoolId =
            "64f35d26b237ad58e099041bc14c687ea7fdc58969d7d5b66e2540ef"
        , sodCoreOwner =
            expectRight $
                hexBytes
                    "7095faf3d48d582fbae8b3f2e726670d7a35e2400c783d992bbdeffb"
        , sodOpsOwner =
            expectRight $
                hexBytes
                    "f3ab64b0f97dcf0f91232754603283df5d75a1201337432c04d23e2e"
        , sodNetworkComplianceOwner =
            expectRight $
                hexBytes
                    "8bd03209d227956aaf9670751e0aa2057b51c1537a43f155b24fb1c1"
        , sodMiddlewareOwner =
            expectRight $
                hexBytes
                    "97e0f6d6c86dbebf15cc8fdf0981f939b2f2b70928a46511edd49df2"
        , sodSundaeProtocolFeeLovelace = 1_280_000
        , sodTreasuryScriptHash =
            expectRight $
                hexBytes
                    "32201dc1e82708364c6c42a53f89f675314bb9ad5da2734aa10baa0d"
        , sodUsdmPolicy =
            "c48cbb3d5e57ed56e276bc45f99ab39abe94e6cd7ac39fb402da47ad"
        , sodUsdmToken = "0014df105553444d"
        }

fixtureOwnerKeys :: Either String [KeyHash Guard]
fixtureOwnerKeys =
    traverse
        parseGuardKeyHash
        [ "7095faf3d48d582fbae8b3f2e726670d7a35e2400c783d992bbdeffb"
        , "f3ab64b0f97dcf0f91232754603283df5d75a1201337432c04d23e2e"
        , "8bd03209d227956aaf9670751e0aa2057b51c1537a43f155b24fb1c1"
        , "97e0f6d6c86dbebf15cc8fdf0981f939b2f2b70928a46511edd49df2"
        ]

fixtureTreasuryScriptHash :: Either String ScriptHash
fixtureTreasuryScriptHash =
    scriptHashFromHex
        "32201dc1e82708364c6c42a53f89f675314bb9ad5da2734aa10baa0d"

hexBytes :: Text -> Either String BS.ByteString
hexBytes t =
    case B16.decode (TE.encodeUtf8 t) of
        Right bytes -> Right bytes
        Left err -> Left err

inlineDatumData :: TxOut ConwayEra -> Maybe Data
inlineDatumData out =
    case out ^. datumTxOutL of
        Datum datum -> Just $ getPlutusData (binaryDataToData datum)
        _ -> Nothing

orderScriptFromBlob :: BS.ByteString -> IO (Script ConwayEra)
orderScriptFromBlob blob =
    case mkPlutusScript plutus of
        Just script -> pure (fromPlutusScript script)
        Nothing ->
            expectationFailure "failed to build Plutus script"
                *> error "unreachable"
  where
    plutus =
        Plutus @PlutusV2 (PlutusBinary (SBS.toShort blob))

refScriptTxOut :: Addr -> Script ConwayEra -> TxOut ConwayEra
refScriptTxOut addr script =
    mkBasicTxOut addr (MaryValue (Coin 2_000_000) (MultiAsset Map.empty))
        & referenceScriptTxOutL .~ SJust script

scriptAddr :: Network -> ScriptHash -> Addr
scriptAddr network scriptHash =
    Addr
        network
        (ScriptHashObj scriptHash)
        (StakeRefBase (ScriptHashObj scriptHash))

allScriptsSucceeded :: [ScriptResult] -> Bool
allScriptsSucceeded =
    all $ \case
        ScriptResult{srOutcome = Right _} -> True
        ScriptResult{srOutcome = Left _} -> False

showTxInText :: TxIn -> Text
showTxInText = T.pack . show

isJust :: Maybe a -> Bool
isJust (Just _) = True
isJust Nothing = False

expectRightIO :: (Show e) => Either e a -> IO a
expectRightIO =
    either
        (errorWithoutStackTrace . ("unexpected Left: " <>) . show)
        pure

expectRight :: (Show e) => Either e a -> a
expectRight =
    either
        (errorWithoutStackTrace . ("unexpected Left: " <>) . show)
        id

swapIntentPath :: FilePath
swapIntentPath = "test/fixtures/swap/intent.json"

swapExpectedCbor :: FilePath
swapExpectedCbor = "test/fixtures/swap/expected.cbor"

syntheticOrderTxIn :: Text
syntheticOrderTxIn =
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa#0"

syntheticOrderScriptRef :: Text
syntheticOrderScriptRef =
    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb#0"

syntheticExtraWalletTxIn :: Text
syntheticExtraWalletTxIn =
    "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc#1"
