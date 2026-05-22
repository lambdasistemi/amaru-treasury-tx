{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Cli.SwapWizardInputControlSpec
Description : RED+GREEN assertions for the @swap-wizard@
              @--exclude-utxo@ / @--extra-tx-in@ wiring
              (Slice 2 of #184).
License     : Apache-2.0

Exercises the runner-level wiring of the shared
'Amaru.Treasury.Wizard.InputControl' API into the
@swap-wizard@ subcommand. The assertions live at the
boundary the runner exposes for testability: the parsed
'WizardOpts', the contradiction pre-flight
('validateWizardInputControl'), and the resolver
('resolveWizardEnvIC') with stub UTxO queries.

T006 — US3 contradiction: same outref on both flags fails
       at flag-validation (before any chain query).
T007 — US1 exclusion filters wallet pool + log line per ref.
T008 — US2 forced inclusion lands in @wallet.extraTxIns@ and
       is dropped from the selection pool.
T009 — US1 shortfall-with-excludes names every excluded ref.
T010 — US4 SC-005 byte stability with empty flags.
T010a — US2 FR-009 extra-tx-in not on wallet → typed error.
T010b — US1 FR-005 pool attribution (wallet/treasury/both).
-}
module Amaru.Treasury.Cli.SwapWizardInputControlSpec
    ( spec
    ) where

import Data.Aeson (FromJSON, eitherDecodeFileStrict)
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
    , runIO
    , shouldBe
    , shouldContain
    , shouldSatisfy
    )

