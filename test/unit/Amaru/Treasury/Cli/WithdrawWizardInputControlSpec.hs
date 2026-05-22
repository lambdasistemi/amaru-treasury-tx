{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : Amaru.Treasury.Cli.WithdrawWizardInputControlSpec
Description : RED+GREEN assertions for the @withdraw-wizard@
              @--exclude-utxo@ / @--extra-tx-in@ wiring
              (Slice 4 of #184).
License     : Apache-2.0

Exercises runner-level wiring of
'Amaru.Treasury.Wizard.InputControl' into the
@withdraw-wizard@ subcommand. Assertions sit at the runner
boundary: parsed opts records, contradiction pre-flight,
and 'resolveWithdrawEnvIC' with stub UTxO queries.

T020 — US3 contradiction.
T021 — US1 exclusion filters the wallet pool.
T022 — US2 forced inclusion lands in the withdraw
       intent's @wallet.extraTxIns@.
T023 — US1+US4 shortfall-with-excludes naming + SC-005
       byte stability against the existing withdraw
       fixture.
-}
module Amaru.Treasury.Cli.WithdrawWizardInputControlSpec
    ( spec
    ) where

import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BSL
import Data.Text (Text)
import Data.Text qualified as T
import Options.Applicative
    ( ParserResult (..)
    , defaultPrefs
    , execParserPure
    , info
    )
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldContain
    , shouldSatisfy
    )

import Amaru.Treasury.IntentJSON
    ( SAction (..)
    , SomeTreasuryIntent (..)
    , encodeSomeTreasuryIntent
    , tiWallet
    , wjExtraTxIns
    )
import Amaru.Treasury.Scope (ScopeId (..))
import Amaru.Treasury.Wizard.InputControl
    ( ExclusionSet (..)
    , ForcedInclusionSet (..)
    , InputControlError (..)
    , OutRef
    , outRefText
    , parseOutRef
    )

import Amaru.Treasury.Cli.WithdrawWizard
    ( WithdrawOpts
    , validateWithdrawWizardInputControl
    , withdrawOptsP
    )
import Amaru.Treasury.Tx.WithdrawWizard
    ( InputControlOutcome (..)
    , PoolHit (..)
    , RegistryView
    , WalletSelection (..)
    , WithdrawAnswers (..)
    , WithdrawEnv (..)
    , WithdrawResolverEnv (..)
    , WithdrawResolverError (..)
    , WithdrawResolverInput (..)
    , renderWithdrawExclusionLogLine
    , renderWithdrawWalletShortfallWithExcludes
    , resolveWithdrawEnvIC
    , withdrawToTreasuryIntent
    )

-- ----------------------------------------------------------------------
-- Helpers
-- ----------------------------------------------------------------------

mustParse :: Text -> OutRef
mustParse t = case parseOutRef t of
    Right r -> r
    Left e -> errorWithoutStackTrace (T.unpack e)

eitherDecodeStrict :: (Aeson.FromJSON a) => FilePath -> IO a
eitherDecodeStrict p = do
    bs <- BSL.readFile p
    case Aeson.eitherDecode bs of
        Right v -> pure v
        Left e ->
            errorWithoutStackTrace ("decode " <> p <> ": " <> e)

countOccurrences :: (Eq a) => a -> [a] -> Int
countOccurrences x = length . filter (== x)

walletAddrStr :: String
walletAddrStr =
    "addr1q802wxt6cg6aw0nl0vdzfxavu65rxu3yzhvgayw7chfxymduzkt66uw9t5kspx5jwjecx80dz4g33htknafhdhkvzd5st4f9xu"

walletAddrText :: Text
walletAddrText = T.pack walletAddrStr

-- Parser helpers

baseWithdrawArgs :: [String]
baseWithdrawArgs =
    [ "--wallet-addr"
    , walletAddrStr
    , "--metadata"
    , "/tmp/metadata.json"
    , "--scope"
    , "core_development"
    ]

parseWithdraw :: [String] -> Either String WithdrawOpts
parseWithdraw args =
    case execParserPure
        defaultPrefs
        (info withdrawOptsP mempty)
        args of
        Success a -> Right a
        Failure _ -> Left "parse failed"
        CompletionInvoked _ -> Left "completion invoked"

-- Resolver stub

stubFor
    :: [(Text, Integer, Bool)]
    -> Integer
    -> WithdrawResolverEnv IO
stubFor walletUtxos rewards =
    WithdrawResolverEnv
        { wreQueryWalletUtxos = \_ -> pure walletUtxos
        , wreQueryRewardsLovelace = \_ -> pure rewards
        , wreComputeUpperBound = \_ -> pure (Right 186_468_259)
        }

baseRi :: RegistryView -> WithdrawResolverInput
baseRi registry =
    WithdrawResolverInput
        { wriNetwork = "mainnet"
        , wriWalletAddrBech32 = walletAddrText
        , wriScope = CoreDevelopment
        , wriRegistry = registry
        , wriValidityHours = Nothing
        }

-- ----------------------------------------------------------------------
-- Spec
-- ----------------------------------------------------------------------

