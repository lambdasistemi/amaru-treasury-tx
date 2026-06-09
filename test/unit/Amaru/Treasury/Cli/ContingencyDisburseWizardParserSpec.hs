{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Cli.ContingencyDisburseWizardParserSpec
Description : Parser + classification tests for the unified
              @disburse-wizard --scope contingency --to@ surface (#334)
License     : Apache-2.0

After #334 the standalone @contingency-disburse-wizard@
subcommand is gone: a contingency disburse is now driven by
@disburse-wizard --scope contingency@ with the repeatable
@--to \<scope\>:\<ada\>@ destination flag. These tests pin the
unified parser ('disburseWizardInputP') and the pure
classifier ('classifyDisburse'):

* @--scope contingency --to a:.. --to b:..@ classifies to a
  'RouteContingency' carrying the SAME 'ContingencyDisburseOpts'
  the old @contingency-disburse-wizard@ parser produced (parity),
* a malformed / @contingency@ @--to@ token is a parse failure,
* @--scope contingency@ with no @--to@, or with a single-disburse
  flag such as @--beneficiary-addr@, is a classification failure
  pointing at @--to@,
* @--to@ on a non-contingency scope is a classification failure.
-}
module Amaru.Treasury.Cli.ContingencyDisburseWizardParserSpec
    ( spec
    ) where

import Data.List (isInfixOf)
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.List.NonEmpty qualified as NE
import Data.Text (Text)
import Data.Text qualified as T
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
    , DisburseRoute (..)
    , DisburseWizardInput
    , classifyDisburse
    , disburseWizardInputP
    )
import Amaru.Treasury.Scope
    ( ScopeId (CoreDevelopment, Middleware)
    )
import Amaru.Treasury.Wizard.InputControl
    ( ExclusionSet (..)
    , ForcedInclusionSet (..)
    )

sampleWalletAddr :: String
sampleWalletAddr =
    "addr1q802wxt6cg6aw0nl0vdzfxavu65rxu3yzhvgayw7chfxymduzkt66uw9t5kspx5jwjecx80dz4g33htknafhdhkvzd5st4f9xu"

{- | Positive contingency argv on the unified @disburse-wizard@
surface. Tests append or substitute @--to@ flags as needed.
-}
baseArgv :: [String]
baseArgv =
    [ "--wallet-addr"
    , sampleWalletAddr
    , "--metadata"
    , "/tmp/metadata.json"
    , "--scope"
    , "contingency"
    , "--description"
    , "Emergency top-up"
    , "--justification"
    , "Approved by council"
    ]

{- | Positive single-beneficiary argv (owned scope). Used to
prove that @--to@ is rejected outside @--scope contingency@.
-}
baseSingleArgv :: [String]
baseSingleArgv =
    [ "--wallet-addr"
    , sampleWalletAddr
    , "--metadata"
    , "/tmp/metadata.json"
    , "--scope"
    , "core_development"
    , "--amount"
    , "100"
    , "--beneficiary-addr"
    , sampleWalletAddr
    , "--description"
    , "Vendor payment"
    , "--justification"
    , "Approved invoice"
    , "--destination-label"
    , "Vendor"
    ]

parseArgs :: [String] -> ParserResult DisburseWizardInput
parseArgs =
    execParserPure
        defaultPrefs
        (info disburseWizardInputP fullDesc)

renderFailureBody :: ParserResult a -> String
renderFailureBody (Failure pf) =
    fst (renderFailure pf "disburse-wizard")
renderFailureBody _ =
    error "renderFailureBody: expected Failure"

{- | Parse the argv (expecting parser success) and run the pure
classifier. A parse failure surfaces as a 'Left' so the
classification-level rejection tests can assert on it uniformly.
-}
classifyArgs :: [String] -> Either Text DisburseRoute
classifyArgs args =
    case parseArgs args of
        Success input -> classifyDisburse input
        other ->
            Left (T.pack ("parse failed: " <> renderFailureBody other))

{- | The 'ContingencyDisburseOpts' the retired
@contingency-disburse-wizard@ parser produced for the canonical
two-destination invocation. Parity target for the unified route.
-}
expectedContingencyOpts :: ContingencyDisburseOpts
expectedContingencyOpts =
    ContingencyDisburseOpts
        { cdOptsWalletAddr = T.pack sampleWalletAddr
        , cdOptsMetadataPath = "/tmp/metadata.json"
        , cdOptsOut = Nothing
        , cdOptsLog = Nothing
        , cdOptsDestinations =
            (CoreDevelopment, 100_000_000)
                :| [(Middleware, 50_000_000)]
        , cdOptsValidityHours = Nothing
        , cdOptsDescription = "Emergency top-up"
        , cdOptsJustification = "Approved by council"
        , cdOptsExcludeSet = ExclusionSet []
        , cdOptsForcedSet = ForcedInclusionSet []
        }

spec :: Spec
spec =
    describe
        "Unified disburse-wizard --scope contingency --to (#334)"
        $ do
            it "classifies --scope contingency --to as a contingency route" $
                case classifyArgs
                    ( baseArgv
                        <> [ "--to"
                           , "core_development:100"
                           , "--to"
                           , "middleware:50"
                           ]
                    ) of
                    Right (RouteContingency opts) ->
                        NE.toList (cdOptsDestinations opts)
                            `shouldBe` [ (CoreDevelopment, 100_000_000)
                                       , (Middleware, 50_000_000)
                                       ]
                    other ->
                        expectationFailure
                            ("expected RouteContingency, got: " <> show other)

            it
                "builds the SAME ContingencyDisburseOpts as the old command (parity)"
                $ classifyArgs
                    ( baseArgv
                        <> [ "--to"
                           , "core_development:100"
                           , "--to"
                           , "middleware:50"
                           ]
                    )
                    `shouldBe` Right (RouteContingency expectedContingencyOpts)

            it "accepts fractional ADA in --to (decimals to 6 places)" $
                case classifyArgs (baseArgv <> ["--to", "middleware:1.5"]) of
                    Right (RouteContingency opts) ->
                        NE.toList (cdOptsDestinations opts)
                            `shouldBe` [(Middleware, 1_500_000)]
                    other ->
                        expectationFailure
                            ("expected RouteContingency, got: " <> show other)

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

            it "rejects --scope contingency with no --to, pointing at --to" $
                case classifyArgs baseArgv of
                    Left msg ->
                        T.unpack msg `shouldSatisfy` ("--to" `isInfixOf`)
                    Right route ->
                        expectationFailure
                            ("expected Left, got: " <> show route)

            it "rejects --beneficiary-addr with --scope contingency" $
                case classifyArgs
                    ( baseArgv
                        <> [ "--to"
                           , "core_development:100"
                           , "--beneficiary-addr"
                           , sampleWalletAddr
                           ]
                    ) of
                    Left msg ->
                        T.unpack msg
                            `shouldSatisfy` ("beneficiary-addr" `isInfixOf`)
                    Right route ->
                        expectationFailure
                            ("expected Left, got: " <> show route)

            it "rejects --to on a non-contingency scope" $
                case classifyArgs
                    (baseSingleArgv <> ["--to", "middleware:50"]) of
                    Left msg ->
                        T.unpack msg `shouldSatisfy` ("--to" `isInfixOf`)
                    Right route ->
                        expectationFailure
                            ("expected Left, got: " <> show route)
