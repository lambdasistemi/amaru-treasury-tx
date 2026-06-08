{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}

{- |
Module      : Amaru.Treasury.Tx.DisburseSpec
Description : Tests for the disburse builder + JSON contract
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Two layers covered here:

* Structural test of 'disburseAdaProgram' over synthesized
  ledger inputs.
* JSON round-trip property on 'DisburseIntentJSON':
  @decodeDisburseIntent . encodeDisburseIntent@ is the
  identity for any wizard-shaped value (T012).
-}
module Amaru.Treasury.Tx.DisburseSpec (spec) where

import Cardano.Crypto.Hash.Class
    ( Hash
    , HashAlgorithm
    , hashFromBytes
    , hashToBytes
    )
import Cardano.Ledger.Address
    ( AccountAddress (..)
    , AccountId (..)
    , Addr (..)
    , Withdrawals (..)
    )
import Cardano.Ledger.Alonzo.TxWits (Redeemers (..))
import Cardano.Ledger.Api.Era (eraProtVerLow)
import Cardano.Ledger.Api.PParams (emptyPParams)
import Cardano.Ledger.Api.Tx (auxDataTxL, witsTxL)
import Cardano.Ledger.Api.Tx.AuxData (metadataTxAuxDataL)
import Cardano.Ledger.Api.Tx.Body
    ( collateralInputsTxBodyL
    , inputsTxBodyL
    , outputsTxBodyL
    , referenceInputsTxBodyL
    , reqSignerHashesTxBodyL
    , withdrawalsTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , coinTxOutL
    , getMinCoinTxOut
    , valueTxOutL
    )
import Cardano.Ledger.Api.Tx.Wits (rdmrsTxWitsL)
import Cardano.Ledger.BaseTypes
    ( Network (..)
    , StrictMaybe (..)
    , mkTxIxPartial
    )
import Cardano.Ledger.Binary
    ( DecCBOR (..)
    , decodeFullAnnotator
    , serialize
    )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (bodyTxL)
import Cardano.Ledger.Credential
    ( Credential (..)
    , StakeReference (..)
    )
import Cardano.Ledger.Hashes
    ( KeyHash (..)
    , ScriptHash (..)
    , unsafeMakeSafeHash
    )
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Tx.Ledger (ConwayTx)
import Codec.Serialise qualified as Codec
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Short qualified as SBS
import Data.Foldable (toList)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromJust)
import Data.Set qualified as Set
import Data.Word (Word8)
import Lens.Micro ((&), (.~), (^.))
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    , shouldContain
    , shouldSatisfy
    )
import Test.QuickCheck
    ( Gen
    , Property
    , chooseInt
    , chooseInteger
    , elements
    , forAll
    , vectorOf
    , (===)
    )

import Cardano.Tx.Build (draft)

import Amaru.Treasury.AuxData (label1694)
import Amaru.Treasury.Build
    ( BuildResult (..)
    , runFromIntent
    )
import Amaru.Treasury.ChainContext.Fixture
    ( SwapFixture (..)
    , readSwapFixture
    , toFrozenContext
    )
import Amaru.Treasury.Constants (minUtxoDepositLovelace)
import Amaru.Treasury.IntentJSON
    ( Action (..)
    , DisburseDestination (..)
    , DisburseInputs (..)
    , SAction (..)
    , SomeTreasuryIntent (..)
    , TranslatedShared (..)
    , TreasuryIntent
    , decodeTreasuryIntentFile
    , encodeSomeTreasuryIntent
    , translateIntent
    )
import Amaru.Treasury.PParams (readPParamsFile)
import Amaru.Treasury.Redeemer
    ( disburseAdaRedeemer
    , disburseUsdmRedeemer
    )
import Amaru.Treasury.Tx.Disburse
    ( DisburseAdaPayload (..)
    , DisburseIntent (..)
    , DisburseIntentFields (..)
    , DisburseUsdmPayload (..)
    , disburseAdaProgram
    , disburseUsdmProgram
    )
