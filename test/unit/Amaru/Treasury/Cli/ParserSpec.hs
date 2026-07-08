{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Cli.ParserSpec
Description : CLI parser tests for the retired @devnet@ supercommand
License     : Apache-2.0

After issue #157 the @devnet@ supercommand and its four
@registry-init@\/@stake-reward-init@\/@governance-withdrawal-init@\/
@disburse-submit@ children no longer ship in the executable. These
parser-level assertions pin that contract: each name must produce
a parse 'Failure', and the top-level help body must not list a
@devnet@ subcommand line.
-}
module Amaru.Treasury.Cli.ParserSpec (spec) where

import Data.Char (isSpace)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Options.Applicative
    ( ParserResult (..)
    , defaultPrefs
    , execParserPure
    , renderFailure
    )
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldSatisfy
    )

import Amaru.Treasury.Cli (opts)

spec :: Spec
spec = describe "Amaru.Treasury.Cli.ParserSpec (post-#157)" $ do
    describe "retired devnet supercommand" $ do
        it "rejects bare devnet" $
            isFailure ["devnet"] `shouldBe` True
        it "rejects devnet registry-init" $
            isFailure ["devnet", "registry-init"]
                `shouldBe` True
        it "rejects devnet stake-reward-init" $
            isFailure ["devnet", "stake-reward-init"]
                `shouldBe` True
        it "rejects devnet governance-withdrawal-init" $
            isFailure ["devnet", "governance-withdrawal-init"]
                `shouldBe` True
        it "rejects devnet disburse-submit" $
            isFailure ["devnet", "disburse-submit"]
                `shouldBe` True
    describe "no flattened devnet leaf at top level either" $ do
        it "rejects top-level registry-init" $
            isFailure ["registry-init"] `shouldBe` True
        it "rejects top-level stake-reward-init" $
            isFailure ["stake-reward-init"] `shouldBe` True
        it "rejects top-level governance-withdrawal-init" $
            isFailure ["governance-withdrawal-init"]
                `shouldBe` True
        it "rejects top-level disburse-submit" $
            isFailure ["disburse-submit"] `shouldBe` True
    describe "help body" $
        it "does not list a top-level devnet subcommand line" $ do
            let body = renderHelpBody
            body
                `shouldSatisfy` not
                    . any matchesDevnetLine
                    . lines
    describe "CLI wizard event severity" $ do
        it "filters tx-build events with the explicit threshold" $ do
            src <- TIO.readFile txBuildSource
            src `shouldContainText` "filterSeverity minimumSeverity"
            src `shouldContainText` "buildEventSeverityTracer"
            src `shouldNotContainText` "buildEventTracer textTracer"

        it "filters swap wizard events with global verbosity" $ do
            src <- TIO.readFile swapWizardSource
            src `shouldContainText` "filterSeverity (goMinimumSeverity g)"
            src `shouldContainText` "eventSeverityTracer"
            src `shouldNotContainText` "eventTracer textTracer"

        it "filters swap-quote wizard events with global verbosity" $ do
            src <- TIO.readFile swapQuoteSource
            src `shouldContainText` "filterSeverity (goMinimumSeverity g)"
            src `shouldContainText` "eventSeverityTracer"
            src `shouldNotContainText` "eventTracer textTracer"

        it "filters disburse wizard events with command-specific prefixes" $ do
            src <- TIO.readFile disburseWizardSource
            src `shouldContainText` "filterSeverity (goMinimumSeverity g)"
            src `shouldContainText` "disburseEventSeverityTracerWithPrefix"
            src `shouldContainText` "commandName"
            src
                `shouldNotContainText` "disburseEventTracerWithPrefix\n                        commandName"

        it "filters withdraw wizard events with global verbosity" $ do
            src <- TIO.readFile withdrawWizardSource
            src `shouldContainText` "filterSeverity (goMinimumSeverity g)"
            src `shouldContainText` "withdrawWizardEventSeverityTracer"
            src
                `shouldNotContainText` "withdrawWizardEventTracer textTracer"

{- | Equivalent to the POSIX regex
@^[[:space:]]+devnet([[:space:]]|$)@ — leading whitespace,
then the literal @devnet@, then either a whitespace character
or end of line. Pinned in plain Haskell so the test suite does
not pull in @regex-tdfa@.
-}
matchesDevnetLine :: String -> Bool
matchesDevnetLine line =
    case span isSpace line of
        ("", _) -> False
        (_, rest) ->
            case splitAt 6 rest of
                ("devnet", "") -> True
                ("devnet", c : _) | isSpace c -> True
                _ -> False

{- | True when 'execParserPure' returns a 'Failure' for the given
argument vector.
-}
isFailure :: [String] -> Bool
isFailure args =
    case execParserPure defaultPrefs opts args of
        Failure{} -> True
        Success{} -> False
        CompletionInvoked{} -> False

{- | Render the executable's top-level help body, as it would
appear when the user passes @--help@.
-}
renderHelpBody :: String
renderHelpBody =
    case execParserPure defaultPrefs opts ["--help"] of
        Failure failure ->
            let (msg, _) = renderFailure failure "amaru-treasury-tx"
            in  msg
        Success _ -> ""
        CompletionInvoked _ -> ""

txBuildSource :: FilePath
txBuildSource = "lib/Amaru/Treasury/Cli/TxBuild.hs"

swapWizardSource :: FilePath
swapWizardSource = "lib/Amaru/Treasury/Wizard/Swap.hs"

swapQuoteSource :: FilePath
swapQuoteSource = "lib/Amaru/Treasury/Cli/SwapQuote.hs"

disburseWizardSource :: FilePath
disburseWizardSource = "lib/Amaru/Treasury/Cli/DisburseWizard.hs"

withdrawWizardSource :: FilePath
withdrawWizardSource = "lib/Amaru/Treasury/Cli/WithdrawWizard.hs"

shouldContainText :: Text -> Text -> IO ()
shouldContainText haystack needle =
    haystack `shouldSatisfy` T.isInfixOf needle

shouldNotContainText :: Text -> Text -> IO ()
shouldNotContainText haystack needle =
    haystack `shouldSatisfy` not . T.isInfixOf needle