spec :: Spec
spec =
    describe
        "withdraw-wizard --exclude-utxo / --extra-tx-in"
        $ do
            let walletRefA = T.replicate 64 "a" <> "#0"
                walletRefB = T.replicate 64 "b" <> "#1"
                outRefA = mustParse walletRefA
                outRefB = mustParse walletRefB

            -- T020 contradiction
            describe "T020 contradiction" $ do
                it "withdraw-wizard fails fast at flag-validation" $ do
                    let argv =
                            baseWithdrawArgs
                                ++ [ "--exclude-utxo"
                                   , T.unpack walletRefA
                                   , "--extra-tx-in"
                                   , T.unpack walletRefA
                                   ]
                    case parseWithdraw argv of
                        Left err ->
                            errorWithoutStackTrace
                                ("expected parse success: " <> err)
                        Right opts ->
                            validateWithdrawWizardInputControl opts
                                `shouldBe` Left
                                    (Contradiction [outRefA])

            -- T021 exclusion filters wallet pool
            describe "T021 exclusion filters the wallet pool" $ do
                it
                    "wallet head is the surviving candidate B after --exclude-utxo A"
                    $ do
                        env :: WithdrawEnv <-
                            eitherDecodeStrict
                                "test/fixtures/withdraw/synthetic/env.json"
                        let ri = baseRi (weRegistry env)
                            stub =
                                stubFor
                                    [ (walletRefA, 5_000_000, False)
                                    , (walletRefB, 5_000_000, False)
                                    ]
                                    12_500_000_000
                        r <-
                            resolveWithdrawEnvIC
                                stub
                                (ExclusionSet [outRefA])
                                (ForcedInclusionSet [])
                                ri
                        case r of
                            Left e ->
                                errorWithoutStackTrace
                                    ("expected Right: " <> show e)
                            Right (env', outcome) -> do
                                wsTxIn (weWalletSelection env')
                                    `shouldBe` walletRefB
                                icoHits outcome
                                    `shouldContain` [(outRefA, WalletOnly)]
                it
                    "renders the operator-facing log line with prefix and [wallet] attribution"
                    $ do
                        renderWithdrawExclusionLogLine
                            "withdraw-wizard"
                            outRefA
                            WalletOnly
                            `shouldBe` ( "withdraw-wizard: excluded utxo "
                                            <> outRefText outRefA
                                            <> " (operator-supplied) [wallet]"
                                       )

            -- T022 forced inclusion lands in wallet.extraTxIns
            describe "T022 forced inclusion lands in intent wallet.extraTxIns" $ do
                it
                    "extra-tx-in ref appears once in wallet.extraTxIns of the withdraw intent"
                    $ do
                        env :: WithdrawEnv <-
                            eitherDecodeStrict
                                "test/fixtures/withdraw/synthetic/env.json"
                        answers :: WithdrawAnswers <-
                            eitherDecodeStrict
                                "test/fixtures/withdraw/synthetic/answers.json"
                        let ri = baseRi (weRegistry env)
                            stub =
                                stubFor
                                    [ (walletRefA, 5_000_000, False)
                                    , (walletRefB, 5_000_000, False)
                                    ]
                                    12_500_000_000
                        r <-
                            resolveWithdrawEnvIC
                                stub
                                (ExclusionSet [])
                                (ForcedInclusionSet [outRefB])
                                ri
                        case r of
                            Left e ->
                                errorWithoutStackTrace
                                    ("expected Right: " <> show e)
                            Right (env', _) -> do
                                wsTxIn (weWalletSelection env')
                                    `shouldBe` walletRefA
                                case withdrawToTreasuryIntent env' answers of
                                    Left we ->
                                        errorWithoutStackTrace (show we)
                                    Right intent -> do
                                        let extras =
                                                wjExtraTxIns (tiWallet intent)
                                        countOccurrences walletRefB extras
                                            `shouldBe` 1

            -- T023 shortfall with excludes + byte stability
            describe "T023 shortfall with excludes + byte stability" $ do
                it
                    "wallet-side filtering all candidates surfaces shortfall naming the excluded ref"
                    $ do
                        env :: WithdrawEnv <-
                            eitherDecodeStrict
                                "test/fixtures/withdraw/synthetic/env.json"
                        let ri = baseRi (weRegistry env)
                            stub =
                                stubFor
                                    [(walletRefA, 5_000_000, False)]
                                    12_500_000_000
                        r <-
                            resolveWithdrawEnvIC
                                stub
                                (ExclusionSet [outRefA])
                                (ForcedInclusionSet [])
                                ri
                        case r of
                            Left
                                ( WithdrawResolverWalletShortfallWithExcludes
                                        _
                                        _
                                        refs
                                    ) -> do
                                    refs `shouldBe` [outRefA]
                                    renderWithdrawWalletShortfallWithExcludes
                                        "wallet shortfall"
                                        refs
                                        `shouldSatisfy` T.isInfixOf
                                            (outRefText outRefA)
                            other ->
                                errorWithoutStackTrace
                                    ( "expected WithdrawResolverWalletShortfallWithExcludes, got: "
                                        <> show other
                                    )
                it "synthetic withdraw fixture emits byte-identically" $ do
                    env :: WithdrawEnv <-
                        eitherDecodeStrict
                            "test/fixtures/withdraw/synthetic/env.json"
                    answers :: WithdrawAnswers <-
                        eitherDecodeStrict
                            "test/fixtures/withdraw/synthetic/answers.json"
                    intent <-
                        case withdrawToTreasuryIntent env answers of
                            Left we ->
                                errorWithoutStackTrace
                                    ("translate: " <> show we)
                            Right i -> pure i
                    expectedBytes <-
                        BSL.readFile
                            "test/fixtures/withdraw/synthetic/intent.json"
                    expected :: Aeson.Value <-
                        case Aeson.eitherDecode expectedBytes of
                            Right v -> pure v
                            Left e ->
                                errorWithoutStackTrace
                                    ("decode expected: " <> e)
                    let producedBytes =
                            encodeSomeTreasuryIntent
                                (SomeTreasuryIntent SWithdraw intent)
                    case Aeson.eitherDecode producedBytes
                            :: Either String Aeson.Value of
                        Right v -> v `shouldBe` expected
                        Left e ->
                            errorWithoutStackTrace
                                ("decode produced: " <> e)