import Amaru.Treasury.Tx.DisburseIntentJSON
    ( DisburseInputsJSON (..)
    , DisburseIntentJSON (..)
    , DisburseRationaleJSON (..)
    , DisburseScopeJSON (..)
    , DisburseWalletJSON (..)
    , TranslatedDisburseIntent (..)
    , decodeDisburseIntent
    , encodeDisburseIntent
    , translateDisburseIntent
    )
import Amaru.Treasury.Tx.DisburseWizard
    ( DisburseAnswers
    , DisburseEnv
    , DisburseTreasurySelection (..)
    , disburseToTreasuryIntent
    , selectDisburseUsdm
    )

import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BSL
import System.Directory (doesFileExist)
import System.Environment (lookupEnv)

import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Text (Text)
import Data.Text qualified as T

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

scriptAddr :: Word8 -> Addr
scriptAddr n =
    Addr
        Mainnet
        (ScriptHashObj (ScriptHash (mkHash28 n)))
        ( StakeRefBase
            (ScriptHashObj (ScriptHash (mkHash28 n)))
        )

keyAddr :: Word8 -> Addr
keyAddr n =
    Addr
        Mainnet
        (KeyHashObj (KeyHash (mkHash28 n)))
        StakeRefNull

permissionsRewardAcct :: Word8 -> AccountAddress
permissionsRewardAcct n =
    AccountAddress
        Mainnet
        (AccountId (ScriptHashObj (ScriptHash (mkHash28 n))))

rewardAccountNetwork :: AccountAddress -> Network
rewardAccountNetwork (AccountAddress network _) = network

fields :: DisburseIntentFields
fields =
    DisburseIntentFields
        { difWalletUtxo = mkTxIn 0
        , difBeneficiaryAddress = keyAddr 99
        , difTreasuryUtxos = [mkTxIn 1]
        , difTreasuryAddress = scriptAddr 10
        , difPermissionsRewardAccount = permissionsRewardAcct 11
        , difScopesDeployedAt = mkTxIn 2
        , difPermissionsDeployedAt = mkTxIn 3
        , difTreasuryDeployedAt = mkTxIn 4
        , difRegistryDeployedAt = mkTxIn 5
        , difSigners =
            [ KeyHash (mkHash28 20)
            , KeyHash (mkHash28 21)
            ]
        , difUpperBound = SlotNo 1_000
        }

payload :: DisburseAdaPayload
payload =
    DisburseAdaPayload
        { dapBeneficiaries =
            (keyAddr 99, Coin 50_000_000) :| []
        , dapLeftoverLovelace = Coin 1_400_000_000_000
        }

{- | A two-destination ADA payload. Output 0 is the
treasury leftover; outputs 1 and 2 are the two
beneficiaries in operator order. The spend redeemer
authorizes Σ = 50_000_000 + 30_000_000 = 80_000_000.
-}
multiPayload :: DisburseAdaPayload
multiPayload =
    DisburseAdaPayload
        { dapBeneficiaries =
            (keyAddr 99, Coin 50_000_000)
                :| [(keyAddr 98, Coin 30_000_000)]
        , dapLeftoverLovelace = Coin 1_400_000_000_000
        }

-- | Σ of the two-destination payload's beneficiary lovelace.
multiBeneficiarySum :: Integer
multiBeneficiarySum = 50_000_000 + 30_000_000

-- | Expected ADA spend-redeemer CBOR hex for a total amount.
expectedAdaRedeemerHex :: Integer -> BS.ByteString
expectedAdaRedeemerHex total =
    B16.encode . BSL.toStrict . Codec.serialise $
        disburseAdaRedeemer total

usdmPolicy :: PolicyID
usdmPolicy = PolicyID (ScriptHash (mkHash28 88))

