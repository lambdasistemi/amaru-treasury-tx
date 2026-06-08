{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Cli.ContingencyDisburseWizardParserSpec
Description : Parser tests for contingency-disburse-wizard repeatable --to (#326 slice B)
License     : Apache-2.0

Covers the repeatable @--to <scope>:<ada>@ destination flag:
it accumulates to a non-empty list, rejects a malformed
@scope:ada@ token, rejects @contingency@ as a destination,
and rejects an empty destination set.
-}
module Amaru.Treasury.Cli.ContingencyDisburseWizardParserSpec
    ( spec
    ) where

import Data.List (isInfixOf)
import Data.List.NonEmpty qualified as NE
import Options.Applicative
    ( ParserResult (..)
    , defaultPrefs
    , execParserPure
    , fullDesc
    , info
    , renderFailure
    )
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    , shouldSatisfy
    )

import Amaru.Treasury.Cli.DisburseWizard
    ( ContingencyDisburseOpts (..)
    , contingencyDisburseOptsP
    )
import Amaru.Treasury.Scope
    ( ScopeId (CoreDevelopment, Middleware)
    )

sampleWalletAddr :: String
sampleWalletAddr =
    "addr1q802wxt6cg6aw0nl0vdzfxavu65rxu3yzhvgayw7chfxymduzkt66uw9t5kspx5jwjecx80dz4g33htknafhdhkvzd5st4f9xu"

{- | Positive argv with a single destination. Tests append
or substitute @--to@ flags as needed.
-}
baseArgv :: [String]
baseArgv =
    [ "--wallet-addr"
    , sampleWalletAddr
    , "--metadata"
    , "/tmp/metadata.json"
    , "--description"
    , "Emergency top-up"
    , "--justification"
    , "Approved by council"
    ]

parseArgs :: [String] -> ParserResult ContingencyDisburseOpts
parseArgs =
    execParserPure
        defaultPrefs
        (info contingencyDisburseOptsP fullDesc)

renderFailureBody :: ParserResult a -> String
renderFailureBody (Failure pf) =
    fst (renderFailure pf "contingency-disburse-wizard")
renderFailureBody _ =
    error "renderFailureBody: expected Failure"

spec :: Spec
spec =
    describe "ContingencyDisburseWizardParser (#326 slice B)" $ do
        it "accumulates repeatable --to into a non-empty list" $
            case parseArgs
                ( baseArgv
                    <> [ "--to"
                       , "core_development:100"
                       , "--to"
                       , "middleware:50"
                       ]
                ) of
                Success opts ->
                    NE.toList (cdOptsDestinations opts)
                        `shouldBe` [ (CoreDevelopment, 100_000_000)
                                   , (Middleware, 50_000_000)
                                   ]
                other ->
                    expectationFailure
                        ( "expected Success, got: "
                            <> renderFailureBody other
                        )

        it "accepts fractional ADA in --to (decimals to 6 places)" $
            case parseArgs
                (baseArgv <> ["--to", "middleware:1.5"]) of
                Success opts ->
                    NE.toList (cdOptsDestinations opts)
                        `shouldBe` [(Middleware, 1_500_000)]
                other ->
                    expectationFailure
                        ( "expected Success, got: "
                            <> renderFailureBody other
                        )

        it "rejects a --to token without a colon" $ do
            let body =
                    renderFailureBody
                        (parseArgs (baseArgv <> ["--to", "core_development"]))
            body `shouldSatisfy` ("to" `isInfixOf`)

        it "rejects a --to token with a non-numeric ada amount" $ do
            let body =
                    renderFailureBody
                        ( parseArgs
                            (baseArgv <> ["--to", "core_development:abc"])
                        )
            body `shouldSatisfy` ("to" `isInfixOf`)

        it "rejects contingency as a --to destination" $ do
            let body =
                    renderFailureBody
                        (parseArgs (baseArgv <> ["--to", "contingency:100"]))
            body `shouldSatisfy` ("contingency" `isInfixOf`)

        it "rejects an empty destination set (no --to)" $ do
            let body = renderFailureBody (parseArgs baseArgv)
            body `shouldSatisfy` ("Missing:" `isInfixOf`)
            body `shouldSatisfy` ("--to" `isInfixOf`)