import Amaru.Treasury.IntentJSON
    ( SAction (..)
    , SomeTreasuryIntent (..)
    , encodeSomeTreasuryIntent
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
import Amaru.Treasury.Wizard.InputControlTestHelpers
    ( hashA
    , hashB
    , hashC
    )

import Amaru.Treasury.Cli.SwapWizard
    ( WizardOpts (..)
    , validateWizardInputControl
    , wizardOptsP
    )
import Amaru.Treasury.Tx.SwapWizard
    ( InputControlOutcome (..)
    , PoolHit (..)
    , RegistryView
    , ResolverEnv (..)
    , ResolverError (..)
    , ResolverInput (..)
    , SwapWizardQ (..)
    , WalletSelection (..)
    , WizardEnv (..)
    , renderExclusionLogLine
    , renderWalletShortfallWithExcludes
    , resolveWizardEnvIC
    , wizardToTreasuryIntent
    )

-- ----------------------------------------------------------------------
-- Helpers (defined first to be in scope for the spec)
-- ----------------------------------------------------------------------

walletAFixtureRef :: Text
walletAFixtureRef =
    "42e4c279036e3ab6070bc969392b823917d8b998204d5dcbdfe69fec4b442da0#0"

mustParse :: Text -> OutRef
mustParse t = case parseOutRef t of
    Right r -> r
    Left e -> error (T.unpack e)

countOccurrences :: (Eq a) => a -> [a] -> Int
countOccurrences x = length . filter (== x)

loadFixture :: (FromJSON a) => FilePath -> IO a
loadFixture path = do
    r <- eitherDecodeFileStrict path
    case r of
        Right v -> pure v
        Left e ->
            errorWithoutStackTrace
                ("loadFixture: " <> path <> ": " <> e)

baseArgs :: [String]
baseArgs =
    [ "--wallet-addr"
    , "addr1q802wxt6cg6aw0nl0vdzfxavu65rxu3yzhvgayw7chfxymduzkt66uw9t5kspx5jwjecx80dz4g33htknafhdhkvzd5st4f9xu"
    , "--metadata"
    , "/tmp/metadata.json"
    , "--scope"
    , "core_development"
    , "--usdm"
    , "100000"
    , "--split"
    , "8"
    , "--min-rate"
    , "0.245"
    , "--description"
    , "x"
    , "--justification"
    , "y"
    , "--destination-label"
    , "z"
    ]

parseArgs :: [String] -> Either String WizardOpts
parseArgs args =
    case execParserPure defaultPrefs (info wizardOptsP mempty) args of
        Success a -> Right a
        Failure _ -> Left "parse failed"
        CompletionInvoked _ -> Left "completion invoked"

stubFor
    :: [(Text, Integer, Bool)]
    -> [(Text, Integer, Bool)]
    -> ResolverEnv IO
stubFor walletUtxos treasuryUtxos =
    ResolverEnv
        { reEnvQueryWalletUtxos = \_ -> pure walletUtxos
        , reEnvQueryTreasuryUtxos = \_ -> pure treasuryUtxos
        , reEnvComputeUpperBound = \_ -> pure (Right 186_364_542)
        }

riFor :: RegistryView -> Text -> ResolverInput
riFor registry walletAddrText =
    ResolverInput
        { riNetwork = "mainnet"
        , riWalletAddrBech32 = walletAddrText
        , riScope = CoreDevelopment
        , riAmountLovelace = 1_000_000_000
        , riChunkSizeLovelace = 100_000_000
        , riRegistry = registry
        , riValidityHours = Nothing
        }

-- ----------------------------------------------------------------------
-- Spec
-- ----------------------------------------------------------------------

spec :: Spec
spec = describe "swap-wizard --exclude-utxo / --extra-tx-in" $ do
    env :: WizardEnv <-
        runIO
            (loadFixture "test/fixtures/swap-wizard/env.json")
    answers :: SwapWizardQ <-
        runIO
            (loadFixture "test/fixtures/swap-wizard/answers.json")
    let registryView = weRegistry env
        walletAddr =
            "addr1q802wxt6cg6aw0nl0vdzfxavu65rxu3yzhvgayw7chfxymduzkt66uw9t5kspx5jwjecx80dz4g33htknafhdhkvzd5st4f9xu"
        treasuryRef =
            "64f27254f3c0311fb2e672cdb87de200089a596aa90dc09f8be4248540267cf0#0"
        walletRefA = hashA <> "#0"
        walletRefB = hashB <> "#1"
        treasuryHitRef = hashC <> "#2"
        outRefA = mustParse walletRefA
        outRefB = mustParse walletRefB
        outRefC = mustParse treasuryHitRef
        baseRi = riFor registryView walletAddr
        empty2 = (ExclusionSet [], ForcedInclusionSet [])

    -- ------------------------------------------------------------------
    -- T006 — US3 contradiction
    -- ------------------------------------------------------------------
    describe "T006 contradiction fails fast at flag-validation" $ do
        it
            "same outref on --exclude-utxo and --extra-tx-in fails before any chain query"
            $ do
                let argv =
                        baseArgs
                            ++ [ "--exclude-utxo"
                               , T.unpack walletRefA
                               , "--extra-tx-in"
                               , T.unpack walletRefA
                               ]
                case parseArgs argv of
                    Left err ->
                        error ("expected parse success, got: " <> err)
                    Right opts -> do
                        validateWizardInputControl opts
                            `shouldBe` Left (Contradiction [outRefA])

    -- ------------------------------------------------------------------
    -- T007 — US1 exclusion filters wallet pool + log line
    -- ------------------------------------------------------------------
    describe "T007 exclusion filters wallet pool" $ do
        it
            "wallet head is the surviving candidate B after --exclude-utxo A"
            $ do
                let stub =
                        stubFor
                            [ (walletRefA, 92_560_000, False)
                            , (walletRefB, 19_760_000, False)
                            ]
                            [(treasuryRef, 1_450_000_000_000, False)]
                r <-
                    resolveWizardEnvIC
                        stub
                        (ExclusionSet [outRefA])
                        (ForcedInclusionSet [])
                        baseRi
                case r of
                    Left e -> error ("expected Right, got: " <> show e)
                    Right (env', outcome) -> do
                        wsTxIn (weWalletSelection env') `shouldBe` walletRefB
                        icoHits outcome
                            `shouldContain` [(outRefA, WalletOnly)]
        it
            "renders the operator-facing log line with [wallet] attribution"
            $ do
                renderExclusionLogLine outRefA WalletOnly
                    `shouldBe` ( "swap-wizard: excluded utxo "
                                    <> outRefText outRefA
                                    <> " (operator-supplied) [wallet]"
                               )

    -- ------------------------------------------------------------------
    -- T008 — US2 forced inclusion lands in wallet.extraTxIns
    -- ------------------------------------------------------------------
    describe "T008 forced inclusion" $ do
        it
            "extra-tx-in ref appears exactly once in wallet.extraTxIns and is removed from selection pool"
            $ do
                let stub =
                        stubFor
                            [ (walletRefA, 92_560_000, False)
                            , (walletRefB, 19_760_000, False)
                            ]
                            [(treasuryRef, 1_450_000_000_000, False)]
                r <-
                    resolveWizardEnvIC
                        stub
                        (ExclusionSet [])
                        (ForcedInclusionSet [outRefB])
                        baseRi
                case r of
                    Left e -> error ("expected Right, got: " <> show e)
                    Right (env', _) -> do
                        wsTxIn (weWalletSelection env')
                            `shouldBe` walletRefA
                        let extras =
                                wsExtraTxIns (weWalletSelection env')
                        countOccurrences walletRefB extras `shouldBe` 1

    -- ------------------------------------------------------------------
    -- T009 — US1 shortfall-with-excludes
    -- ------------------------------------------------------------------
    describe "T009 shortfall with excludes" $ do
        it
            "filtering all wallet candidates surfaces shortfall whose message names every excluded ref"
            $ do
                let stub =
                        stubFor
                            [(walletRefA, 92_560_000, False)]
                            [(treasuryRef, 1_450_000_000_000, False)]
                r <-
                    resolveWizardEnvIC
                        stub
                        (ExclusionSet [outRefA])
                        (ForcedInclusionSet [])
                        baseRi
                case r of
                    Left (ResolverWalletShortfallWithExcludes _ _ refs) -> do
                        refs `shouldBe` [outRefA]
                        let rendered =
                                renderWalletShortfallWithExcludes
                                    "wallet shortfall"
                                    refs
                        rendered
                            `shouldSatisfy` T.isInfixOf (outRefText outRefA)
                    other ->
                        error
                            ( "expected ResolverWalletShortfallWithExcludes, got: "
                                <> show other
                            )

    -- ------------------------------------------------------------------
    -- T010 — US4 SC-005 byte stability with empty flags
    -- ------------------------------------------------------------------
    describe "T010 SC-005 byte stability with empty flags" $ do
        it "empty exclusion/forced sets produce the fixture intent" $ do
            let stub =
                    stubFor
                        [(walletAFixtureRef, 1_000_000_000, False)]
                        [(treasuryRef, 1_450_000_000_000, False)]
                ri =
                    baseRi
                        { riAmountLovelace = 408_163_265_306
                        , riChunkSizeLovelace = 12_500_000_000
                        }
            r <- uncurry (resolveWizardEnvIC stub) empty2 ri
            case r of
                Left e -> error ("expected Right, got: " <> show e)
                Right (env', _) -> do
                    let envMainnet =
                            env'
                                { weNetwork = "mainnet"
                                , weWalletSelection =
                                    (weWalletSelection env')
                                        { wsAddress =
                                            wsAddress
                                                (weWalletSelection env)
                                        }
                                }
                    case wizardToTreasuryIntent envMainnet answers of
                        Left e -> error (show e)
                        Right intent ->
                            encodeSomeTreasuryIntent
                                (SomeTreasuryIntent SSwap intent)
                                `shouldBe` encodeSomeTreasuryIntent
                                    ( SomeTreasuryIntent SSwap $
                                        case wizardToTreasuryIntent env answers of
                                            Right x -> x
                                            Left e -> error (show e)
                                    )

    -- ------------------------------------------------------------------
    -- T010a — US2 FR-009 not-on-wallet
    -- ------------------------------------------------------------------
    describe "T010a FR-009 extra-tx-in not on wallet" $ do
        it
            "refs absent from wallet query produce a typed error naming them"
            $ do
                let stub =
                        stubFor
                            [(walletRefA, 92_560_000, False)]
                            [(treasuryRef, 1_450_000_000_000, False)]
                    missingRef = mustParse (hashB <> "#7")
                r <-
                    resolveWizardEnvIC
                        stub
                        (ExclusionSet [])
                        (ForcedInclusionSet [missingRef])
                        baseRi
                case r of
                    Left (ResolverExtraTxInNotOnWallet refs) ->
                        refs `shouldBe` [missingRef]
                    other ->
                        error
                            ( "expected ResolverExtraTxInNotOnWallet, got: "
                                <> show other
                            )

    -- ------------------------------------------------------------------
    -- T010b — US1 FR-005 pool attribution
    -- ------------------------------------------------------------------
    describe "T010b FR-005 pool attribution" $ do
        it "wallet-only hit emits [wallet] attribution" $ do
            let stub =
                    stubFor
                        [ (walletRefA, 92_560_000, False)
                        , (walletRefB, 1_000_000_000, False)
                        ]
                        [(treasuryRef, 1_450_000_000_000, False)]
            r <-
                resolveWizardEnvIC
                    stub
                    (ExclusionSet [outRefA])
                    (ForcedInclusionSet [])
                    baseRi
            case r of
                Right (_, outcome) ->
                    icoHits outcome `shouldBe` [(outRefA, WalletOnly)]
                Left e -> error (show e)
        it "treasury-only hit emits [treasury] attribution" $ do
            let stub =
                    stubFor
                        [(walletRefA, 92_560_000, False)]
                        [ (treasuryRef, 1_400_000_000_000, False)
                        , (treasuryHitRef, 60_000_000_000, False)
                        ]
            r <-
                resolveWizardEnvIC
                    stub
                    (ExclusionSet [outRefC])
                    (ForcedInclusionSet [])
                    baseRi
            case r of
                Right (_, outcome) ->
                    icoHits outcome `shouldBe` [(outRefC, TreasuryOnly)]
                Left e -> error (show e)
        it "ref hitting both pools emits [both] attribution" $ do
            let stub =
                    stubFor
                        [ (walletRefA, 92_560_000, False)
                        , (walletRefB, 1_000_000_000, False)
                        ]
                        [ (treasuryRef, 1_400_000_000_000, False)
                        , (walletRefB, 60_000_000_000, False)
                        ]
            r <-
                resolveWizardEnvIC
                    stub
                    (ExclusionSet [outRefB])
                    (ForcedInclusionSet [])
                    baseRi
            case r of
                Right (_, outcome) ->
                    icoHits outcome `shouldBe` [(outRefB, Both)]
                Left e -> error (show e)