usdmAsset :: AssetName
usdmAsset = AssetName (SBS.toShort "USDM")

otherPolicy :: PolicyID
otherPolicy = PolicyID (ScriptHash (mkHash28 89))

otherAsset :: AssetName
otherAsset = AssetName (SBS.toShort "OTHER")

usdmPayload :: DisburseUsdmPayload
usdmPayload =
    DisburseUsdmPayload
        { dupUsdmPolicy = usdmPolicy
        , dupUsdmAsset = usdmAsset
        , dupAmountUsdm = 100_000_000
        , dupLeftoverLovelace = Coin 1_400_000_000_000
        , dupLeftoverUsdm = 50_000_000
        , dupLeftoverOtherAssets =
            MultiAsset $
                Map.singleton otherPolicy $
                    Map.singleton otherAsset 7
        }

expectedUsdmRedeemerHex :: Coin -> BS.ByteString
expectedUsdmRedeemerHex (Coin lovelace) =
    B16.encode . BSL.toStrict . Codec.serialise $
        disburseUsdmRedeemer
            (policyBytes usdmPolicy)
            (assetBytes usdmAsset)
            (dupAmountUsdm usdmPayload)
            lovelace

policyBytes :: PolicyID -> BS.ByteString
policyBytes (PolicyID (ScriptHash h)) =
    hashToBytes h

assetBytes :: AssetName -> BS.ByteString
assetBytes (AssetName raw) =
    SBS.fromShort raw

