{- |
Module      : Amaru.Treasury.Cli.ReorganizeWizardDispatchSpec
Description : Dispatcher-level test for the reorganize-wizard subcommand
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Asserts that the top-level @optparse-applicative@ parser
('Amaru.Treasury.Cli.opts') recognizes @reorganize-wizard@ as
a subcommand and reaches its flag set. Drives
'execParserPure' directly — no subprocess spawn — so the spec
exercises exactly the parser the binary's @execParser@
consumes.

This spec is the S2 RED→GREEN proof for #186: before the
dispatcher wiring exists, @--help@ fails with
@"Invalid argument \`reorganize-wizard'"@ (or equivalent
unknown-subcommand text). After wiring, @--help@ surfaces the
documented progDesc and bare invocation surfaces the
@Missing:@ list for the wizard's own required flags.
-}
module Amaru.Treasury.Cli.ReorganizeWizardDispatchSpec
    ( spec
    ) where

import Data.List (isInfixOf)
import Options.Applicative
    ( ParserResult (..)
    , defaultPrefs
    , execParserPure
    , renderFailure
    )
import Test.Hspec (Spec, describe, it, shouldSatisfy)

import Amaru.Treasury.Cli (opts)

spec :: Spec
spec = describe "reorganize-wizard dispatcher wiring" $ do
    it "surfaces the subcommand progDesc on --help" $ do
        case execParserPure
            defaultPrefs
            opts
            ["reorganize-wizard", "--help"] of
            Failure pf ->
                fst (renderFailure pf "amaru-treasury-tx")
                    `shouldSatisfy` ( "reorganize intent.json"
                                        `isInfixOf`
                                    )
            other ->
                error
                    ( "expected Failure (help payload), got: "
                        <> showResult other
                    )
    it "requires the wizard's own flag set" $ do
        case execParserPure
            defaultPrefs
            opts
            ["reorganize-wizard"] of
            Failure pf -> do
                let rendered =
                        fst
                            ( renderFailure
                                pf
                                "amaru-treasury-tx"
                            )
                rendered
                    `shouldSatisfy` ("Missing:" `isInfixOf`)
                rendered
                    `shouldSatisfy` ("--wallet-addr" `isInfixOf`)
            other ->
                error
                    ( "expected Failure (missing-args), got: "
                        <> showResult other
                    )

showResult :: ParserResult a -> String
showResult Failure{} = "Failure"
showResult Success{} = "Success"
showResult CompletionInvoked{} = "CompletionInvoked"
