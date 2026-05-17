{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.IntentJSONSchemaSpec
Description : JSON Schema contract tests for TreasuryIntent
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Verifies that the generated JSON Schema asset stays in
sync with the Haskell source of truth and that checked-in
intents plus wizard-emitted JSON conform to it.
-}
module Amaru.Treasury.IntentJSONSchemaSpec (spec) where

import Data.Aeson
    ( FromJSON
    , Value (..)
    , eitherDecode
    , eitherDecodeFileStrict
    , encode
    , toJSON
    )
import Data.Aeson.Key (Key)
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy.Char8 qualified as BSL8
import Data.JSON.JSONSchema (validateJSONSchema)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldSatisfy
    )

import Amaru.Treasury.IntentJSON
    ( Action (..)
    , RationaleJSON (..)
    , SAction (..)
    , ScopeJSON (..)
    , SomeTreasuryIntent (..)
    , TreasuryIntent (..)
    , WalletJSON (..)
    , WithdrawInputs (..)
    , encodeSomeTreasuryIntent
    )
import Amaru.Treasury.IntentJSON.Schema (intentJsonSchema)
import Amaru.Treasury.Tx.DisburseWizard
    ( DisburseAnswers
    , DisburseEnv
    , disburseToTreasuryIntent
    )
import Amaru.Treasury.Tx.SwapWizard
    ( SwapWizardQ
    , WizardEnv
    , wizardToTreasuryIntent
    )