spec :: Spec
spec = do
    describe "Amaru.Treasury.Tx.Disburse" $ do
        let tx =
                draft
                    emptyPParams
                    (disburseAdaProgram fields payload)
            body = tx ^. bodyTxL
        it "spends wallet UTxO + the treasury UTxO" $
            body
                ^. inputsTxBodyL
                `shouldBe` Set.fromList [mkTxIn 0, mkTxIn 1]
        it "uses the wallet UTxO as collateral" $
            body
                ^. collateralInputsTxBodyL
                `shouldBe` Set.singleton (mkTxIn 0)
        it
            "carries 4 reference inputs (scopes, permissions, treasury, registry)"
            $ Set.size (body ^. referenceInputsTxBodyL)
                `shouldBe` 4
        it "withdraw-zero against the permissions reward account" $
            body
                ^. withdrawalsTxBodyL
                `shouldBe` Withdrawals
                    ( Map.singleton
                        (permissionsRewardAcct 11)
                        (Coin 0)
                    )
        it "produces exactly two outputs (leftover + beneficiary)" $
            length (body ^. outputsTxBodyL) `shouldBe` 2
        it "requires both scope-owner signers" $
            body
                ^. reqSignerHashesTxBodyL
                `shouldSatisfy` \s -> Set.size s == 2

        -- Regression for #224/#81. The on-chain treasury validator
        -- enforces lovelace conservation:
        --     equal_plus_min_ada(input_sum - amount, output_sum)
        -- For a treasury-funded USDM disburse the redeemer's
        -- `amount.lovelace` must equal the beneficiary output's
        -- compensated min-UTxO, and the treasury leftover output
        -- must subtract the same lovelace.
        it
            "USDM disburse: payTo compensation funds beneficiary min-UTxO from treasury ADA"
            $ do
                pp <- readPParamsFile "test/fixtures/pparams.json"
                let totalTreasuryInputLov = 1_400_000_000_000 :: Integer
                    validatorCorrectPayload =
                        usdmPayload
                            { dupLeftoverLovelace =
                                Coin totalTreasuryInputLov
                            }
                    usdmTx =
                        draft
                            pp
                            (disburseUsdmProgram fields validatorCorrectPayload)
                    usdmBody = usdmTx ^. bodyTxL
                    outs = toList (usdmBody ^. outputsTxBodyL)
                case outs of
                    [treasuryOut, beneficiaryOut] -> do
                        let beneficiaryCoin = beneficiaryOut ^. coinTxOutL
                            Coin beneficiaryLov = beneficiaryCoin
                            required =
                                getMinCoinTxOut pp beneficiaryOut
                        beneficiaryCoin `shouldSatisfy` (>= required)
                        treasuryOut
                            ^. valueTxOutL
                            `shouldBe` MaryValue
                                (Coin (totalTreasuryInputLov - beneficiaryLov))
                                ( MultiAsset $
                                    Map.fromList
                                        [
                                            ( usdmPolicy
                                            , Map.singleton usdmAsset 50_000_000
                                            )
                                        ,
                                            ( otherPolicy
                                            , Map.singleton otherAsset 7
                                            )
                                        ]
                                )
                        beneficiaryOut
                            ^. valueTxOutL
                            `shouldBe` MaryValue
                                beneficiaryCoin
                                ( MultiAsset $
                                    Map.singleton usdmPolicy $
                                        Map.singleton usdmAsset 100_000_000
                                )
                    _ ->
                        expectationFailure
                            ( "expected two outputs, saw "
                                <> show (length outs)
                            )

    describe "disburseAdaProgram — multi-destination ADA" $ do
        let multiTx =
                draft
                    emptyPParams
                    (disburseAdaProgram fields multiPayload)
            multiBody = multiTx ^. bodyTxL
            multiOuts = toList (multiBody ^. outputsTxBodyL)
        it
            "produces leftover + one output per beneficiary (3 outputs)"
            $ length multiOuts `shouldBe` 3
        it
            "emits leftover first, then beneficiaries in operator order"
            $ map (^. coinTxOutL) multiOuts
                `shouldBe` [ Coin 1_400_000_000_000
                           , Coin 50_000_000
                           , Coin 30_000_000
                           ]
        it
            "spend redeemer authorizes Σ of beneficiary lovelace"
            $ do
                let Redeemers redeemers =
                        multiTx ^. witsTxL . rdmrsTxWitsL
                    redeemerHexes =
                        [ B16.encode . BSL.toStrict $
                            serialize
                                (eraProtVerLow @ConwayEra)
                                dat
                        | (_, (dat, _)) <- Map.toAscList redeemers
                        ]
                redeemerHexes
                    `shouldContain` [ expectedAdaRedeemerHex
                                        multiBeneficiarySum
                                    ]

    describe "DisburseInputs multi-destination JSON" $ do
        it
            "round-trips a 2-destination payload via the destinations array"
            $ do
                let inputs =
                        DisburseInputs
                            { diUnit = "ada"
                            , diDestinations =
                                DisburseDestination
                                    "addr1_a"
                                    50_000_000
                                    :| [ DisburseDestination
                                            "addr1_b"
                                            30_000_000
                                       ]
                            , diUsdmPolicy = ""
                            , diUsdmToken = ""
                            }
                Aeson.eitherDecode (Aeson.encode inputs)
                    `shouldBe` Right inputs
        it
            "decodes legacy flat single-destination keys to a singleton"
            $ do
                let bytes =
                        "{\"unit\":\"ada\",\"amount\":50000000\
                        \,\"beneficiaryAddress\":\"addr1_a\"\
                        \,\"usdmPolicy\":\"\",\"usdmToken\":\"\"}"
                    expected =
                        DisburseInputs
                            { diUnit = "ada"
                            , diDestinations =
                                DisburseDestination
                                    "addr1_a"
                                    50_000_000
                                    :| []
                            , diUsdmPolicy = ""
                            , diUsdmToken = ""
                            }
                Aeson.eitherDecode bytes `shouldBe` Right expected

    -- Keystone invariant. This is the test that would have
    -- caught #215 at unit-test time: the wizard's USDM
    -- selection MUST yield `dtsLeftoverLovelace == sum of
    -- input lovelaces`. Anything less and the on-chain
    -- treasury validator's `equal_plus_min_ada` check
    -- rejects the tx (the redeemer's `amount.lovelace` is 0
    -- for USDM disburses).
    describe "selectDisburseUsdm: lovelace conservation (#215)" $ do
        let mkUsdmInput :: Word8 -> Integer -> Integer -> (TxIn, MaryValue)
            mkUsdmInput n lov usdmQty =
                ( mkTxIn n
                , MaryValue
                    (Coin lov)
                    ( MultiAsset $
                        Map.singleton usdmPolicy $
                            Map.singleton usdmAsset usdmQty
                    )
                )
        it
            "leftover lovelace == sum of selected treasury input lovelaces (single input)"
            $ do
                let input = mkUsdmInput 30 4_612_003 20_330_144_633
                    amount = 18_750_000_000
                    sel =
                        fromJust $
                            selectDisburseUsdm
                                usdmPolicy
                                usdmAsset
                                minUtxoDepositLovelace
                                [input]
                                amount
                dtsLeftoverLovelace sel `shouldBe` 4_612_003

        it
            "leftover lovelace == sum of selected treasury input lovelaces (multi-input)"
            $ do
                let inputs =
                        [ mkUsdmInput 30 3_000_000 12_000_000_000
                        , mkUsdmInput 31 4_500_000 8_500_000_000
                        ]
                    amount = 18_750_000_000
                    sel =
                        fromJust $
                            selectDisburseUsdm
                                usdmPolicy
                                usdmAsset
                                minUtxoDepositLovelace
                                inputs
                                amount
                dtsLeftoverLovelace sel `shouldBe` 7_500_000

        it
            "leftover USDM == sum of selected treasury input USDM minus disbursed amount"
            $ do
                let input = mkUsdmInput 30 4_612_003 20_330_144_633
                    amount = 18_750_000_000
                    sel =
                        fromJust $
                            selectDisburseUsdm
                                usdmPolicy
                                usdmAsset
                                minUtxoDepositLovelace
                                [input]
                                amount
                dtsLeftoverUsdm sel `shouldBe` 1_580_144_633

        it "authorizes treasury-funded USDM min-UTxO in the spend redeemer" $ do
            pp <- readPParamsFile "test/fixtures/pparams.json"
            let usdmTx =
                    draft
                        pp
                        (disburseUsdmProgram fields usdmPayload)
                outs = toList (usdmTx ^. bodyTxL . outputsTxBodyL)
                Redeemers redeemers =
                    usdmTx ^. witsTxL . rdmrsTxWitsL
                redeemerHexes =
                    [ B16.encode . BSL.toStrict $
                        serialize
                            (eraProtVerLow @ConwayEra)
                            dat
                    | (_, (dat, _)) <- Map.toAscList redeemers
                    ]
            case outs of
                [_, beneficiaryOut] ->
                    redeemerHexes
                        `shouldContain` [ expectedUsdmRedeemerHex
                                            (beneficiaryOut ^. coinTxOutL)
                                        ]
                _ ->
                    expectationFailure
                        ( "expected two outputs, saw "
                            <> show (length outs)
                        )

    describe "Amaru.Treasury.Tx.DisburseIntentJSON" $ do
        it
            "decodeDisburseIntent . encodeDisburseIntent = Right"
            roundTripProp

        it "translates DevNet disburse reward accounts as Testnet" $ do
            dij <-
                eitherDecodeStrict
                    "test/fixtures/disburse/ada/intent.json"
                    :: IO DisburseIntentJSON
            TranslatedDisburseIntent{tdDisburseIntent = di} <-
                expectRight $
                    translateDisburseIntent
                        dij{dijNetwork = "devnet"}
            case di of
                DisburseAdaIntent translatedFields _ ->
                    rewardAccountNetwork
                        ( difPermissionsRewardAccount
                            translatedFields
                        )
                        `shouldBe` Testnet
                DisburseUsdmIntent{} ->
                    expectationFailure
                        "expected ADA disburse payload"

    describe "Amaru.Treasury.Tx.DisburseWizard.disburseToTreasuryIntent" $
        do
            it "matches golden expected.intent.ada.json" $
                goldenCase "ada"
            it "matches golden expected.intent.usdm.json" $
                goldenCase "usdm"

    describe "Amaru.Treasury.IntentJSON.translateIntent" $
        it "translates unified ADA disburse intent" $ do
            some <-
                expectRight
                    =<< decodeTreasuryIntentFile
                        "test/fixtures/disburse-wizard/expected.intent.ada.json"
            case some of
                SomeTreasuryIntent SDisburse intent -> do
                    (shared, translated) <-
                        expectRight $
                            translateIntent SDisburse intent
                    tsNetwork shared `shouldBe` "mainnet"
                    case translated of
                        DisburseAdaIntent _ ada ->
                            fmap snd (dapBeneficiaries ada)
                                `shouldBe` (Coin 50_000_000 :| [])
                        DisburseUsdmIntent{} ->
                            expectationFailure
                                "expected ADA disburse payload"
                _ ->
                    expectationFailure
                        "expected SDisburse intent"

    describe "Amaru.Treasury.Build.runFromIntent"
        $ it
            "builds d6c14625 references intent with golden label-1694 CBOR"
        $ do
            some <-
                expectRight
                    =<< decodeTreasuryIntentFile
                        d6c14625IntentPath
            fixture <-
                readSwapFixture "test/fixtures/disburse/ada"
            fundedFixture <-
                fundD6c14625TreasuryAssets some fixture
            result <-
                runFromIntent
                    (toFrozenContext fundedFixture)
                    some
            tx <- expectRight (decodeFinalTx result)
            actual <- expectRight (label1694Cbor tx)
            expected <- BS.readFile d6c14625RationalePath
            actual `shouldBe` expected

