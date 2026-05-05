{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : Amaru.Treasury.Tx.SwapWizardSpec
Description : Pure-translation tests for the swap wizard
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Loads the fixture 'WizardEnv' and 'SwapWizardQ' from
@test/fixtures/swap-wizard/@, runs 'wizardToIntentJSON',
and asserts:

  * the encoded JSON round-trips through
    'decodeSwapIntent' and
    'translateIntent' (i.e. the existing build path
    accepts what the wizard produced);
  * each contracted field carries the expected value per
    @specs\/002-swap-wizard\/data-model.md §4@;
  * 'WizardError' constructors fire on the documented
    failure shapes.
-}
module Amaru.Treasury.Tx.SwapWizardSpec (spec) where

import Data.Aeson (FromJSON, eitherDecodeFileStrict)
import Data.ByteString.Lazy qualified as BSL
import Data.Either (isRight)
import Test.Hspec
    ( Spec
    , describe
    , it
    , runIO
    , shouldBe
    , shouldSatisfy
    )

import Amaru.Treasury.Tx.SwapIntentJSON
    ( RationaleInputs (..)
    , ScopeInputs (..)
    , SwapInputs (..)
    , SwapIntentJSON (..)
    , Wallet (..)
    , decodeSwapIntent
    , translateIntent
    )
import Amaru.Treasury.Tx.SwapWizard
    ( SwapWizardQ (..)
    , WizardEnv (..)
    , WizardError (..)
    , encodeIntentJSON
    , wizardToIntentJSON
    )

