{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : Amaru.Treasury.Tx.DisburseWizardSpec
Description : Unit tests for the disburse wizard
License     : Apache-2.0
-}
module Amaru.Treasury.Tx.DisburseWizardSpec (spec) where

import Cardano.Crypto.Hash.Class (Hash, HashAlgorithm, hashFromBytes)
import Cardano.Ledger.BaseTypes (mkTxIxPartial)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Hashes (ScriptHash (..), unsafeMakeSafeHash)
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.ByteString.Short qualified as SBS
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromJust)
import Data.Text (Text)
import Data.Word (Word8)
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    )
import Test.QuickCheck
    ( Positive (..)
    , property
    )

import Amaru.Treasury.Constants (Unit (..))
import Amaru.Treasury.IntentJSON
    ( RationaleJSON (..)
    , RationaleReferenceJSON (..)
    , SAction (..)
    , TreasuryIntent (..)
    )
import Amaru.Treasury.Scope
    ( ScopeId (Contingency, CoreDevelopment)
    )
import Amaru.Treasury.Tx.DisburseWizard
    ( DisburseAnswers (..)
    , DisburseEnv (..)
    , DisburseTreasurySelection (..)
    , RegistryView (..)
    , ResolverEnv (..)
    , ResolverError (..)
    , ResolverInput (..)
    , ScopeOwners (..)
    , ScopeView (..)
    , disburseToTreasuryIntent
    , resolveDisburseEnv
    , selectDisburseAda
    , selectDisburseUsdm
    )
import Amaru.Treasury.Tx.SwapWizard
    ( WalletSelection (..)
    , txInToText
    , walletFeeSlackLovelace
    )