-- ----------------------------------------------------
-- T020: Pure-translation goldens (ADA + USDM)
-- ----------------------------------------------------

{- | Load fixture (env, answers) for the named unit, run
'disburseToTreasuryIntent', and assert the encoded JSON
matches the checked-in golden byte-for-byte (modulo
alphabetical key ordering, applied by both the encoder
and the golden file).
-}
goldenCase :: FilePath -> IO ()
goldenCase unit = do
    let dir = "test/fixtures/disburse-wizard"
        envPath = dir <> "/env." <> unit <> ".json"
        ansPath = dir <> "/answers." <> unit <> ".json"
        goldenPath =
            dir <> "/expected.intent." <> unit <> ".json"
    env <-
        eitherDecodeStrict envPath :: IO DisburseEnv
    answers <-
        eitherDecodeStrict ansPath :: IO DisburseAnswers
    let result = disburseToTreasuryIntent env answers
    case result of
        Left err ->
            error
                ( "disburseToTreasuryIntent failed: " <> show err
                )
        Right got -> do
            let actualBytes = stableEncode got
            exists <- doesFileExist goldenPath
            update <- lookupEnv "UPDATE_GOLDENS"
            if not exists || update == Just "1"
                then do
                    BSL.writeFile goldenPath actualBytes
                    error
                        ( "Golden written to "
                            <> goldenPath
                            <> "; review and re-run without"
                            <> " UPDATE_GOLDENS=1 to lock in"
                        )
                else do
                    expectedBytes <- BSL.readFile goldenPath
                    actualBytes `shouldBe` expectedBytes

