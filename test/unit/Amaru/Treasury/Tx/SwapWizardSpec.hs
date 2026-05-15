{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : Amaru.Treasury.Tx.SwapWizardSpec
Description : Pure-translation tests for the swap wizard
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Loads the fixture 'WizardEnv' and 'SwapWizardQ' from
@test/fixtures/swap-wizard/@, runs
'wizardToTreasuryIntent', and asserts:

  * each contracted field carries the expected value per
    @specs\/002-swap-wizard\/data-model.md §4@;
  * the encoded JSON round-trips through
    'decodeTreasuryIntent' and 'translateIntent' (i.e. the
    unified @tx-build@ subcommand accepts what the wizard
    produced);
  * 'WizardError' constructors fire on the documented
    failure shapes.
-}
module Amaru.Treasury.Tx.SwapWizardSpec (spec) where

import Data.Aeson (FromJSON, eitherDecodeFileStrict)
import Data.ByteString.Lazy qualified as BSL
import Data.Char (isDigit)
import Data.Either (isLeft, isRight)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec
    ( Spec
    , describe
    , it
    , runIO
    , shouldBe
    , shouldSatisfy
    )

import Cardano.Ledger.BaseTypes (Network (..))

import Amaru.Treasury.IntentJSON
    ( RationaleJSON (..)
    , SAction (..)
    , ScopeJSON (..)
    , SomeTreasuryIntent (..)
    , SwapInputs (..)
    , TreasuryIntent (..)
    , WalletJSON (..)
    , decodeTreasuryIntent
    , encodeSomeTreasuryIntent
    , translateIntent
    )
import Amaru.Treasury.LedgerParse
    ( addrFromText
    , keyHashFromHex
    , scriptHashFromHex
    , txInFromText
    )
import Amaru.Treasury.Registry.Verify
    ( VerifiedRegistry (..)
    , VerifiedScope (..)
    )
import Amaru.Treasury.Scope (ScopeId (..))
import Amaru.Treasury.Tx.SwapWizard
    ( AllAdaError (..)
    , AllAdaPlan (..)
    , NetworkConstants (..)
    , RegistryView (..)
    , ResolverAllAdaInput (..)
    , ResolverEnv (..)
    , ResolverError (..)
    , ResolverInput (..)
    , ScopeOwners (..)
    , SwapWizardQ (..)
    , TreasuryRefs (..)
    , WalletSelection (..)
    , WalletSelectionError (..)
    , WizardEnv (..)
    , WizardError (..)
    , addrNetwork
    , chunkLovelaces
    , networkConstants
    , planAllAda
    , registryViewFromVerified
    , renderWalletShortfall
    , resolveWizardEnv
    , resolveWizardEnvAllAda
    , selectTreasury
    , selectWallet
    , wizardToTreasuryIntent
    )
import Test.QuickCheck
    ( Positive (..)
    , property
    , (===)
    )

import Options.Applicative
    ( ParserResult (..)
    , defaultPrefs
    , execParserPure
    , info
    )

import Amaru.Treasury.Cli.SwapWizard
    ( wizardOptsP
    )
import Amaru.Treasury.Constants
    ( minUtxoDepositLovelace
    , sundaeOrderAddressMainnet
    , sundaeProtocolFeeLovelace
    , sundaeUsdmPoolHex
    , usdmAssetHex
    , usdmPolicyHex
    )
import Amaru.Treasury.Tx.SwapWizard.Trace
    ( WizardEvent (..)
    , renderEvent
    )

