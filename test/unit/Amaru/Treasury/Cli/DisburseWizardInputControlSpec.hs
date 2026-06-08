{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : Amaru.Treasury.Cli.DisburseWizardInputControlSpec
Description : RED+GREEN assertions for the @disburse-wizard@
              and @contingency-disburse-wizard@
              @--exclude-utxo@ / @--extra-tx-in@ wiring
              (Slice 3 of #184).
License     : Apache-2.0

Exercises runner-level wiring of
'Amaru.Treasury.Wizard.InputControl' into the two
disburse subcommands. Assertions sit at the runner
boundary: parsed opts records, contradiction
pre-flight, and 'resolveDisburseEnvIC' with stub UTxO
queries.

T013 — US3 contradiction for both wizards.
T014 — US1 exclusion filters the wallet pool.
T015 — US1 exclusion filters the per-unit treasury
       pool ('selectTreasuryForUnit').
T016 — US2 forced inclusion lands in the disburse
       intent's @wallet.extraTxIns@.
T017 — US1 shortfall-with-excludes names every
       excluded ref for both wallet and treasury pools.
T018 — US4 SC-005 byte stability against the existing
       disburse fixtures with empty flag sets.
-}
module Amaru.Treasury.Cli.DisburseWizardInputControlSpec
    ( spec
    ) where

import Cardano.Crypto.Hash.Class
    ( Hash
    , HashAlgorithm
    , hashFromBytes
    )
import Cardano.Ledger.BaseTypes (mkTxIxPartial)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Hashes (unsafeMakeSafeHash)
import Cardano.Ledger.Mary.Value
    ( MaryValue (..)
    , MultiAsset (..)
    )
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Maybe (fromJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word8)
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

import Amaru.Treasury.Constants (Unit (..))
import Amaru.Treasury.IntentJSON
    ( DisburseDestination (..)
    , SAction (..)
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

import Amaru.Treasury.Cli.DisburseWizard
    ( ContingencyDisburseOpts
    , DisburseWizardOpts
    , contingencyDisburseOptsP
    , disburseWizardOptsP
    , validateContingencyDisburseInputControl
    , validateDisburseWizardInputControl
    )
import Amaru.Treasury.Tx.DisburseWizard
    ( DisburseAnswers (..)
    , DisburseEnv (..)
    , DisburseTreasurySelection (..)
    , InputControlOutcome (..)
    , PoolHit (..)
    , RegistryView
    , ResolverEnv (..)
    , ResolverError (..)
    , ResolverInput (..)
    , WalletSelection (..)
    , disburseToTreasuryIntent
    , renderDisburseExclusionLogLine
    , renderDisburseWalletShortfallWithExcludes
    , resolveDisburseEnvIC
    )
import Amaru.Treasury.Tx.SwapWizard (txInToText)

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

mkHash32 :: (HashAlgorithm h) => Word8 -> Hash h a
mkHash32 n =
    fromJust . hashFromBytes . BS.pack $
        replicate 31 0 ++ [n]

mkTxIn :: Word8 -> TxIn
mkTxIn n =
    TxIn
        (TxId (unsafeMakeSafeHash (mkHash32 n)))
        (mkTxIxPartial 0)

txInOutRef :: TxIn -> OutRef
txInOutRef = mustParse . txInToText

adaValue :: Integer -> MaryValue
adaValue lov = MaryValue (Coin lov) (MultiAsset mempty)

countOccurrences :: (Eq a) => a -> [a] -> Int
countOccurrences x = length . filter (== x)

walletAddrStr :: String
walletAddrStr =
    "addr1q802wxt6cg6aw0nl0vdzfxavu65rxu3yzhvgayw7chfxymduzkt66uw9t5kspx5jwjecx80dz4g33htknafhdhkvzd5st4f9xu"

walletAddrText :: Text
walletAddrText = T.pack walletAddrStr

beneficiaryAddrStr :: String
beneficiaryAddrStr =
    "addr1qy8ac7qqy0vtulyl7wntmsxc6wex80gvcyjy33qffrhm7sh927ysx5sftuw0dlft05dz3c7revpf7jx0xnlcjz3g69mq4afdhv"

-- Parser helpers

baseDisburseArgs :: [String]
baseDisburseArgs =
    [ "--wallet-addr"
    , walletAddrStr
    , "--metadata"
    , "/tmp/metadata.json"
    , "--scope"
    , "core_development"
    , "--unit"
    , "ada"
    , "--amount"
    , "50000000"
    , "--beneficiary-addr"
    , beneficiaryAddrStr
    , "--description"
    , "x"
    , "--justification"
    , "y"
    , "--destination-label"
    , "z"
    ]

baseContingencyArgs :: [String]
baseContingencyArgs =
    [ "--wallet-addr"
    , walletAddrStr
    , "--metadata"
    , "/tmp/metadata.json"
    , "--to"
    , "core_development:1.0"
    , "--description"
    , "x"
    , "--justification"
    , "y"
    ]

parseDisburse :: [String] -> Either String DisburseWizardOpts
parseDisburse args =
    case execParserPure
        defaultPrefs
        (info disburseWizardOptsP mempty)
        args of
        Success a -> Right a
        Failure _ -> Left "parse failed"
        CompletionInvoked _ -> Left "completion invoked"

parseContingency :: [String] -> Either String ContingencyDisburseOpts
parseContingency args =
    case execParserPure
        defaultPrefs
        (info contingencyDisburseOptsP mempty)
        args of
        Success a -> Right a
        Failure _ -> Left "parse failed"
        CompletionInvoked _ -> Left "completion invoked"

-- Resolver stub

stubFor
    :: [(Text, Integer, Bool)]
    -> [(TxIn, MaryValue)]
    -> ResolverEnv IO
stubFor walletUtxos treasuryUtxos =
    ResolverEnv
        { reEnvQueryWalletUtxos = \_ -> pure walletUtxos
        , reEnvQueryTreasuryUtxos = \_ -> pure treasuryUtxos
        , reEnvComputeUpperBound = \_ -> pure (Right 186_468_259)
        }

baseRi :: RegistryView -> ResolverInput
baseRi registry =
    ResolverInput
        { riNetwork = "mainnet"
        , riWalletAddrBech32 = walletAddrText
        , riDestinations =
            DisburseDestination
                (T.pack beneficiaryAddrStr)
                50_000_000
                :| []
        , riScope = CoreDevelopment
        , riUnit = ADA
        , riRegistry = registry
        , riValidityHours = Nothing
        , riTreasuryTxIns = []
        }

-- ----------------------------------------------------------------------
-- Spec
-- ----------------------------------------------------------------------

spec :: Spec
spec =
    describe
        "disburse-wizard / contingency-disburse-wizard --exclude-utxo / --extra-tx-in"
        $ do
            let walletRefA = T.replicate 64 "a" <> "#0"
                walletRefB = T.replicate 64 "b" <> "#1"
                outRefA = mustParse walletRefA
                outRefB = mustParse walletRefB
                treasuryTxIn = mkTxIn 1
                treasuryRef = txInOutRef treasuryTxIn

            -- T013 contradiction (both wizards)
            describe "T013 contradiction" $ do
                it "disburse-wizard fails fast at flag-validation" $ do
                    let argv =
                            baseDisburseArgs
                                ++ [ "--exclude-utxo"
                                   , T.unpack walletRefA
                                   , "--extra-tx-in"
                                   , T.unpack walletRefA
                                   ]
                    case parseDisburse argv of
                        Left err ->
                            errorWithoutStackTrace
                                ("expected parse success: " <> err)
                        Right opts ->
                            validateDisburseWizardInputControl opts
                                `shouldBe` Left
                                    (Contradiction [outRefA])
                it "contingency-disburse-wizard fails fast at flag-validation" $ do
                    let argv =
                            baseContingencyArgs
                                ++ [ "--exclude-utxo"
                                   , T.unpack walletRefA
                                   , "--extra-tx-in"
                                   , T.unpack walletRefA
                                   ]
                    case parseContingency argv of
                        Left err ->
                            errorWithoutStackTrace
                                ("expected parse success: " <> err)
                        Right opts ->
                            validateContingencyDisburseInputControl opts
                                `shouldBe` Left
                                    (Contradiction [outRefA])

            -- T014 exclusion filters wallet pool
            describe "T014 exclusion filters the wallet pool" $ do
                it
                    "wallet head is the surviving candidate B after --exclude-utxo A"
                    $ do
                        env :: DisburseEnv <-
                            eitherDecodeStrict
                                "test/fixtures/disburse-wizard/env.ada.json"
                        let ri = baseRi (deRegistry env)
                            stub =
                                stubFor
                                    [ (walletRefA, 5_000_000, False)
                                    , (walletRefB, 5_000_000, False)
                                    ]
                                    [(treasuryTxIn, adaValue 1_000_000_000)]
                        r <-
                            resolveDisburseEnvIC
                                stub
                                (ExclusionSet [outRefA])
                                (ForcedInclusionSet [])
                                ri
                        case r of
                            Left e ->
                                errorWithoutStackTrace
                                    ("expected Right: " <> show e)
                            Right (env', outcome) -> do
                                wsTxIn (deWalletSelection env')
                                    `shouldBe` walletRefB
                                icoHits outcome
                                    `shouldContain` [(outRefA, WalletOnly)]
                it
                    "renders the operator-facing log line with prefix and attribution"
                    $ do
                        renderDisburseExclusionLogLine
                            "disburse-wizard"
                            outRefA
                            WalletOnly
                            `shouldBe` ( "disburse-wizard: excluded utxo "
                                            <> outRefText outRefA
                                            <> " (operator-supplied) [wallet]"
                                       )
                        renderDisburseExclusionLogLine
                            "contingency-disburse-wizard"
                            outRefA
                            TreasuryOnly
                            `shouldBe` ( "contingency-disburse-wizard: excluded utxo "
                                            <> outRefText outRefA
                                            <> " (operator-supplied) [treasury]"
                                       )

            -- T015 exclusion filters per-unit treasury pool
            describe "T015 exclusion filters the per-unit treasury pool" $ do
                it
                    "the excluded TxIn is dropped before selectTreasuryForUnit picks"
                    $ do
                        env :: DisburseEnv <-
                            eitherDecodeStrict
                                "test/fixtures/disburse-wizard/env.ada.json"
                        let kept = mkTxIn 2
                            ri = baseRi (deRegistry env)
                            stub =
                                stubFor
                                    [(walletRefA, 5_000_000, False)]
                                    [ (treasuryTxIn, adaValue 1_000_000_000)
                                    , (kept, adaValue 60_000_000)
                                    ]
                        r <-
                            resolveDisburseEnvIC
                                stub
                                (ExclusionSet [treasuryRef])
                                (ForcedInclusionSet [])
                                ri
                        case r of
                            Left e ->
                                errorWithoutStackTrace
                                    ("expected Right: " <> show e)
                            Right (env', outcome) -> do
                                icoHits outcome
                                    `shouldContain` [(treasuryRef, TreasuryOnly)]
                                dtsInputs (deTreasurySelection env')
                                    `shouldBe` [txInToText kept]

            -- T016 forced inclusion lands in wallet.extraTxIns
            describe "T016 forced inclusion lands in intent wallet.extraTxIns" $ do
                it
                    "extra-tx-in ref appears once in wallet.extraTxIns of the disburse intent"
                    $ do
                        env :: DisburseEnv <-
                            eitherDecodeStrict
                                "test/fixtures/disburse-wizard/env.ada.json"
                        answers :: DisburseAnswers <-
                            eitherDecodeStrict
                                "test/fixtures/disburse-wizard/answers.ada.json"
                        let ri = baseRi (deRegistry env)
                            stub =
                                stubFor
                                    [ (walletRefA, 5_000_000, False)
                                    , (walletRefB, 5_000_000, False)
                                    ]
                                    [(treasuryTxIn, adaValue 1_000_000_000)]
                        r <-
                            resolveDisburseEnvIC
                                stub
                                (ExclusionSet [])
                                (ForcedInclusionSet [outRefB])
                                ri
                        case r of
                            Left e ->
                                errorWithoutStackTrace
                                    ("expected Right: " <> show e)
                            Right (env', _) -> do
                                wsTxIn (deWalletSelection env')
                                    `shouldBe` walletRefA
                                case disburseToTreasuryIntent env' answers of
                                    Left de ->
                                        errorWithoutStackTrace (show de)
                                    Right intent -> do
                                        let extras =
                                                wjExtraTxIns (tiWallet intent)
                                        countOccurrences walletRefB extras
                                            `shouldBe` 1

            -- T017 shortfall with excludes names refs for both pools
            describe "T017 shortfall with excludes" $ do
                it
                    "wallet-side filtering all candidates surfaces shortfall naming the excluded ref"
                    $ do
                        env :: DisburseEnv <-
                            eitherDecodeStrict
                                "test/fixtures/disburse-wizard/env.ada.json"
                        let ri = baseRi (deRegistry env)
                            stub =
                                stubFor
                                    [(walletRefA, 5_000_000, False)]
                                    [(treasuryTxIn, adaValue 1_000_000_000)]
                        r <-
                            resolveDisburseEnvIC
                                stub
                                (ExclusionSet [outRefA])
                                (ForcedInclusionSet [])
                                ri
                        case r of
                            Left
                                ( ResolverWalletShortfallWithExcludes
                                        _
                                        _
                                        refs
                                    ) -> do
                                    refs `shouldBe` [outRefA]
                                    renderDisburseWalletShortfallWithExcludes
                                        "wallet shortfall"
                                        refs
                                        `shouldSatisfy` T.isInfixOf
                                            (outRefText outRefA)
                            other ->
                                errorWithoutStackTrace
                                    ( "expected ResolverWalletShortfallWithExcludes, got: "
                                        <> show other
                                    )
                it
                    "treasury-side filtering all candidates surfaces shortfall naming the excluded ref"
                    $ do
                        env :: DisburseEnv <-
                            eitherDecodeStrict
                                "test/fixtures/disburse-wizard/env.ada.json"
                        let ri = baseRi (deRegistry env)
                            stub =
                                stubFor
                                    [(walletRefA, 5_000_000, False)]
                                    [(treasuryTxIn, adaValue 60_000_000)]
                        r <-
                            resolveDisburseEnvIC
                                stub
                                (ExclusionSet [treasuryRef])
                                (ForcedInclusionSet [])
                                ri
                        case r of
                            Left
                                ( ResolverTreasuryShortfallWithExcludes
                                        _
                                        _
                                        refs
                                    ) ->
                                    refs `shouldBe` [treasuryRef]
                            other ->
                                errorWithoutStackTrace
                                    ( "expected ResolverTreasuryShortfallWithExcludes, got: "
                                        <> show other
                                    )

            -- T018 SC-005 byte stability with empty flag sets
            describe "T018 SC-005 byte stability with empty flag sets" $ do
                it "ADA fixture emits byte-identically" $
                    byteStableFixture
                        "test/fixtures/disburse-wizard/env.ada.json"
                        "test/fixtures/disburse-wizard/answers.ada.json"
                        "test/fixtures/disburse-wizard/expected.intent.ada.json"
                it "USDM fixture emits byte-identically" $
                    byteStableFixture
                        "test/fixtures/disburse-wizard/env.usdm.json"
                        "test/fixtures/disburse-wizard/answers.usdm.json"
                        "test/fixtures/disburse-wizard/expected.intent.usdm.json"

byteStableFixture :: FilePath -> FilePath -> FilePath -> IO ()
byteStableFixture envPath answersPath expectedPath = do
    env :: DisburseEnv <- eitherDecodeStrict envPath
    answers :: DisburseAnswers <- eitherDecodeStrict answersPath
    intent <- case disburseToTreasuryIntent env answers of
        Left de ->
            errorWithoutStackTrace ("translate: " <> show de)
        Right i -> pure i
    expectedBytes <- BSL.readFile expectedPath
    expected :: Aeson.Value <- case Aeson.eitherDecode expectedBytes of
        Right v -> pure v
        Left e ->
            errorWithoutStackTrace ("decode expected: " <> e)
    let producedBytes =
            encodeSomeTreasuryIntent (SomeTreasuryIntent SDisburse intent)
    case Aeson.eitherDecode producedBytes :: Either String Aeson.Value of
        Right v -> v `shouldBe` expected
        Left e ->
            errorWithoutStackTrace ("decode produced: " <> e)