eitherDecodeStrict :: (Aeson.FromJSON a) => FilePath -> IO a
eitherDecodeStrict p = do
    bs <- BSL.readFile p
    case Aeson.eitherDecode bs of
        Right v -> pure v
        Left e ->
            error ("decode " <> p <> ": " <> e)

expectRight :: (Show e) => Either e a -> IO a
expectRight =
    either
        ( errorWithoutStackTrace
            . ("unexpected Left: " <>)
            . show
        )
        pure

-- | Stable encoder for the unified disburse intent shape.
stableEncode :: TreasuryIntent 'Disburse -> BSL.ByteString
stableEncode =
    encodeSomeTreasuryIntent . SomeTreasuryIntent SDisburse

d6c14625IntentPath :: FilePath
d6c14625IntentPath =
    "test/fixtures/disburse/d6c14625-references/intent.json"

d6c14625RationalePath :: FilePath
d6c14625RationalePath =
    "test/fixtures/disburse/d6c14625-references/rationale.cbor"

fundD6c14625TreasuryAssets
    :: SomeTreasuryIntent
    -> SwapFixture
    -> IO SwapFixture
fundD6c14625TreasuryAssets some fixture =
    case some of
        SomeTreasuryIntent SDisburse intent -> do
            (_, translated) <-
                expectRight (translateIntent SDisburse intent)
            case translated of
                DisburseUsdmIntent translatedFields translatedUsdm ->
                    case difTreasuryUtxos translatedFields of
                        [treasuryInput] ->
                            pure
                                fixture
                                    { sfUtxos =
                                        Map.adjust
                                            ( withUsdmTreasuryValue
                                                translatedUsdm
                                            )
                                            treasuryInput
                                            (sfUtxos fixture)
                                    }
                        _ ->
                            fail
                                "expected one d6c14625 treasury input"
                DisburseAdaIntent{} ->
                    fail
                        "expected d6c14625 USDM disburse intent"
        _ ->
            fail "expected SDisburse intent"