spec :: Spec
spec = describe "SwapWizard" $ do
    env :: WizardEnv <-
        runIO (loadFixture "test/fixtures/swap-wizard/env.json")
    answers :: SwapWizardQ <-
        runIO (loadFixture "test/fixtures/swap-wizard/answers.json")

    describe "wizardToIntentJSON" $ do
        it "produces a SwapIntentJSON" $ do
            wizardToIntentJSON env answers
                `shouldSatisfy` isRight

        it "preserves the wallet selection" $ do
            let Right intent = wizardToIntentJSON env answers
                w = sijWallet intent
            wTxIn w
                `shouldBe` "42e4c279036e3ab6070bc969392b823917d8b998204d5dcbdfe69fec4b442da0#0"
            wAddress w
                `shouldBe` "addr1q802wxt6cg6aw0nl0vdzfxavu65rxu3yzhvgayw7chfxymduzkt66uw9t5kspx5jwjecx80dz4g33htknafhdhkvzd5st4f9xu"

        it "preserves the scope refs and selection" $ do
            let Right intent = wizardToIntentJSON env answers
                s = sijScope intent
            siTreasuryAddress_ s
                `shouldBe` "addr1xyezq8wpaqnssdjvd3p220uf7e6nzjae44w6yu625y965rfjyqwur6p8pqmycmzz55lcnan4x99mnt2a5fe54ggt4gxs8thzgk"
            siTreasuryUtxos_ s
                `shouldBe` ["64f27254f3c0311fb2e672cdb87de200089a596aa90dc09f8be4248540267cf0#0"]
            siTreasuryLeftoverLovelace_ s
                `shouldBe` 1041836734694
            siTreasuryScriptHash_ s
                `shouldBe` "32201dc1e82708364c6c42a53f89f675314bb9ad5da2734aa10baa0d"
            siPermissionsRewardAccount_ s
                `shouldBe` "a64d1b9e1aeffe54056034d84977061b45a92691efc282fbee3fc094"
            siRegistryPolicyId_ s
                `shouldBe` "38c627d45835744a2d6c727124f2b5852e5564aeab3f608e0e84ea6d"

        it "applies the network constants and answers in the swap block" $ do
            let Right intent = wizardToIntentJSON env answers
                sw = sijSwap intent
            swSwapOrderAddress sw
                `shouldBe` "addr1x8ax5k9mutg07p2ngscu3chsauktmstq92z9de938j8nqaejyqwur6p8pqmycmzz55lcnan4x99mnt2a5fe54ggt4gxst7gy3n"
            swChunkSizeLovelace sw `shouldBe` 12500000000
            swAmountLovelace sw `shouldBe` 408163265306
            swExtraPerChunkLovelace sw `shouldBe` 3280000
            swRateNumerator sw `shouldBe` 245
            swRateDenominator sw `shouldBe` 1000
            swSundaeProtocolFeeLovelace sw `shouldBe` 1280000
            swPoolId sw
                `shouldBe` "64f35d26b237ad58e099041bc14c687ea7fdc58969d7d5b66e2540ef"
            swCoreOwner sw
                `shouldBe` "7095faf3d48d582fbae8b3f2e726670d7a35e2400c783d992bbdeffb"
            swOpsOwner sw
                `shouldBe` "f3ab64b0f97dcf0f91232754603283df5d75a1201337432c04d23e2e"
            swNetworkComplianceOwner sw
                `shouldBe` "8bd03209d227956aaf9670751e0aa2057b51c1537a43f155b24fb1c1"
            swMiddlewareOwner sw
                `shouldBe` "97e0f6d6c86dbebf15cc8fdf0981f939b2f2b70928a46511edd49df2"
            swUsdmPolicy sw
                `shouldBe` "c48cbb3d5e57ed56e276bc45f99ab39abe94e6cd7ac39fb402da47ad"
            swUsdmToken sw `shouldBe` "0014df105553444d"

        it "honours the signer override" $ do
            let Right intent = wizardToIntentJSON env answers
            sijSigners intent
                `shouldBe` [ "f3ab64b0f97dcf0f91232754603283df5d75a1201337432c04d23e2e"
                           , "8bd03209d227956aaf9670751e0aa2057b51c1537a43f155b24fb1c1"
                           ]

        it "computes validityUpperBoundSlot from tip + slotsPerHour * hours" $ do
            let Right intent = wizardToIntentJSON env answers
            -- 186342942 + 3600 * 6 = 186364542
            sijValidityUpperBoundSlot intent `shouldBe` 186364542

        it "applies rationale defaults for absent event/label" $ do
            let Right intent = wizardToIntentJSON env answers
                r = sijRationale intent
            riEvent r `shouldBe` "disburse"
            riLabel r `shouldBe` "Swap ADA<->USDM"
            riDescription r
                `shouldBe` "Swapping ADA for $100k at a rate of $0.245 per ADA"
            riDestinationLabel r `shouldBe` "Network Compliance's treasury"
            riJustification r
                `shouldBe` "Required to pay Antithesis as vendor"

    describe "round-trip" $ do
        it "encoded JSON parses + translates" $ do
            let Right intent = wizardToIntentJSON env answers
                bytes = encodeIntentJSON intent
            case decodeSwapIntent bytes of
                Left e ->
                    expectationFailure'
                        ( "decodeSwapIntent failed: " <> e
                        )
                Right parsed ->
                    case translateIntent parsed of
                        Left e ->
                            expectationFailure'
                                ( "translateIntent failed: "
                                    <> e
                                )
                        Right _ -> pure ()

        it "matches golden expected.intent.json" $ do
            let Right intent = wizardToIntentJSON env answers
                bytes = encodeIntentJSON intent
                goldenPath =
                    "test/fixtures/swap-wizard/expected.intent.json"
            existing <- BSL.readFile goldenPath
            bytes `shouldBe` existing

    describe "validation" $ do
        let leftIs e q =
                case wizardToIntentJSON env q of
                    Left e' -> e' `shouldBe` e
                    Right _ ->
                        expectationFailure'
                            ( "expected Left "
                                <> show e
                                <> ", got Right"
                            )
        it "rejects chunk size <= 0" $ do
            leftIs
                WizardChunkSizeNotPositive
                answers{wqChunkSizeLovelace = 0}
        it "rejects chunk size > amount" $ do
            leftIs
                WizardChunkSizeExceedsAmount
                answers
                    { wqChunkSizeLovelace = 999_000_000_000_000
                    }
        it "rejects amount <= 0" $ do
            leftIs
                WizardAmountNotPositive
                answers{wqAmountLovelace = 0}
        it "rejects validity hours = 0" $ do
            leftIs
                (WizardValidityHoursOutOfRange 0)
                answers{wqValidityHours = 0}
        it "rejects validity hours > 48" $ do
            leftIs
                (WizardValidityHoursOutOfRange 49)
                answers{wqValidityHours = 49}
        it "rejects rate denominator = 0" $ do
            leftIs
                WizardRateDenominatorZero
                answers{wqRateDenominator = 0}
        it "rejects malformed signer hex" $ do
            leftIs
                (WizardSignerNotHex28 "zz")
                answers{wqSignersOverride = Just ["zz"]}

loadFixture :: forall a. (Show a, FromJSON a) => FilePath -> IO a
loadFixture path = do
    r <- eitherDecodeFileStrict path
    case r of
        Right v -> pure v
        Left e ->
            errorWithoutStackTrace
                ( "loadFixture: " <> path <> ": " <> e
                )

expectationFailure' :: String -> IO ()
expectationFailure' = errorWithoutStackTrace