spec :: Spec
spec = describe "Amaru.Treasury.IntentJSON.Schema" $ do
    it "matches the checked-in schema asset" $ do
        asset <-
            decodeFile "docs/assets/intent-schema.json"
        asset `shouldBe` intentJsonSchema

    describe "carries the seven flat init sub-action tags" $ do
        let schemaBytes = encode intentJsonSchema
            containsTag tag =
                BSL8.unpack schemaBytes
                    `shouldSatisfy` ( tag
                                        `isInfixOf`
                                    )
        it "registry-init-seed-split" $
            containsTag "registry-init-seed-split"
        it "registry-init-mint" $
            containsTag "registry-init-mint"
        it "registry-init-reference-scripts" $
            containsTag "registry-init-reference-scripts"
        it "stake-reward-init-script-account" $
            containsTag "stake-reward-init-script-account"
        it "stake-reward-init-plain-account" $
            containsTag "stake-reward-init-plain-account"
        it "governance-withdrawal-init-proposal" $
            containsTag "governance-withdrawal-init-proposal"
        it "governance-withdrawal-init-materialization" $
            containsTag
                "governance-withdrawal-init-materialization"

    it "validates the tx-build swap fixture intent" $ do
        intent <- decodeFile "test/fixtures/swap/intent.json"
        validateJSONSchema intentJsonSchema intent
            `shouldBe` True

    it
        "validates the legacy swap fixture intent (no extraTxIns)"
        $ do
            intent <-
                decodeFile
                    "test/fixtures/swap/legacy/intent.json"
            validateJSONSchema intentJsonSchema intent
                `shouldBe` True

    it "validates the swap-wizard golden intent" $ do
        intent <-
            decodeFile
                "test/fixtures/swap-wizard/expected.intent.json"
        validateJSONSchema intentJsonSchema intent
            `shouldBe` True

    it "validates the disburse-wizard ADA golden intent" $ do
        intent <-
            decodeFile
                "test/fixtures/disburse-wizard/expected.intent.ada.json"
        validateJSONSchema intentJsonSchema intent
            `shouldBe` True

    it "validates the tx-build ADA disburse fixture intent" $ do
        intent <- decodeFile "test/fixtures/disburse/ada/intent.json"
        validateJSONSchema intentJsonSchema intent
            `shouldBe` True

    it "validates the tx-build withdraw fixture intent" $ do
        intent <-
            decodeFile "test/fixtures/withdraw/synthetic/intent.json"
        validateJSONSchema intentJsonSchema intent
            `shouldBe` True

    it "validates JSON emitted by wizardToTreasuryIntent" $ do
        env :: WizardEnv <-
            decodeFile "test/fixtures/swap-wizard/env.json"
        answers :: SwapWizardQ <-
            decodeFile "test/fixtures/swap-wizard/answers.json"
        intent <-
            expectRight $
                wizardToTreasuryIntent env answers
        let bytes =
                encodeSomeTreasuryIntent
                    (SomeTreasuryIntent SSwap intent)
        value <- expectRight (eitherDecode bytes)
        validateJSONSchema intentJsonSchema value
            `shouldBe` True

    it "validates JSON emitted by disburseToTreasuryIntent" $ do
        env :: DisburseEnv <-
            decodeFile "test/fixtures/disburse-wizard/env.ada.json"
        answers :: DisburseAnswers <-
            decodeFile
                "test/fixtures/disburse-wizard/answers.ada.json"
        intent <-
            expectRight $
                disburseToTreasuryIntent env answers
        let bytes =
                encodeSomeTreasuryIntent
                    (SomeTreasuryIntent SDisburse intent)
        value <- expectRight (eitherDecode bytes)
        validateJSONSchema intentJsonSchema value
            `shouldBe` True

    it "validates JSON emitted for a withdraw intent" $ do
        value <- withdrawValue
        validateJSONSchema intentJsonSchema value
            `shouldBe` True

    it "rejects action/payload mismatches" $ do
        swapIntent <- decodeFile "test/fixtures/swap/intent.json"
        let mismatched =
                replaceActionBlockWithAction
                    "swap"
                    "swap"
                    "disburse"
                    disburseBlock
                    swapIntent
        validateJSONSchema intentJsonSchema mismatched
            `shouldBe` False

    it "rejects action='withdraw' with a swap payload" $ do
        swapIntent <- decodeFile "test/fixtures/swap/intent.json"
        validateJSONSchema
            intentJsonSchema
            (setAction "withdraw" swapIntent)
            `shouldBe` False

    it "rejects action='withdraw' with a disburse payload" $ do
        disburseIntent <-
            decodeFile "test/fixtures/disburse/ada/intent.json"
        validateJSONSchema
            intentJsonSchema
            (setAction "withdraw" disburseIntent)
            `shouldBe` False

    it "rejects action='withdraw' with a reorganize payload" $ do
        value <- withdrawValue
        let mismatched =
                replaceActionBlockWithAction
                    "withdraw"
                    "withdraw"
                    "reorganize"
                    (Object KM.empty)
                    value
        validateJSONSchema intentJsonSchema mismatched
            `shouldBe` False

    it "accepts wallet.extraTxIns as a non-empty txIn array" $ do
        swapIntent <- decodeFile "test/fixtures/swap/intent.json"
        let extras =
                toJSON
                    [ T.pack
                        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef#1"
                    ]
            withExtras =
                setWalletField "extraTxIns" extras swapIntent
        validateJSONSchema intentJsonSchema withExtras
            `shouldBe` True

    it "rejects wallet.extraTxIns when the type is wrong" $ do
        swapIntent <- decodeFile "test/fixtures/swap/intent.json"
        let withScalar =
                setWalletField
                    "extraTxIns"
                    (Number 3)
                    swapIntent
        validateJSONSchema intentJsonSchema withScalar
            `shouldBe` False

decodeFile :: (FromJSON a) => FilePath -> IO a
decodeFile path = do
    r <- eitherDecodeFileStrict path
    expectRight r

expectRight :: (Show e) => Either e a -> IO a
expectRight =
    either
        ( errorWithoutStackTrace
            . ("unexpected Left: " <>)
            . show
        )
        pure

setAction :: Text -> Value -> Value
setAction action = \case
    Object o -> Object (KM.insert "action" (String action) o)
    other -> other

replaceActionBlockWithAction
    :: Text
    -> Key
    -> Key
    -> Value
    -> Value
    -> Value
replaceActionBlockWithAction action oldBlock newBlock payload = \case
    Object o ->
        Object $
            KM.insert "action" (String action) $
                KM.insert newBlock payload $
                    KM.delete oldBlock o
    other -> other