withUsdmTreasuryValue
    :: DisburseUsdmPayload
    -> TxOut ConwayEra
    -> TxOut ConwayEra
withUsdmTreasuryValue translatedUsdm txOut =
    txOut
        & valueTxOutL
            .~ MaryValue
                lovelace
                ( MultiAsset $
                    Map.singleton
                        (dupUsdmPolicy translatedUsdm)
                        ( Map.singleton
                            (dupUsdmAsset translatedUsdm)
                            ( dupAmountUsdm translatedUsdm
                                + dupLeftoverUsdm translatedUsdm
                            )
                        )
                )
  where
    MaryValue lovelace _ = txOut ^. valueTxOutL

decodeFinalTx :: BuildResult -> Either String ConwayTx
decodeFinalTx result =
    case decodeFullAnnotator
        (eraProtVerLow @ConwayEra)
        "ConwayTx"
        decCBOR
        (brCborBytes result) of
        Right tx -> Right tx
        Left err -> Left (show err)

label1694Cbor :: ConwayTx -> Either String BS.ByteString
label1694Cbor tx =
    case tx ^. auxDataTxL of
        SNothing -> Left "built tx has no auxiliary data"
        SJust auxData ->
            case Map.lookup
                label1694
                (auxData ^. metadataTxAuxDataL) of
                Nothing -> Left "built tx has no label-1694 metadatum"
                Just metadatum ->
                    Right $
                        BSL.toStrict $
                            serialize
                                (eraProtVerLow @ConwayEra)
                                metadatum

-- ----------------------------------------------------
-- T012: JSON round-trip property
-- ----------------------------------------------------

{- | For any wizard-shaped 'DisburseIntentJSON', the
@decode . encode@ pipeline must return the same value.
Covers SC-003 (100% round-trip).
-}
roundTripProp :: Property
roundTripProp = forAll genDisburseIntentJSON $ \dij ->
    decodeDisburseIntent (encodeDisburseIntent dij)
        === Right dij

-- ----------------------------------------------------
-- Generators (no Arbitrary instances per /haskell skill)
-- ----------------------------------------------------

genHexN :: Int -> Gen Text
genHexN n =
    T.pack
        <$> vectorOf
            (n * 2)
            (elements "0123456789abcdef")

genTxId :: Gen Text
genTxId = do
    h <- genHexN 32
    ix <- chooseInt (0, 100)
    pure (h <> "#" <> T.pack (show ix))