spec :: Spec
spec = describe "SwapWizard" $ do
    env :: WizardEnv <-
        runIO (loadFixture "test/fixtures/swap-wizard/env.json")
    answers :: SwapWizardQ <-
        runIO (loadFixture "test/fixtures/swap-wizard/answers.json")

    describe "wizardToTreasuryIntent" $ do
        it "produces a TreasuryIntent 'Swap" $ do
            wizardToTreasuryIntent env answers
                `shouldSatisfy` isRight

        it "preserves the wallet selection" $ do
            let Right intent = wizardToTreasuryIntent env answers
                w = tiWallet intent
            wjTxIn w
                `shouldBe` "42e4c279036e3ab6070bc969392b823917d8b998204d5dcbdfe69fec4b442da0#0"
            wjAddress w
                `shouldBe` "addr1q802wxt6cg6aw0nl0vdzfxavu65rxu3yzhvgayw7chfxymduzkt66uw9t5kspx5jwjecx80dz4g33htknafhdhkvzd5st4f9xu"

        it "preserves the scope refs and selection" $ do
            let Right intent = wizardToTreasuryIntent env answers
                s = tiScope intent
            sjId s `shouldBe` "core_development"
            sjTreasuryAddress s
                `shouldBe` "addr1xyezq8wpaqnssdjvd3p220uf7e6nzjae44w6yu625y965rfjyqwur6p8pqmycmzz55lcnan4x99mnt2a5fe54ggt4gxs8thzgk"
            sjTreasuryUtxos s
                `shouldBe` ["64f27254f3c0311fb2e672cdb87de200089a596aa90dc09f8be4248540267cf0#0"]
            sjTreasuryLeftoverLovelace s
                `shouldBe` 1041728494694
            sjTreasuryLeftoverUsdm s `shouldBe` 0
            sjTreasuryLeftoverOtherAssets s
                `shouldBe` Map.empty
            sjTreasuryScriptHash s
                `shouldBe` "32201dc1e82708364c6c42a53f89f675314bb9ad5da2734aa10baa0d"
            sjPermissionsRewardAccount s
                `shouldBe` "a64d1b9e1aeffe54056034d84977061b45a92691efc282fbee3fc094"
            sjRegistryPolicyId s
                `shouldBe` "38c627d45835744a2d6c727124f2b5852e5564aeab3f608e0e84ea6d"

        it "applies the network constants and answers in the swap block" $ do
            let Right intent = wizardToTreasuryIntent env answers
                sw = tiPayload intent
            swiSwapOrderAddress sw
                `shouldBe` sundaeOrderAddressMainnet
            swiChunkSizeLovelace sw `shouldBe` 12500000000
            swiAmountLovelace sw `shouldBe` 408163265306
            swiExtraPerChunkLovelace sw
                `shouldBe` ( sundaeProtocolFeeLovelace
                                + minUtxoDepositLovelace
                           )
            swiRateNumerator sw `shouldBe` 245
            swiRateDenominator sw `shouldBe` 1000
            swiSundaeProtocolFeeLovelace sw
                `shouldBe` sundaeProtocolFeeLovelace
            swiPoolId sw `shouldBe` sundaeUsdmPoolHex
            swiCoreOwner sw
                `shouldBe` "7095faf3d48d582fbae8b3f2e726670d7a35e2400c783d992bbdeffb"
            swiOpsOwner sw
                `shouldBe` "f3ab64b0f97dcf0f91232754603283df5d75a1201337432c04d23e2e"
            swiNetworkComplianceOwner sw
                `shouldBe` "8bd03209d227956aaf9670751e0aa2057b51c1537a43f155b24fb1c1"
            swiMiddlewareOwner sw
                `shouldBe` "97e0f6d6c86dbebf15cc8fdf0981f939b2f2b70928a46511edd49df2"
            swiUsdmPolicy sw `shouldBe` usdmPolicyHex
            swiUsdmToken sw `shouldBe` usdmAssetHex

        it "carries the resolved network at the top level" $ do
            let Right intent = wizardToTreasuryIntent env answers
            tiNetwork intent `shouldBe` "mainnet"
            tiSchema intent `shouldBe` 1

        it "infers the scope owner and appends extra signer scopes" $ do
            let Right intent = wizardToTreasuryIntent env answers
            tiSigners intent
                `shouldBe` [ "7095faf3d48d582fbae8b3f2e726670d7a35e2400c783d992bbdeffb"
                           , "8bd03209d227956aaf9670751e0aa2057b51c1537a43f155b24fb1c1"
                           ]

        it "defaults signers to the selected scope owner" $ do
            let Right intent =
                    wizardToTreasuryIntent
                        env
                        answers{wqExtraSigners = []}
            tiSigners intent
                `shouldBe` [ "7095faf3d48d582fbae8b3f2e726670d7a35e2400c783d992bbdeffb"
                           ]

        it "accepts raw key hashes for extra signers" $ do
            let Right intent =
                    wizardToTreasuryIntent
                        env
                        answers
                            { wqExtraSigners =
                                [ "f3ab64b0f97dcf0f91232754603283df5d75a1201337432c04d23e2e"
                                ]
                            }
            tiSigners intent
                `shouldBe` [ "7095faf3d48d582fbae8b3f2e726670d7a35e2400c783d992bbdeffb"
                           , "f3ab64b0f97dcf0f91232754603283df5d75a1201337432c04d23e2e"
                           ]

        it "deduplicates an explicitly repeated scope owner" $ do
            let Right intent =
                    wizardToTreasuryIntent
                        env
                        answers
                            { wqExtraSigners =
                                [ "core_development"
                                , "network_compliance"
                                , "7095faf3d48d582fbae8b3f2e726670d7a35e2400c783d992bbdeffb"
                                ]
                            }
            tiSigners intent
                `shouldBe` [ "7095faf3d48d582fbae8b3f2e726670d7a35e2400c783d992bbdeffb"
                           , "8bd03209d227956aaf9670751e0aa2057b51c1537a43f155b24fb1c1"
                           ]

        it "computes validityUpperBoundSlot from tip + slotsPerHour * hours" $ do
            let Right intent = wizardToTreasuryIntent env answers
            -- 186342942 + 3600 * 6 = 186364542
            tiValidityUpperBoundSlot intent `shouldBe` 186364542

        it "applies rationale defaults for absent event/label" $ do
            let Right intent = wizardToTreasuryIntent env answers
                r = tiRationale intent
            rjEvent r `shouldBe` "disburse"
            rjLabel r `shouldBe` "Swap ADA<->USDM"
            rjDescription r
                `shouldBe` "Swapping ADA for $100k at a rate of $0.245 per ADA"
            rjDestinationLabel r
                `shouldBe` "Network Compliance's treasury"
            rjJustification r
                `shouldBe` "Required to pay Antithesis as vendor"

    describe "round-trip" $ do
        it "encoded JSON parses + translates" $ do
            let Right intent = wizardToTreasuryIntent env answers
                bytes =
                    encodeSomeTreasuryIntent
                        (SomeTreasuryIntent SSwap intent)
            case decodeTreasuryIntent bytes of
                Left e ->
                    expectationFailure'
                        ( "decodeTreasuryIntent failed: " <> e
                        )
                Right (SomeTreasuryIntent sa parsed) ->
                    case translateIntent sa parsed of
                        Left e ->
                            expectationFailure'
                                ( "translateIntent failed: "
                                    <> e
                                )
                        Right _ -> pure ()

        it "matches golden expected.intent.json" $ do
            let Right intent = wizardToTreasuryIntent env answers
                bytes =
                    encodeSomeTreasuryIntent
                        (SomeTreasuryIntent SSwap intent)
                goldenPath =
                    "test/fixtures/swap-wizard/expected.intent.json"
            existing <- BSL.readFile goldenPath
            bytes `shouldBe` existing

    describe "registryViewFromVerified" $ do
        it "projects verified local metadata into the wizard registry view" $ do
            view <-
                expectRight $
                    registryViewFromVerified
                        CoreDevelopment
                        verifiedRegistryFixture
            refs <-
                expectJust "missing core_development refs" $
                    Map.lookup CoreDevelopment (rvTreasuryByScope view)
            let owners = rvOwners view
            rvScopesDeployedAt view
                `shouldBe` "11ace24a7b0caad4a68a38ef2fff18185dc9ea604e84425dab487cae94e4cf54#0"
            rvTreasuryDeployedAt view
                `shouldBe` "87ee53271fb41021efa13c2dbe2998c18ead07d32a6ab6dda184853ed7e39aae#0"
            rvPermissionsDeployedAt view
                `shouldBe` "25ba96f5deb14bb5c56e7542d6a9ba8450f52cc698ebd74574e1a0525d861095#0"
            rvRegistryDeployedAt view
                `shouldBe` "e7b395a93d49a17994d66df0e4778a01dee05e7711e6612f28d97b63e4e6311c#0"
            rvRegistryPolicyId view
                `shouldBe` "1e1ee91b8e2bddc9d583d92fd1ba5ea47b8a3e62c1eacb0ec799b99b"
            soCore owners
                `shouldBe` "7095faf3d48d582fbae8b3f2e726670d7a35e2400c783d992bbdeffb"
            soOps owners
                `shouldBe` "f3ab64b0f97dcf0f91232754603283df5d75a1201337432c04d23e2e"
            trAddress refs
                `shouldBe` "addr1x90mk0jjjhppr36ethwj8kewpgyrxyc7q6qucl4gqru96dzlhvl999wzz8r4jhway0djuzsgxvf3up5pe3l2sq8ct56qtjz6ah"
            trScriptHash refs
                `shouldBe` "5fbb3e5295c211c7595ddd23db2e0a0833131e0681cc7ea800f85d34"
            trPermissionsRewardAccount refs `shouldSatisfy` isHex28

    describe "validation" $ do
        let leftIs e q =
                case wizardToTreasuryIntent env q of
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
        it "rejects validity hours = Just 0" $ do
            leftIs
                WizardValidityHoursZero
                answers{wqValidityHours = Just 0}
        it "accepts validity hours = Nothing (AutoLongest)" $ do
            case wizardToTreasuryIntent
                env
                answers{wqValidityHours = Nothing} of
                Right _ -> pure ()
                Left e ->
                    expectationFailure'
                        ( "expected Right for Nothing, got Left "
                            <> show e
                        )
        it "accepts arbitrarily large validity hours" $ do
            -- The wizard no longer enforces a static cap.
            -- The chain horizon does — and is enforced by the
            -- resolver, not the pure translator.
            case wizardToTreasuryIntent
                env
                answers{wqValidityHours = Just 999} of
                Right _ -> pure ()
                Left e ->
                    expectationFailure'
                        ( "expected Right for Just 999, got Left "
                            <> show e
                        )
        it "rejects rate denominator = 0" $ do
            leftIs
                WizardRateDenominatorZero
                answers{wqRateDenominator = 0}
        it "rejects unknown extra signer tokens" $ do
            leftIs
                (WizardSignerNotScopeOrHex28 "zz")
                answers{wqExtraSigners = ["zz"]}

    describe "chunkLovelaces" $ do
        it "dust-fold split-33" $
            chunkLovelaces 408_163_265_306 12_368_583_797
                `shouldBe` replicate 5 12_368_583_798
                    <> replicate 28 12_368_583_797
        it "clean divide" $
            chunkLovelaces 100 25 `shouldBe` [25, 25, 25, 25]
        it "tiny rem distributes" $
            chunkLovelaces 7 2 `shouldBe` [3, 2, 2]
        it "chunk-usdm large rem stays separate" $
            chunkLovelaces 408_163_265_306 12_500_000_000
                `shouldBe` replicate 32 12_500_000_000
                    <> [8_163_265_306]
        it "amount < chunkSize" $
            chunkLovelaces 7 100 `shouldBe` [7]
        it "non-positive chunkSize" $
            chunkLovelaces 100 0 `shouldBe` []
        it "sum invariant" $
            property $ \(Positive a) (Positive c) ->
                sum (chunkLovelaces a c) === a

    describe "networkConstants" $ do
        it "returns a row for mainnet" $
            case networkConstants "mainnet" of
                Right _ -> pure ()
                Left e -> expectationFailure' e
        it "rejects unknown networks" $
            case networkConstants "narnia" of
                Left _ -> pure ()
                Right _ ->
                    expectationFailure'
                        "unexpected Right for narnia"

    describe "planAllAda" $ do
        it
            "spends every available pure ADA lovelace except overhead and minimum leftover"
            $ do
                nc <- expectRight (networkConstants "mainnet")
                let available = 52_821_860_941
                    rateNum = 262_350
                    rateDen = 1_000_000
                    Right plan =
                        planAllAda
                            nc
                            1
                            (rateNum, rateDen)
                            [
                                ( "22e914892e83c22e19514937914ca32a0c059f9d1c5b555429edde0ea3406ae4#5"
                                , available
                                , False
                                )
                            ]
                    expectedOverhead =
                        ncExtraPerChunkLovelace nc
                    expectedAmount =
                        available
                            - expectedOverhead
                            - minUtxoDepositLovelace
                aapSelectedTreasuryUtxos plan
                    `shouldBe` [ "22e914892e83c22e19514937914ca32a0c059f9d1c5b555429edde0ea3406ae4#5"
                               ]
                aapAvailableLovelace plan `shouldBe` available
                aapAmountLovelace plan `shouldBe` expectedAmount
                aapChunkSizeLovelace plan `shouldBe` expectedAmount
                aapChunkCount plan `shouldBe` 1
                aapOverheadLovelace plan `shouldBe` expectedOverhead
                aapLeftoverLovelace plan
                    `shouldBe` minUtxoDepositLovelace
                aapImpliedUsdm plan
                    `shouldBe` ceilingDiv (expectedAmount * rateNum) rateDen

        it "ignores token-bearing treasury UTxOs in all-ADA mode" $ do
            nc <- expectRight (networkConstants "mainnet")
            let Right plan =
                    planAllAda
                        nc
                        1
                        (1, 1)
                        [ ("token-bearing#0", 999_000_000, True)
                        , ("pure#1", 10_000_000, False)
                        ]
            aapSelectedTreasuryUtxos plan `shouldBe` ["pure#1"]
            aapAvailableLovelace plan `shouldBe` 10_000_000

        it
            "rejects a pure ADA balance that cannot cover overhead, leftover, and one lovelace"
            $ do
                nc <- expectRight (networkConstants "mainnet")
                let available =
                        ncExtraPerChunkLovelace nc
                            + minUtxoDepositLovelace
                    result =
                        planAllAda
                            nc
                            1
                            (1, 1)
                            [("pure#0", available, False)]
                result
                    `shouldBe` Left
                        ( AllAdaInsufficientLovelace
                            available
                            (available + 1)
                        )

        it "rejects a split count larger than the derived lovelace amount" $ do
            nc <- expectRight (networkConstants "mainnet")
            let split = 2
                required =
                    toInteger split
                        * ncExtraPerChunkLovelace nc
                        + minUtxoDepositLovelace
                        + toInteger split
                available = required - 1
            planAllAda
                nc
                split
                (1, 1)
                [("pure#0", available, False)]
                `shouldBe` Left
                    ( AllAdaInsufficientLovelace
                        available
                        required
                    )

    describe "addrNetwork" $ do
        it "classifies any addr_test1 address as Testnet" $
            addrNetwork
                "addr_test1xyezq8wpaqnssdjvd3p220uf7e6n"
                `shouldBe` Just Testnet
        it "classifies addr1 as Mainnet" $
            addrNetwork
                "addr1q802wxt6cg6aw0nl0vdzfxavu65rxu3y"
                `shouldBe` Just Mainnet
        it "rejects bare bech32" $
            addrNetwork "stake1xyz" `shouldBe` Nothing

    describe "selectTreasury" $ do
        it "is largest-first and totals to leftover" $
            property $ \(ps :: [Positive Integer]) ->
                let ls = [getPositive p | p <- ps]
                    inputs =
                        zip
                            (map (\i -> "u" <> tShow i) [(0 :: Int) ..])
                            ls
                    target =
                        if null ls
                            then 0
                            else sum ls `div` 2
                in  case selectTreasury inputs target of
                        Nothing ->
                            sum (snd <$> inputs) < target
                        Just (picked, leftover) ->
                            let pickedSum =
                                    sum
                                        [ l
                                        | (r, l) <- inputs
                                        , r `elem` picked
                                        ]
                            in  pickedSum >= target
                                    && leftover
                                        == pickedSum - target

    describe "selectWallet" $ do
        it "ignores entries with native assets" $
            selectWallet
                100
                [ ("a", 100, True)
                , ("b", 200, True)
                ]
                `shouldBe` Left WalletNoPureAda
        it "single UTxO covers the target" $
            selectWallet
                100
                [ ("a", 200, False)
                , ("b", 50, False)
                ]
                `shouldBe` Right (["a"], 200)
        it "two UTxOs needed: largest first, smaller second" $
            selectWallet
                300
                [ ("a", 100, False)
                , ("b", 250, False)
                ]
                `shouldBe` Right (["b", "a"], 350)
        it "stops once the cumulative meets the target" $
            selectWallet
                300
                [ ("a", 250, False)
                , ("b", 100, False)
                , ("c", 50, False)
                ]
                `shouldBe` Right (["a", "b"], 350)
        it "sorts by ADA descending regardless of input order" $ do
            let unsorted =
                    [ ("c", 50, False)
                    , ("a", 250, False)
                    , ("b", 100, False)
                    ]
            selectWallet 300 unsorted
                `shouldBe` Right (["a", "b"], 350)
        it "shortfall when total is one lovelace short" $
            selectWallet
                301
                [ ("a", 250, False)
                , ("b", 50, False)
                ]
                `shouldBe` Left (WalletShortfall 300 301)
        it "succeeds when total available equals the target" $
            selectWallet
                300
                [ ("a", 250, False)
                , ("b", 50, False)
                ]
                `shouldBe` Right (["a", "b"], 300)

    describe "resolveWizardEnv (stub Provider)" $ do
        it "produces a WizardEnv whose translation matches the golden" $ do
            let stub =
                    ResolverEnv
                        { reEnvQueryWalletUtxos = \_ ->
                            pure
                                [
                                    ( "42e4c279036e3ab6070bc969392b823917d8b998204d5dcbdfe69fec4b442da0#0"
                                    , 1_000_000_000
                                    , False
                                    )
                                ]
                        , reEnvQueryTreasuryUtxos = \_ ->
                            pure
                                [
                                    ( "64f27254f3c0311fb2e672cdb87de200089a596aa90dc09f8be4248540267cf0#0"
                                    , 1_450_000_000_000
                                    , False
                                    )
                                ]
                        , reEnvComputeUpperBound = \_ -> pure (Right 186364542)
                        }
                ri =
                    ResolverInput
                        { riNetwork = "mainnet"
                        , riWalletAddrBech32 =
                            "addr1q802wxt6cg6aw0nl0vdzfxavu65rxu3yzhvgayw7chfxymduzkt66uw9t5kspx5jwjecx80dz4g33htknafhdhkvzd5st4f9xu"
                        , riScope = CoreDevelopment
                        , riAmountLovelace = 408163265306
                        , riChunkSizeLovelace = 12500000000
                        , riRegistry = weRegistry env
                        , riValidityHours = Nothing
                        }
            r <- resolveWizardEnv stub ri
            case r of
                Left e -> expectationFailure' (show e)
                Right env' -> do
                    -- the resolver-derived env should
                    -- carry the same scope view, treasury
                    -- selection, and wallet selection that
                    -- the fixture env has, so feeding it
                    -- through wizardToTreasuryIntent yields
                    -- the same byte-for-byte output.
                    let envOverMainnet =
                            env'
                                { weNetwork = "mainnet"
                                , weWalletSelection =
                                    (weWalletSelection env')
                                        { wsAddress =
                                            -- match fixture
                                            wsAddress
                                                ( weWalletSelection
                                                    env
                                                )
                                        }
                                }
                    case wizardToTreasuryIntent envOverMainnet answers of
                        Left e ->
                            expectationFailure'
                                (show e)
                        Right intent ->
                            encodeSomeTreasuryIntent
                                ( SomeTreasuryIntent
                                    SSwap
                                    intent
                                )
                                `shouldBe` encodeSomeTreasuryIntent
                                    ( SomeTreasuryIntent
                                        SSwap
                                        ( case wizardToTreasuryIntent
                                            env
                                            answers of
                                            Right x -> x
                                            Left _ ->
                                                error
                                                    "fixture broken"
                                        )
                                    )

        it "rejects network mismatch" $ do
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
                        , -- preprod wallet on mainnet request
                          riWalletAddrBech32 =
                            "addr_test1q802wxt6cg6aw0nl0vdzfxavu65rxu3yzhvgayw7chfxymduzkt66uw9t5kspx5jwjecx80dz4g33htknafhdhkvzd5st4f9xu"
                        , riScope = CoreDevelopment
                        , riAmountLovelace = 1
                        , riChunkSizeLovelace = 1
                        , riRegistry = weRegistry env
                        , riValidityHours = Nothing
                        }
            r <- resolveWizardEnv stub ri
            r
                `shouldBe` Left
                    ( ResolverNetworkMismatch
                        "mainnet"
                        "testnet"
                    )

        it
            "accepts a small wallet when the treasury covers per-chunk overhead"
            $ do
                let walletRef =
                        "42e4c279036e3ab6070bc969392b823917d8b998204d5dcbdfe69fec4b442da0#0"
                    stub =
                        ResolverEnv
                            { reEnvQueryWalletUtxos = \_ ->
                                pure [(walletRef, 5_000_000, False)]
                            , reEnvQueryTreasuryUtxos = \_ ->
                                pure
                                    [
                                        ( "64f27254f3c0311fb2e672cdb87de200089a596aa90dc09f8be4248540267cf0#0"
                                        , 1_450_000_000_000
                                        , False
                                        )
                                    ]
                            , reEnvComputeUpperBound = \_ -> pure (Right 186364542)
                            }
                    ri =
                        ResolverInput
                            { riNetwork = "mainnet"
                            , riWalletAddrBech32 =
                                "addr1q802wxt6cg6aw0nl0vdzfxavu65rxu3yzhvgayw7chfxymduzkt66uw9t5kspx5jwjecx80dz4g33htknafhdhkvzd5st4f9xu"
                            , riScope = CoreDevelopment
                            , riAmountLovelace = 408163265306
                            , riChunkSizeLovelace = 12500000000
                            , riRegistry = weRegistry env
                            , riValidityHours = Nothing
                            }
                r <- resolveWizardEnv stub ri
                case r of
                    Left e -> expectationFailure' (show e)
                    Right env' -> do
                        wsTxIn (weWalletSelection env') `shouldBe` walletRef
                        wsExtraTxIns (weWalletSelection env') `shouldBe` []

        it
            "reports a typed wallet shortfall when pure-ADA total is below target"
            $ do
                let stub =
                        ResolverEnv
                            { reEnvQueryWalletUtxos = \_ ->
                                pure
                                    [
                                        ( "42e4c279036e3ab6070bc969392b823917d8b998204d5dcbdfe69fec4b442da0#0"
                                        , 1_000_000
                                        , False
                                        )
                                    ]
                            , reEnvQueryTreasuryUtxos = \_ ->
                                pure
                                    [
                                        ( "64f27254f3c0311fb2e672cdb87de200089a596aa90dc09f8be4248540267cf0#0"
                                        , 1_450_000_000_000
                                        , False
                                        )
                                    ]
                            , reEnvComputeUpperBound = \_ -> pure (Right 186364542)
                            }
                    ri =
                        ResolverInput
                            { riNetwork = "mainnet"
                            , riWalletAddrBech32 =
                                "addr1q802wxt6cg6aw0nl0vdzfxavu65rxu3yzhvgayw7chfxymduzkt66uw9t5kspx5jwjecx80dz4g33htknafhdhkvzd5st4f9xu"
                            , riScope = CoreDevelopment
                            , riAmountLovelace = 408163265306
                            , riChunkSizeLovelace = 12500000000
                            , riRegistry = weRegistry env
                            , riValidityHours = Nothing
                            }
                r <- resolveWizardEnv stub ri
                case r of
                    Left (ResolverWalletShortfall avail req) -> do
                        -- amount=408_163_265_306,
                        -- chunkSize=12_500_000_000
                        --   → full=32, rem=663_265_306, chunks=33.
                        avail `shouldBe` 1_000_000
                        req `shouldBe` 2_000_000
                    other ->
                        expectationFailure'
                            ( "expected ResolverWalletShortfall, got: "
                                <> show other
                            )

        it "rejects riChunkSizeLovelace = 0" $ do
            let stub =
                    ResolverEnv
                        { reEnvQueryWalletUtxos = \_ ->
                            pure
                                [
                                    ( "42e4c279036e3ab6070bc969392b823917d8b998204d5dcbdfe69fec4b442da0#0"
                                    , 1_000_000_000
                                    , False
                                    )
                                ]
                        , reEnvQueryTreasuryUtxos = \_ ->
                            pure
                                [
                                    ( "64f27254f3c0311fb2e672cdb87de200089a596aa90dc09f8be4248540267cf0#0"
                                    , 1_450_000_000_000
                                    , False
                                    )
                                ]
                        , reEnvComputeUpperBound = \_ -> pure (Right 186364542)
                        }
                ri =
                    ResolverInput
                        { riNetwork = "mainnet"
                        , riWalletAddrBech32 =
                            "addr1q802wxt6cg6aw0nl0vdzfxavu65rxu3yzhvgayw7chfxymduzkt66uw9t5kspx5jwjecx80dz4g33htknafhdhkvzd5st4f9xu"
                        , riScope = CoreDevelopment
                        , riAmountLovelace = 408163265306
                        , riChunkSizeLovelace = 0
                        , riRegistry = weRegistry env
                        , riValidityHours = Nothing
                        }
            r <- resolveWizardEnv stub ri
            r
                `shouldBe` Left
                    (ResolverInvalidChunkSize 0)

        it
            "derives all-ADA mode and translates through the unified intent path"
            $ do
                nc <- expectRight (networkConstants "mainnet")
                let treasuryRef =
                        "64f27254f3c0311fb2e672cdb87de200089a596aa90dc09f8be4248540267cf0#0"
                    available = 52_821_860_941
                    walletRef =
                        "42e4c279036e3ab6070bc969392b823917d8b998204d5dcbdfe69fec4b442da0#0"
                    rateNum = 262_350
                    rateDen = 1_000_000
                    stub =
                        ResolverEnv
                            { reEnvQueryWalletUtxos = \_ ->
                                pure [(walletRef, 5_000_000, False)]
                            , reEnvQueryTreasuryUtxos = \_ ->
                                pure
                                    [ (treasuryRef, available, False)
                                    , ("token-bearing#1", 10_000_000, True)
                                    ]
                            , reEnvComputeUpperBound = \_ ->
                                pure (Right 186364542)
                            }
                    rai =
                        ResolverAllAdaInput
                            { raiNetwork = "mainnet"
                            , raiWalletAddrBech32 =
                                "addr1q802wxt6cg6aw0nl0vdzfxavu65rxu3yzhvgayw7chfxymduzkt66uw9t5kspx5jwjecx80dz4g33htknafhdhkvzd5st4f9xu"
                            , raiScope = CoreDevelopment
                            , raiSplit = 1
                            , raiRateNumerator = rateNum
                            , raiRateDenominator = rateDen
                            , raiRegistry = weRegistry env
                            , raiValidityHours = Nothing
                            }
                r <- resolveWizardEnvAllAda stub rai
                case r of
                    Left e -> expectationFailure' (show e)
                    Right (env', plan) -> do
                        aapSelectedTreasuryUtxos plan
                            `shouldBe` [treasuryRef]
                        aapAmountLovelace plan
                            `shouldBe` available
                                - ncExtraPerChunkLovelace nc
                                - minUtxoDepositLovelace
                        let allAdaAnswers =
                                answers
                                    { wqAmountLovelace =
                                        aapAmountLovelace plan
                                    , wqChunkSizeLovelace =
                                        aapChunkSizeLovelace plan
                                    , wqRateNumerator = rateNum
                                    , wqRateDenominator = rateDen
                                    }
                        intent <-
                            expectRight $
                                wizardToTreasuryIntent env' allAdaAnswers
                        let bytes =
                                encodeSomeTreasuryIntent
                                    (SomeTreasuryIntent SSwap intent)
                        case decodeTreasuryIntent bytes of
                            Left e ->
                                expectationFailure' e
                            Right (SomeTreasuryIntent sa parsed) ->
                                case translateIntent sa parsed of
                                    Left e ->
                                        expectationFailure' e
                                    Right _ -> pure ()

    describe "swap-wizard CLI parser" $ do
        it "accepts --min-rate alone (expert path)" $
            parseWizardOpts (baseWizardArgs <> ["--min-rate", "0.245"])
                `shouldSatisfy` isRight

        it "accepts --ada-usdm paired with --slippage-bps" $
            parseWizardOpts
                ( baseWizardArgs
                    <> ["--ada-usdm", "0.270", "--slippage-bps", "100"]
                )
                `shouldSatisfy` isRight

        it "rejects --ada-usdm without --slippage-bps" $
            parseWizardOpts (baseWizardArgs <> ["--ada-usdm", "0.270"])
                `shouldSatisfy` isLeft

        it "rejects --price-source (retired from the wizard)" $
            parseWizardOpts
                ( baseWizardArgs
                    <> [ "--price-source"
                       , "coingecko-ada-usdm"
                       , "--slippage-bps"
                       , "100"
                       ]
                )
                `shouldSatisfy` isLeft

        it "rejects --ada-usd (silent USDM~USD conversion, retired)" $
            parseWizardOpts
                ( baseWizardArgs
                    <> ["--ada-usd", "0.27", "--slippage-bps", "100"]
                )
                `shouldSatisfy` isLeft

        it "accepts --all-ada with --split" $
            parseWizardOpts
                ( allAdaWizardArgs
                    <> ["--ada-usdm", "0.270", "--slippage-bps", "100"]
                )
                `shouldSatisfy` isRight

        it "rejects --all-ada together with --usdm" $
            parseWizardOpts
                ( allAdaWizardArgs
                    <> ["--usdm", "100000"]
                    <> ["--ada-usdm", "0.270", "--slippage-bps", "100"]
                )
                `shouldSatisfy` isLeft

        it "rejects commands with no target mode" $
            parseWizardOpts
                ( targetlessWizardArgs
                    <> ["--ada-usdm", "0.270", "--slippage-bps", "100"]
                )
                `shouldSatisfy` isLeft

        it "rejects --all-ada with --chunk-usdm" $
            parseWizardOpts
                ( targetlessWizardArgs
                    <> [ "--all-ada"
                       , "--chunk-usdm"
                       , "10000"
                       , "--ada-usdm"
                       , "0.270"
                       , "--slippage-bps"
                       , "100"
                       ]
                )
                `shouldSatisfy` isLeft

    describe "WizardEvent all-ADA trace" $ do
        it "renders the derived amount facts" $ do
            let rendered =
                    renderEvent $
                        WeAllAdaPlan
                            ["pure#0"]
                            10_000_000
                            4_720_000
                            4_720_000
                            2_000_000
                            1
                            1
                            3_280_000
                            3_280_000
                            1
                            1
            rendered `shouldContainText` "all-ada"
            rendered `shouldContainText` "pure#0"
            rendered `shouldContainText` "available=10000000"
            rendered `shouldContainText` "amount=4720000"
            rendered `shouldContainText` "impliedUsdm=4720000"
            rendered `shouldContainText` "leftover=2000000"
            rendered `shouldContainText` "split=1"
            rendered `shouldContainText` "chunks=1"
            rendered `shouldContainText` "overhead=3280000"
            rendered `shouldContainText` "rate=1/1"

    describe "renderWalletShortfall"
        $ it
            "produces the operator-facing single-line shape"
        $ let ri =
                ResolverInput
                    { riNetwork = "mainnet"
                    , riWalletAddrBech32 =
                        "addr1q802wxt6cg6aw0nl0vdzfxavu65rxu3yzhvgayw7chfxymduzkt66uw9t5kspx5jwjecx80dz4g33htknafhdhkvzd5st4f9xu"
                    , riScope = CoreDevelopment
                    , riAmountLovelace = 408163265306
                    , riChunkSizeLovelace = 12500000000
                    , riRegistry = weRegistry env
                    , riValidityHours = Nothing
                    }
          in  renderWalletShortfall ri 1_000_000 2_000_000
                `shouldBe` "wallet shortfall at addr1q802wxt6cg6aw0nl0vdzfxavu65rxu3yzhvgayw7chfxymduzkt66uw9t5kspx5jwjecx80dz4g33htknafhdhkvzd5st4f9xu: available=1000000 required=2000000 (feeSlack=2000000)"

tShow :: (Show a) => a -> Text
tShow = T.pack . show

parseWizardOpts :: [String] -> Either String ()
parseWizardOpts args =
    case execParserPure defaultPrefs (info wizardOptsP mempty) args of
        Success _ -> Right ()
        Failure _ -> Left "parse failure"
        CompletionInvoked _ -> Left "completion invoked"

baseWizardArgs :: [String]
baseWizardArgs =
    targetlessWizardArgs
        <> [ "--usdm"
           , "100000"
           , "--split"
           , "33"
           ]

targetlessWizardArgs :: [String]
targetlessWizardArgs =
    [ "--wallet-addr"
    , "addr1test"
    , "--metadata"
    , "metadata.json"
    , "--scope"
    , "network_compliance"
    , "--description"
    , "Treasury swap"
    , "--justification"
    , "Quote-derived execution"
    , "--destination-label"
    , "USDM reserve"
    ]

allAdaWizardArgs :: [String]
allAdaWizardArgs =
    targetlessWizardArgs
        <> [ "--all-ada"
           , "--split"
           , "1"
           ]

loadFixture :: forall a. (FromJSON a) => FilePath -> IO a
loadFixture path = do
    r <- eitherDecodeFileStrict path
    case r of
        Right v -> pure v
        Left e ->
            errorWithoutStackTrace
                ( "loadFixture: " <> path <> ": " <> e
                )

verifiedRegistryFixture :: VerifiedRegistry
verifiedRegistryFixture =
    VerifiedRegistry
        { vrScopesNftUtxo =
            parseFixture
                "scope owners ref"
                txInFromText
                "11ace24a7b0caad4a68a38ef2fff18185dc9ea604e84425dab487cae94e4cf54#00"
        , vrScopesNftPolicy =
            parseFixture
                "scopes policy"
                scriptHashFromHex
                "5a7350fef97581498697d679aa1cbc4fb72f51991bde8ad535614365"
        , vrOwners =
            Map.fromList
                [
                    ( CoreDevelopment
                    , owner "7095faf3d48d582fbae8b3f2e726670d7a35e2400c783d992bbdeffb"
                    )
                ,
                    ( OpsAndUseCases
                    , owner "f3ab64b0f97dcf0f91232754603283df5d75a1201337432c04d23e2e"
                    )
                ,
                    ( NetworkCompliance
                    , owner "8bd03209d227956aaf9670751e0aa2057b51c1537a43f155b24fb1c1"
                    )
                ,
                    ( Middleware
                    , owner "97e0f6d6c86dbebf15cc8fdf0981f939b2f2b70928a46511edd49df2"
                    )
                ]
        , vrTreasuriesByScope =
            Map.singleton CoreDevelopment verifiedCoreDevelopment
        }
  where
    owner =
        parseFixture "owner" keyHashFromHex

verifiedCoreDevelopment :: VerifiedScope
verifiedCoreDevelopment =
    VerifiedScope
        { vsAddress =
            parseFixture
                "treasury address"
                addrFromText
                "addr1x90mk0jjjhppr36ethwj8kewpgyrxyc7q6qucl4gqru96dzlhvl999wzz8r4jhway0djuzsgxvf3up5pe3l2sq8ct56qtjz6ah"
        , vsTreasuryScriptHash =
            scriptHash
                "5fbb3e5295c211c7595ddd23db2e0a0833131e0681cc7ea800f85d34"
        , vsRegistryScriptHash =
            scriptHash
                "1e1ee91b8e2bddc9d583d92fd1ba5ea47b8a3e62c1eacb0ec799b99b"
        , vsPermissionsScriptHash =
            scriptHash
                "03ee9cf951e89fb82c47edbff562ee90be17de85b2c24b451c7e8e39"
        , vsRegistryNftUtxo =
            txIn
                "e7b395a93d49a17994d66df0e4778a01dee05e7711e6612f28d97b63e4e6311c#00"
        , vsTreasuryDeployedAt =
            txIn
                "87ee53271fb41021efa13c2dbe2998c18ead07d32a6ab6dda184853ed7e39aae#00"
        , vsPermissionsDeployedAt =
            txIn
                "25ba96f5deb14bb5c56e7542d6a9ba8450f52cc698ebd74574e1a0525d861095#00"
        , vsRegistryDeployedAt =
            txIn
                "e7b395a93d49a17994d66df0e4778a01dee05e7711e6612f28d97b63e4e6311c#00"
        }
  where
    scriptHash =
        parseFixture "script hash" scriptHashFromHex
    txIn =
        parseFixture "txin" txInFromText

parseFixture
    :: (Show e)
    => String
    -> (Text -> Either e a)
    -> Text
    -> a
parseFixture label parser raw =
    case parser raw of
        Right a -> a
        Left e -> error (label <> ": " <> show e)

isHex28 :: Text -> Bool
isHex28 t =
    T.length t == 56 && T.all isHex t
  where
    isHex c =
        isDigit c
            || (c >= 'a' && c <= 'f')
            || (c >= 'A' && c <= 'F')

expectRight :: (Show e) => Either e a -> IO a
expectRight =
    either (expectationFailure' . show) pure

expectJust :: String -> Maybe a -> IO a
expectJust label =
    maybe (expectationFailure' label) pure

expectationFailure' :: String -> IO a
expectationFailure' = errorWithoutStackTrace

ceilingDiv :: Integer -> Integer -> Integer
ceilingDiv n d = (n + d - 1) `div` d

shouldContainText :: Text -> Text -> IO ()
shouldContainText haystack needle =
    haystack `shouldSatisfy` T.isInfixOf needle