spec :: Spec
spec =
    describe "Amaru.Treasury.Tx.DisburseWizard" $ do
        it "emits a schema-v1 TreasuryIntent 'Disburse" $ do
            env <-
                eitherDecodeStrict
                    "test/fixtures/disburse-wizard/env.ada.json"
            answers <-
                eitherDecodeStrict
                    "test/fixtures/disburse-wizard/answers.ada.json"
            intent <-
                expectRight $
                    disburseToTreasuryIntent env answers
            tiSAction intent `shouldBe` SDisburse
            tiSchema intent `shouldBe` 1
            tiNetwork intent `shouldBe` "mainnet"

        it "threads Cyber Castellum references into intent rationale" $ do
            env <-
                eitherDecodeStrict
                    "test/fixtures/disburse-wizard/env.usdm.json"
            answers <-
                eitherDecodeStrict
                    "test/fixtures/disburse-wizard/answers.usdm.json"
            intent <-
                expectRight $
                    disburseToTreasuryIntent
                        env
                        answers
                            { daRationaleReferences =
                                cyberCastellumReferences
                            }
            rjReferences (tiRationale intent)
                `shouldBe` cyberCastellumReferences

        it
            "defaults contingency disburse signers to all four scope owners"
            $ do
                env <-
                    eitherDecodeStrict
                        "test/fixtures/disburse-wizard/env.ada.json"
                answers <-
                    eitherDecodeStrict
                        "test/fixtures/disburse-wizard/answers.ada.json"
                let owners = rvOwners (deRegistry env)
                    contingencyEnv =
                        env
                            { deScopeView =
                                (deScopeView env)
                                    { svScope = Contingency
                                    , svDefaultSigners = []
                                    }
                            }
                    contingencyAnswers =
                        answers
                            { daScope = Contingency
                            , daExtraSigners = []
                            }
                intent <-
                    expectRight $
                        disburseToTreasuryIntent
                            contingencyEnv
                            contingencyAnswers
                tiSigners intent
                    `shouldBe` [ soCore owners
                               , soOps owners
                               , soNetworkCompliance owners
                               , soMiddleware owners
                               ]

        describe "selectDisburseAda" $ do
            it "selects largest-first by lovelace" $ do
                let inputs =
                        [ (mkTxIn 1, mkValue 100 1 7)
                        , (mkTxIn 2, mkValue 300 2 5)
                        , (mkTxIn 3, mkValue 200 3 6)
                        ]
                selection <-
                    expectJust
                        "selectDisburseAda"
                        ( selectDisburseAda
                            usdmPolicy
                            usdmAsset
                            inputs
                            450
                        )
                dtsInputs selection
                    `shouldBe` txInToText <$> [mkTxIn 2, mkTxIn 3]
                dtsLeftoverLovelace selection `shouldBe` 50
                dtsLeftoverUsdm selection `shouldBe` 5
                dtsLeftoverOtherAssets selection
                    `shouldBe` otherAssets 11

            it "preserves selected non-USDM assets as leftover" $
                property $ \(ps :: [Positive Integer]) ->
                    let amounts = take 50 (getPositive <$> ps)
                        inputs =
                            [ (mkTxIn i, mkValue lov i' (i' + 1))
                            | (i, lov) <-
                                zip [1 ..] amounts
                            , let i' = fromIntegral i
                            ]
                        target =
                            if null amounts
                                then 0
                                else max 1 (sum amounts `div` 2)
                    in  case selectDisburseAda
                            usdmPolicy
                            usdmAsset
                            inputs
                            target of
                            Nothing -> sum amounts < target
                            Just selection ->
                                let picked =
                                        pickedValues selection inputs
                                    pickedLov =
                                        sum (lovelaceOf <$> picked)
                                    pickedUsdm =
                                        sum (assetOf usdmPolicy usdmAsset <$> picked)
                                    pickedOther =
                                        sum (assetOf otherPolicy otherAsset <$> picked)
                                in  pickedLov >= target
                                        && dtsLeftoverLovelace selection
                                            == pickedLov - target
                                        && dtsLeftoverUsdm selection
                                            == pickedUsdm
                                        && dtsLeftoverOtherAssets selection
                                            == otherAssets pickedOther

        describe "selectDisburseUsdm" $ do
            it "selects largest-first by USDM quantity" $ do
                let inputs =
                        [ (mkTxIn 1, mkValue 2_000_000 100 7)
                        , (mkTxIn 2, mkValue 3_000_000 300 5)
                        , (mkTxIn 3, mkValue 2_000_000 200 6)
                        ]
                selection <-
                    expectJust
                        "selectDisburseUsdm"
                        ( selectDisburseUsdm
                            usdmPolicy
                            usdmAsset
                            1_500_000
                            inputs
                            450
                        )
                dtsInputs selection
                    `shouldBe` txInToText <$> [mkTxIn 2, mkTxIn 3]
                dtsLeftoverLovelace selection `shouldBe` 3_500_000
                dtsLeftoverUsdm selection `shouldBe` 50
                dtsLeftoverOtherAssets selection
                    `shouldBe` otherAssets 11

            it "adds inputs until the beneficiary ADA deposit is covered" $ do
                let inputs =
                        [ (mkTxIn 1, mkValue 1_000_000 500 7)
                        , (mkTxIn 2, mkValue 1_500_000 1 5)
                        ]
                selection <-
                    expectJust
                        "selectDisburseUsdm"
                        ( selectDisburseUsdm
                            usdmPolicy
                            usdmAsset
                            2_000_000
                            inputs
                            450
                        )
                dtsInputs selection
                    `shouldBe` txInToText <$> [mkTxIn 1, mkTxIn 2]
                dtsLeftoverLovelace selection `shouldBe` 500_000
                dtsLeftoverUsdm selection `shouldBe` 51

            it "reports Nothing when selected USDM cannot cover the amount" $
                selectDisburseUsdm
                    usdmPolicy
                    usdmAsset
                    1_500_000
                    [(mkTxIn 1, mkValue 2_000_000 100 0)]
                    101
                    `shouldBe` Nothing

            it "preserves selected ADA and non-USDM assets as leftover" $
                property $ \(ps :: [Positive Integer]) ->
                    let amounts = take 50 (getPositive <$> ps)
                        beneficiaryLov = 1_500_000
                        inputs =
                            [ ( mkTxIn i
                              , mkValue
                                    (2_000_000 + usdm)
                                    usdm
                                    (i' + 1)
                              )
                            | (i, usdm) <-
                                zip [1 ..] amounts
                            , let i' = fromIntegral i
                            ]
                        target =
                            if null amounts
                                then 0
                                else max 1 (sum amounts `div` 2)
                    in  case selectDisburseUsdm
                            usdmPolicy
                            usdmAsset
                            beneficiaryLov
                            inputs
                            target of
                            Nothing ->
                                null amounts || sum amounts < target
                            Just selection ->
                                let picked =
                                        pickedValues selection inputs
                                    pickedLov =
                                        sum (lovelaceOf <$> picked)
                                    pickedUsdm =
                                        sum (assetOf usdmPolicy usdmAsset <$> picked)
                                    pickedOther =
                                        sum (assetOf otherPolicy otherAsset <$> picked)
                                in  pickedUsdm >= target
                                        && dtsLeftoverLovelace selection
                                            == pickedLov - beneficiaryLov
                                        && dtsLeftoverUsdm selection
                                            == pickedUsdm - target
                                        && dtsLeftoverOtherAssets selection
                                            == otherAssets pickedOther

        describe "resolveDisburseEnv" $ do
            it "rejects a beneficiary address on the wrong network" $ do
                env <-
                    eitherDecodeStrict
                        "test/fixtures/disburse-wizard/env.ada.json"
                let stub =
                        ResolverEnv
                            { reEnvQueryWalletUtxos =
                                \_ -> pure []
                            , reEnvQueryTreasuryUtxos =
                                \_ -> pure []
                            , reEnvComputeUpperBound = \_ -> pure (Right 0)
                            }
                    ri =
                        ResolverInput
                            { riNetwork = "mainnet"
                            , riWalletAddrBech32 =
                                wsAddress (deWalletSelection env)
                            , riBeneficiaryAddrBech32 =
                                "addr_test1q802wxt6cg6aw0nl0vdzfxavu65rxu3yzhvgayw7chfxymduzkt66uw9t5kspx5jwjecx80dz4g33htknafhdhkvzd5st4f9xu"
                            , riScope = CoreDevelopment
                            , riUnit = USDM
                            , riAmount = 1
                            , riRegistry = deRegistry env
                            , riValidityHours = Nothing
                            , riTreasuryTxIns = []
                            }
                r <- resolveDisburseEnv stub ri
                r
                    `shouldBe` Left
                        ( ResolverBeneficiaryNetworkMismatch
                            "mainnet"
                            "testnet"
                        )

            it
                "filters treasury UTxOs to requested TxIns before ADA selection"
                $ do
                    env <-
                        eitherDecodeStrict
                            "test/fixtures/disburse-wizard/env.ada.json"
                    let requested = mkTxIn 1
                        referenceScript = mkTxIn 2
                        stub =
                            ResolverEnv
                                { reEnvQueryWalletUtxos =
                                    \_ ->
                                        pure
                                            [
                                                ( txInToText (mkTxIn 7)
                                                , walletFeeSlackLovelace
                                                , False
                                                )
                                            ]
                                , reEnvQueryTreasuryUtxos =
                                    \_ ->
                                        pure
                                            [
                                                ( referenceScript
                                                , mkValue 100_000_000 0 0
                                                )
                                            ,
                                                ( requested
                                                , mkValue 2_000_000 0 0
                                                )
                                            ]
                                , reEnvComputeUpperBound =
                                    \_ -> pure (Right 42)
                                }
                        ri =
                            ResolverInput
                                { riNetwork = "mainnet"
                                , riWalletAddrBech32 =
                                    wsAddress (deWalletSelection env)
                                , riBeneficiaryAddrBech32 =
                                    wsAddress (deWalletSelection env)
                                , riScope = CoreDevelopment
                                , riUnit = ADA
                                , riAmount = 1_500_000
                                , riRegistry = deRegistry env
                                , riValidityHours = Nothing
                                , riTreasuryTxIns = [requested]
                                }
                    r <- resolveDisburseEnv stub ri
                    deTreasurySelection <$> r
                        `shouldBe` Right
                            DisburseTreasurySelection
                                { dtsInputs = [txInToText requested]
                                , dtsLeftoverLovelace = 500_000
                                , dtsLeftoverUsdm = 0
                                , dtsLeftoverOtherAssets = mempty
                                }

eitherDecodeStrict :: (Aeson.FromJSON a) => FilePath -> IO a
eitherDecodeStrict p = do
    bs <- BSL.readFile p
    expectRight (Aeson.eitherDecode bs)

expectRight :: (Show e) => Either e a -> IO a
expectRight =
    either
        ( errorWithoutStackTrace
            . ("unexpected Left: " <>)
            . show
        )
        pure

expectJust :: String -> Maybe a -> IO a
expectJust label =
    maybe
        (errorWithoutStackTrace ("unexpected Nothing: " <> label))
        pure

mkHash32 :: (HashAlgorithm h) => Word8 -> Hash h a
mkHash32 n =
    fromJust . hashFromBytes . BS.pack $
        replicate 31 0 ++ [n]

mkHash28 :: (HashAlgorithm h) => Word8 -> Hash h a
mkHash28 n =
    fromJust . hashFromBytes . BS.pack $
        replicate 27 0 ++ [n]

mkTxIn :: Word8 -> TxIn
mkTxIn n =
    TxIn
        (TxId (unsafeMakeSafeHash (mkHash32 n)))
        (mkTxIxPartial 0)

usdmPolicy :: PolicyID
usdmPolicy = PolicyID (ScriptHash (mkHash28 90))

usdmAsset :: AssetName
usdmAsset = AssetName (SBS.toShort "USDM")

otherPolicy :: PolicyID
otherPolicy = PolicyID (ScriptHash (mkHash28 91))

otherAsset :: AssetName
otherAsset = AssetName (SBS.toShort "OTHER")

mkValue :: Integer -> Integer -> Integer -> MaryValue
mkValue lovelace usdm other =
    MaryValue
        (Coin lovelace)
        ( MultiAsset $
            Map.fromListWith
                (Map.unionWith (+))
                [ (policy, Map.singleton asset quantity)
                | (policy, asset, quantity) <-
                    [ (usdmPolicy, usdmAsset, usdm)
                    , (otherPolicy, otherAsset, other)
                    ]
                , quantity /= 0
                ]
        )

lovelaceOf :: MaryValue -> Integer
lovelaceOf (MaryValue (Coin lovelace) _) = lovelace

assetOf :: PolicyID -> AssetName -> MaryValue -> Integer
assetOf policy asset (MaryValue _ (MultiAsset assets)) =
    maybe
        0
        (Map.findWithDefault 0 asset)
        (Map.lookup policy assets)

pickedValues
    :: DisburseTreasurySelection
    -> [(TxIn, MaryValue)]
    -> [MaryValue]
pickedValues selection inputs =
    [ value
    | (txIn, value) <- inputs
    , txInToText txIn `elem` dtsInputs selection
    ]

otherAssets :: Integer -> Map Text (Map Text Integer)
otherAssets quantity
    | quantity == 0 = Map.empty
    | otherwise =
        Map.singleton
            "0000000000000000000000000000000000000000000000000000005b"
            (Map.singleton "4f54484552" quantity)

cyberCastellumReferences :: [RationaleReferenceJSON]
cyberCastellumReferences =
    [ RationaleReferenceJSON
        { rjrUri =
            "ipfs://bafybeib3jef34ndw6oe24mkmifdvxe5jrv7ulh63rdllovyth27mqfj2da"
        , rjrType = "Other"
        , rjrLabel =
            "Whitehacking Agreement - Cyber Castellum 2026-03-31"
        }
    , RationaleReferenceJSON
        { rjrUri =
            "ipfs://bafybeigy37ui2ikn7bim2vw6cojcbxkcndpjwh7cj5fv3vzs4cszezipxu"
        , rjrType = "Other"
        , rjrLabel =
            "Invoice 3508 - Cyber Castellum Whitehacking M1"
        }
    , RationaleReferenceJSON
        { rjrUri =
            "ipfs://bafybeibx32gm7wefhtvvhojoqjrkjbhntknqkgfu7ryrhptbnmjgz7jvga"
        , rjrType = "Other"
        , rjrLabel = "CAG MSA - 2026-04-09"
        }
    , RationaleReferenceJSON
        { rjrUri =
            "ipfs://bafkreihl2qvl4coduzqwg4hhh7l7go5ym7y5d7w3flzb5kpxvvquj3i3qm"
        , rjrType = "Other"
        , rjrLabel =
            "CAG payment confirmation - Laura Dugan email 2026-05-21"
        }
    ]