genBech32Addr :: Gen Text
genBech32Addr =
    T.pack . ("addr1" <>)
        <$> vectorOf
            50
            (elements "abcdefghjkmnpqrstuvwxyz0123456789")

genAssetMap :: Gen (Map Text (Map Text Integer))
genAssetMap = do
    n <- chooseInt (0, 2)
    Map.fromList <$> vectorOf n entry
  where
    entry = do
        policy <- genHexN 28
        m <- chooseInt (0, 2)
        inner <-
            Map.fromList
                <$> vectorOf m innerEntry
        pure (policy, inner)
    innerEntry = do
        asset <- genHexN 4
        amount <- chooseInteger (1, 1_000_000)
        pure (asset, amount)

genWallet :: Gen DisburseWalletJSON
genWallet =
    DisburseWalletJSON
        <$> genTxId
        <*> genBech32Addr

genScope :: Gen DisburseScopeJSON
genScope = do
    sid <-
        elements
            [ "core_development"
            , "ops_and_use_cases"
            , "network_compliance"
            , "middleware"
            , "contingency"
            ]
    addr <- genBech32Addr
    nUtxos <- chooseInt (1, 4)
    utxos <- vectorOf nUtxos genTxId
    leftoverLov <- chooseInteger (0, 10_000_000_000)
    leftoverUsdm <- chooseInteger (0, 10_000_000_000)
    leftoverOther <- genAssetMap
    treasuryHash <- genHexN 28
    permissionsAcct <- genHexN 28
    scopesRef <- genTxId
    permissionsRef <- genTxId
    treasuryRef <- genTxId
    registryRef <- genTxId
    registryPolicy <- genHexN 28
    pure
        DisburseScopeJSON
            { dsjId = sid
            , dsjTreasuryAddress = addr
            , dsjTreasuryUtxos = utxos
            , dsjTreasuryLeftoverLovelace = leftoverLov
            , dsjTreasuryLeftoverUsdm = leftoverUsdm
            , dsjTreasuryLeftoverOtherAssets = leftoverOther
            , dsjTreasuryScriptHash = treasuryHash
            , dsjPermissionsRewardAccount = permissionsAcct
            , dsjScopesDeployedAt = scopesRef
            , dsjPermissionsDeployedAt = permissionsRef
            , dsjTreasuryDeployedAt = treasuryRef
            , dsjRegistryDeployedAt = registryRef
            , dsjRegistryPolicyId = registryPolicy
            }

genInputs :: Gen DisburseInputsJSON
genInputs =
    DisburseInputsJSON
        <$> elements ["ada", "usdm"]
        <*> chooseInteger (1, 10_000_000_000)
        <*> genBech32Addr
        <*> genHexN 28
        <*> genHexN 4

genRationale :: Gen DisburseRationaleJSON
genRationale =
    DisburseRationaleJSON
        <$> elements ["disburse", "vendor", "rebate"]
        <*> elements ["Disburse ADA", "Disburse USDM"]
        <*> pure "A description"
        <*> pure "A justification"
        <*> pure "Beneficiary X"
        <*> pure []

genDisburseIntentJSON :: Gen DisburseIntentJSON
genDisburseIntentJSON = do
    network <-
        elements ["mainnet", "preprod", "preview"]
    wallet <- genWallet
    scope <- genScope
    inputs <- genInputs
    nSigners <- chooseInt (1, 3)
    signers <- vectorOf nSigners (genHexN 28)
    validity <- toEnum <$> chooseInt (1, 200_000_000)
    rationale <- genRationale
    pure
        DisburseIntentJSON
            { dijNetwork = network
            , dijWallet = wallet
            , dijScope = scope
            , dijDisburse = inputs
            , dijSigners = signers
            , dijValidityUpperBoundSlot = validity
            , dijRationale = rationale
            }