{- | Replace (or insert) a single field on the @wallet@
sub-object of an intent JSON. Used to synthesise schema
fixtures with custom 'extraTxIns' shapes.
-}
setWalletField :: Key -> Value -> Value -> Value
setWalletField field value = \case
    Object o ->
        case KM.lookup "wallet" o of
            Just (Object w) ->
                Object $
                    KM.insert
                        "wallet"
                        (Object (KM.insert field value w))
                        o
            _ -> Object o
    other -> other

disburseBlock :: Value
disburseBlock =
    Object $
        KM.fromList
            [ ("unit", String "ada")
            , ("amount", Number 50000000)
            ,
                ( "beneficiaryAddress"
                , String
                    "addr1q802wxt6cg6aw0nl0vdzfxavu65rxu3yzhvgayw7chfxymduzkt66uw9t5kspx5jwjecx80dz4g33htknafhdhkvzd5st4f9xu"
                )
            ,
                ( "usdmPolicy"
                , String
                    "c48cbb3d5e57ed56e276bc45f99ab39abe94e6cd7ac39fb402da47ad"
                )
            , ("usdmToken", String "0014df105553444d")
            ]

withdrawValue :: IO Value
withdrawValue =
    expectRight . eitherDecode . encodeSomeTreasuryIntent $
        SomeTreasuryIntent SWithdraw withdrawIntent

withdrawIntent :: TreasuryIntent 'Withdraw
withdrawIntent =
    TreasuryIntent
        SWithdraw
        1
        "mainnet"
        ( WalletJSON
            "42e4c279036e3ab6070bc969392b823917d8b998204d5dcbdfe69fec4b442da0#0"
            "addr1q802wxt6cg6aw0nl0vdzfxavu65rxu3yzhvgayw7chfxymduzkt66uw9t5kspx5jwjecx80dz4g33htknafhdhkvzd5st4f9xu"
            []
        )
        ( ScopeJSON
            { sjId = "network_compliance"
            , sjTreasuryAddress =
                "addr1xyezq8wpaqnssdjvd3p220uf7e6nzjae44w6yu625y965rfjyqwur6p8pqmycmzz55lcnan4x99mnt2a5fe54ggt4gxs8thzgk"
            , sjTreasuryUtxos = []
            , sjTreasuryLeftoverLovelace = 0
            , sjTreasuryLeftoverUsdm = 0
            , sjTreasuryLeftoverOtherAssets = Map.empty
            , sjTreasuryScriptHash =
                "32201dc1e82708364c6c42a53f89f675314bb9ad5da2734aa10baa0d"
            , sjPermissionsRewardAccount =
                "a64d1b9e1aeffe54056034d84977061b45a92691efc282fbee3fc094"
            , sjScopesDeployedAt =
                "11ace24a7b0caad4a68a38ef2fff18185dc9ea604e84425dab487cae94e4cf54#0"
            , sjPermissionsDeployedAt =
                "25ba96f5deb14bb5c56e7542d6a9ba8450f52cc698ebd74574e1a0525d861095#2"
            , sjTreasuryDeployedAt =
                "810bfcbde85ae72f27d7e8cd154c03c802de15d3fa0dd83a32a4b0fdba330b3c#0"
            , sjRegistryDeployedAt =
                "e7b395a93d49a17994d66df0e4778a01dee05e7711e6612f28d97b63e4e6311c#2"
            , sjRegistryPolicyId =
                "38c627d45835744a2d6c727124f2b5852e5564aeab3f608e0e84ea6d"
            }
        )
        []
        186_796_799
        ( RationaleJSON
            "withdraw"
            "Withdraw treasury rewards"
            "Pull accrued rewards"
            "Treasury accounting"
            "Network Compliance treasury"
        )
        ( WithdrawInputs
            "32201dc1e82708364c6c42a53f89f675314bb9ad5da2734aa10baa0d"
            12_500_000_000
        )

isInfixOf :: String -> String -> Bool
isInfixOf needle haystack =
    any (needle `prefixOf`) (tails haystack)
  where
    prefixOf [] _ = True
    prefixOf _ [] = False
    prefixOf (x : xs) (y : ys) = x == y && prefixOf xs ys

    tails :: [a] -> [[a]]
    tails [] = [[]]
    tails xs@(_ : rest) = xs : tails rest
