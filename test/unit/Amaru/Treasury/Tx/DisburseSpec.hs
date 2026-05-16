{-# LANGUAGE DataKinds #-}

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

import Cardano.Crypto.Hash.Class (Hash, HashAlgorithm, hashFromBytes)
import Cardano.Ledger.Address
    ( AccountAddress (..)
    , AccountId (..)
    , Addr (..)
    , Withdrawals (..)
    )
import Cardano.Ledger.Api.PParams (emptyPParams)
import Cardano.Ledger.Api.Tx.Body
    ( collateralInputsTxBodyL
    , inputsTxBodyL
    , outputsTxBodyL
    , referenceInputsTxBodyL
    , reqSignerHashesTxBodyL
    , withdrawalsTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out (valueTxOutL)
import Cardano.Ledger.BaseTypes
    ( Network (..)
    , mkTxIxPartial
    )
import Cardano.Ledger.Coin (Coin (..))
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
import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.Foldable (toList)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromJust)
import Data.Set qualified as Set
import Data.Word (Word8)
import Lens.Micro ((^.))
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
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

import Amaru.Treasury.IntentJSON
    ( Action (..)
    , SAction (..)
    , SomeTreasuryIntent (..)
    , TranslatedShared (..)
    , TreasuryIntent
    , decodeTreasuryIntentFile
    , encodeSomeTreasuryIntent
    , translateIntent
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
    , disburseToTreasuryIntent
    )

import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BSL
import System.Directory (doesFileExist)
import System.Environment (lookupEnv)

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
        { dapAmountLovelace = Coin 50_000_000
        , dapLeftoverLovelace = Coin 1_400_000_000_000
        }

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

        it "builds USDM beneficiary and treasury leftover values" $ do
            let usdmTx =
                    draft
                        emptyPParams
                        ( disburseUsdmProgram
                            fields
                            usdmPayload
                            (Coin 2_000_000)
                        )
                usdmBody = usdmTx ^. bodyTxL
                values =
                    (^. valueTxOutL)
                        <$> toList (usdmBody ^. outputsTxBodyL)
            values
                `shouldBe` [ MaryValue
                                (Coin 1_400_000_000_000)
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
                           , MaryValue
                                (Coin 2_000_000)
                                ( MultiAsset $
                                    Map.singleton usdmPolicy $
                                        Map.singleton usdmAsset 100_000_000
                                )
                           ]

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
                            dapAmountLovelace ada
                                `shouldBe` Coin 50_000_000
                        DisburseUsdmIntent{} ->
                            expectationFailure
                                "expected ADA disburse payload"
                _ ->
                    expectationFailure
                        "expected SDisburse intent"

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
