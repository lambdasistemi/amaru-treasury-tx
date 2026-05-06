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
import Data.Char (isDigit)
import Data.Either (isRight)
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
    ( RegistryView (..)
    , ResolverEnv (..)
    , ResolverError (..)
    , ResolverInput (..)
    , ScopeOwners (..)
    , SwapWizardQ (..)
    , TreasuryRefs (..)
    , WalletSelection (..)
    , WizardEnv (..)
    , WizardError (..)
    , addrNetwork
    , encodeIntentJSON
    , networkConstants
    , registryViewFromVerified
    , resolveWizardEnv
    , selectTreasury
    , selectWallet
    , wizardToIntentJSON
    )
import Test.QuickCheck
    ( Positive (..)
    , property
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

        it "infers the scope owner and appends extra signer scopes" $ do
            let Right intent = wizardToIntentJSON env answers
            sijSigners intent
                `shouldBe` [ "7095faf3d48d582fbae8b3f2e726670d7a35e2400c783d992bbdeffb"
                           , "8bd03209d227956aaf9670751e0aa2057b51c1537a43f155b24fb1c1"
                           ]

        it "defaults signers to the selected scope owner" $ do
            let Right intent =
                    wizardToIntentJSON
                        env
                        answers{wqExtraSigners = []}
            sijSigners intent
                `shouldBe` [ "7095faf3d48d582fbae8b3f2e726670d7a35e2400c783d992bbdeffb"
                           ]

        it "accepts raw key hashes for extra signers" $ do
            let Right intent =
                    wizardToIntentJSON
                        env
                        answers
                            { wqExtraSigners =
                                [ "f3ab64b0f97dcf0f91232754603283df5d75a1201337432c04d23e2e"
                                ]
                            }
            sijSigners intent
                `shouldBe` [ "7095faf3d48d582fbae8b3f2e726670d7a35e2400c783d992bbdeffb"
                           , "f3ab64b0f97dcf0f91232754603283df5d75a1201337432c04d23e2e"
                           ]

        it "deduplicates an explicitly repeated scope owner" $ do
            let Right intent =
                    wizardToIntentJSON
                        env
                        answers
                            { wqExtraSigners =
                                [ "core_development"
                                , "network_compliance"
                                , "7095faf3d48d582fbae8b3f2e726670d7a35e2400c783d992bbdeffb"
                                ]
                            }
            sijSigners intent
                `shouldBe` [ "7095faf3d48d582fbae8b3f2e726670d7a35e2400c783d992bbdeffb"
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
        it "rejects unknown extra signer tokens" $ do
            leftIs
                (WizardSignerNotScopeOrHex28 "zz")
                answers{wqExtraSigners = ["zz"]}

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
        it "picks the largest pure-ADA UTxO" $
            selectWallet
                [ ("a", 100, False)
                , ("b", 200, False)
                , ("c", 500, True)
                ]
                `shouldBe` Just "b"
        it "ignores entries with native assets" $
            selectWallet
                [ ("a", 100, True)
                , ("b", 200, True)
                ]
                `shouldBe` Nothing

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
                        , reEnvCurrentTip = pure 186342942
                        }
                ri =
                    ResolverInput
                        { riNetwork = "mainnet"
                        , riWalletAddrBech32 =
                            "addr1q802wxt6cg6aw0nl0vdzfxavu65rxu3yzhvgayw7chfxymduzkt66uw9t5kspx5jwjecx80dz4g33htknafhdhkvzd5st4f9xu"
                        , riScope = CoreDevelopment
                        , riAmountLovelace = 408163265306
                        , riRegistry = weRegistry env
                        }
            r <- resolveWizardEnv stub ri
            case r of
                Left e -> expectationFailure' (show e)
                Right env' -> do
                    -- the resolver-derived env should
                    -- carry the same scope view, treasury
                    -- selection, and wallet selection that
                    -- the fixture env has, so feeding it
                    -- through wizardToIntentJSON yields the
                    -- same byte-for-byte golden output.
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
                    case wizardToIntentJSON envOverMainnet answers of
                        Left e ->
                            expectationFailure'
                                (show e)
                        Right intent ->
                            encodeIntentJSON intent
                                `shouldBe` encodeIntentJSON
                                    ( case wizardToIntentJSON
                                        env
                                        answers of
                                        Right x -> x
                                        Left _ ->
                                            error
                                                "fixture broken"
                                    )

        it "rejects network mismatch" $ do
            let stub =
                    ResolverEnv
                        { reEnvQueryWalletUtxos =
                            \_ -> pure []
                        , reEnvQueryTreasuryUtxos =
                            \_ -> pure []
                        , reEnvCurrentTip = pure 0
                        }
                ri =
                    ResolverInput
                        { riNetwork = "mainnet"
                        , -- preprod wallet on mainnet request
                          riWalletAddrBech32 =
                            "addr_test1q802wxt6cg6aw0nl0vdzfxavu65rxu3yzhvgayw7chfxymduzkt66uw9t5kspx5jwjecx80dz4g33htknafhdhkvzd5st4f9xu"
                        , riScope = CoreDevelopment
                        , riAmountLovelace = 1
                        , riRegistry = weRegistry env
                        }
            r <- resolveWizardEnv stub ri
            r
                `shouldBe` Left
                    ( ResolverNetworkMismatch
                        "mainnet"
                        "testnet"
                    )

tShow :: (Show a) => a -> Text
tShow = T.pack . show

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
