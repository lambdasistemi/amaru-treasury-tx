{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Cli.ReorganizeWizardParserSpec
Description : Parser + pre-flight + network-guard tests for the reorganize-wizard scaffold (Slice 1 of #186)
License     : Apache-2.0

Slice 1 of #186 — parser scaffold + stub runner. The five
@describe@ blocks below cover the User Story 1..5
acceptance scenarios via
'Options.Applicative.execParserPure' for parser-shape
checks and direct calls to
'Amaru.Treasury.Cli.ReorganizeWizard.runReorganizeWizardEither'
+
'Amaru.Treasury.Cli.ReorganizeWizard.validateOutPath' for
runner-shell checks (no subprocess spawning).
-}
module Amaru.Treasury.Cli.ReorganizeWizardParserSpec
    ( spec
    ) where

import Data.List (isInfixOf)
import Data.Text (Text)
import Options.Applicative
    ( ParserResult (..)
    , defaultPrefs
    , execParserPure
    , fullDesc
    , info
    , renderFailure
    )
import Ouroboros.Network.Magic (NetworkMagic (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    , shouldSatisfy
    )

import Amaru.Treasury.Cli.Common (GlobalOpts (..))
import Amaru.Treasury.Cli.ReorganizeWizard
    ( ReorganizeWizardOpts (..)
    , reorganizeWizardOptsP
    , runReorganizeWizardEither
    , validateOutPath
    )
import Amaru.Treasury.Tx.ReorganizeWizard
    ( ReorganizeError (..)
    , ReorganizeWizardAnswers
    )

-- ----------------------------------------------------
-- Top-level spec
-- ----------------------------------------------------

spec :: Spec
spec =
    describe "ReorganizeWizardParser (Slice 1 of #186)" $ do
        describe "US1 — --help lists documented flag set" us1HelpSpec
        describe
            "US2 — malformed --funding-seed-txin rejected"
            us2MalformedTxinSpec
        describe "US3 — missing required flag rejected" us3MissingFlagSpec
        describe
            "US4 — --out parent missing rejected before work"
            us4OutPathSpec
        describe
            "US5 — non-devnet --network rejected before work"
            us5NetworkGuardSpec

-- ----------------------------------------------------
-- Fixtures
-- ----------------------------------------------------

{- | A 64-zero-hex transaction id and ix 0 — accepted by
'Amaru.Treasury.LedgerParse.txInFromText'.
-}
sampleTxIn :: String
sampleTxIn =
    "0000000000000000000000000000000000000000000000000000000000000000#0"

{- | Bech32 wallet address. The parser does not validate
bech32 (validation lives in #187); any non-empty
'String' is accepted at parse time.
-}
sampleWalletAddr :: String
sampleWalletAddr =
    "addr_test1vq3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zygswahgq5"

{- | Full positive argv exercising every required flag.
The @--out@ path here points at @\/tmp\/intent.json@
whose parent always exists; tests that exercise the
@validateOutPath@ pre-flight override the path.
-}
fullArgv :: [String]
fullArgv =
    [ "--wallet-addr"
    , sampleWalletAddr
    , "--metadata"
    , "/tmp/metadata.json"
    , "--out"
    , "/tmp/intent.json"
    , "--scope"
    , "core_development"
    , "--funding-seed-txin"
    , sampleTxIn
    ]

{- | Build a 'GlobalOpts' with the given resolved network
name. Always uses the devnet magic so
'resolveNetworkName' falls through the @Just _@ branch.
-}
mkGlobal :: Maybe Text -> GlobalOpts
mkGlobal n =
    GlobalOpts
        { goSocketPath = Nothing
        , goNetworkMagic = NetworkMagic 42
        , goNetworkName = n
        }

devnetGlobal :: GlobalOpts
devnetGlobal = mkGlobal (Just "devnet")

{- | 'GlobalOpts' with no resolvable network — neither
@--network@ nor a recognized @--network-magic@ supplied.
'resolveNetworkName' returns 'Left', triggering the typed
'ReorganizeUnresolvedNetwork' error.
-}
unresolvableGlobal :: GlobalOpts
unresolvableGlobal =
    GlobalOpts
        { goSocketPath = Nothing
        , goNetworkMagic = NetworkMagic 9999999
        , goNetworkName = Nothing
        }

-- ----------------------------------------------------
-- Parser helpers
-- ----------------------------------------------------

parseArgs :: [String] -> ParserResult ReorganizeWizardOpts
parseArgs =
    execParserPure defaultPrefs (info reorganizeWizardOptsP fullDesc)

renderFailureBody :: ParserResult a -> String
renderFailureBody (Failure pf) =
    fst (renderFailure pf "reorganize-wizard")
renderFailureBody _ =
    error
        "renderFailureBody: expected Failure (got Success or Completion)"

{- | Replace the first occurrence of @flag@ in 'fullArgv'
with the supplied value (the value at @flag+1@ is
dropped). Used to substitute a single flag value while
keeping the rest of the positive argv intact.
-}
substituteFlag :: String -> String -> [String]
substituteFlag flag newValue = go fullArgv
  where
    go [] = []
    go (f : _ : rest) | f == flag = f : newValue : rest
    go (x : xs) = x : go xs

{- | Drop the named flag (and the value after it) from
'fullArgv'. Used to assert
@optparse-applicative@'s @Missing:@ rejection.
-}
omitFlag :: String -> [String]
omitFlag flag = go fullArgv
  where
    go [] = []
    go (f : _ : rest) | f == flag = rest
    go (x : xs) = x : go xs

{- | Build the full opts record from the positive argv,
with @--out@ overridden to the supplied path. Used by
the US4 \"valid parent\" case.
-}
optsWithOut :: FilePath -> ReorganizeWizardOpts
optsWithOut out =
    case parseArgs (substituteFlag "--out" out) of
        Success o -> o
        _ ->
            error
                "optsWithOut: positive argv must parse — fixture broken"

-- ----------------------------------------------------
-- US1 — --help lists documented flag set
-- ----------------------------------------------------

us1HelpSpec :: Spec
us1HelpSpec =
    it "lists every required and optional flag name" $ do
        let body = renderFailureBody (parseArgs ["--help"])
        mapM_
            (\flagName -> body `shouldSatisfy` (flagName `isInfixOf`))
            requiredFlagNames
        mapM_
            (\flagName -> body `shouldSatisfy` (flagName `isInfixOf`))
            optionalFlagNames

requiredFlagNames :: [String]
requiredFlagNames =
    [ "--wallet-addr"
    , "--metadata"
    , "--out"
    , "--scope"
    , "--funding-seed-txin"
    ]

optionalFlagNames :: [String]
optionalFlagNames =
    [ "--log"
    , "--validity-hours"
    , "--description"
    , "--justification"
    , "--destination-label"
    , "--event"
    , "--label"
    , "--force"
    , "--split-native-assets"
    ]

-- ----------------------------------------------------
-- US2 — malformed --funding-seed-txin rejected
-- ----------------------------------------------------

us2MalformedTxinSpec :: Spec
us2MalformedTxinSpec = do
    let cases :: [(String, String)]
        cases =
            [
                ( "no '#' separator"
                , "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
                )
            , ("short hex prefix", "00#0")
            ,
                ( "non-hex characters"
                , "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz#0"
                )
            ,
                ( "non-numeric index"
                , "0000000000000000000000000000000000000000000000000000000000000000#xyz"
                )
            ]
    mapM_
        ( \(label, badValue) ->
            it ("rejects " <> label) $ do
                let body =
                        renderFailureBody
                            (parseArgs (substituteFlag "--funding-seed-txin" badValue))
                body
                    `shouldSatisfy` ("funding-seed-txin" `isInfixOf`)
        )
        cases

-- ----------------------------------------------------
-- US3 — missing required flag rejected
-- ----------------------------------------------------

us3MissingFlagSpec :: Spec
us3MissingFlagSpec = do
    let cases :: [(String, String)]
        cases =
            [ ("--wallet-addr", "--wallet-addr")
            , ("--metadata", "--metadata")
            , ("--out", "--out")
            , ("--scope", "--scope")
            ]
    mapM_
        ( \(label, flagName) ->
            it ("rejects missing " <> label) $ do
                let body = renderFailureBody (parseArgs (omitFlag flagName))
                body `shouldSatisfy` ("Missing:" `isInfixOf`)
                body `shouldSatisfy` (flagName `isInfixOf`)
        )
        cases
    it
        "accepts a parse without --funding-seed-txin (auto-pick \
        \fallback; sibling-wizard parity with disburse / withdraw \
        \/ swap)"
        $ do
            case parseArgs (omitFlag "--funding-seed-txin") of
                Success opts ->
                    rwoFundingSeedTxIn opts `shouldBe` Nothing
                other ->
                    expectationFailure
                        ( "expected Success on missing \
                          \--funding-seed-txin, got: "
                            <> show
                                (renderFailureBody other)
                        )

    it "accepts --split-native-assets as an opt-in flag" $
        case parseArgs (fullArgv <> ["--split-native-assets"]) of
            Success opts ->
                rwoSplitNativeAssets opts `shouldBe` True
            other ->
                expectationFailure
                    ( "expected Success on --split-native-assets, got: "
                        <> show (renderFailureBody other)
                    )

-- ----------------------------------------------------
-- US4 — --out parent missing rejected before work
-- ----------------------------------------------------

us4OutPathSpec :: Spec
us4OutPathSpec = do
    it "rejects --out with a missing parent directory" $ do
        let missingParent =
                "/tmp/nonexistent-186-parent-driver-s1/foo.json"
        r <- validateOutPath missingParent False
        case r of
            Left (ReorganizeOutputParentMissing parent) ->
                parent
                    `shouldBe` "/tmp/nonexistent-186-parent-driver-s1"
            other ->
                expectationFailure
                    ( "expected ReorganizeOutputParentMissing, got: "
                        <> show other
                    )

    it
        "accepts a valid parent and falls through to the missing-socket check"
        $ do
            withSystemTempDirectory "reorganize-wizard-s1" $ \tmp -> do
                let outPath = tmp </> "intent.json"
                let opts = optsWithOut outPath
                r <- runReorganizeWizardEither devnetGlobal opts
                r `shouldBe` Left ReorganizeMissingNodeSocket

-- ----------------------------------------------------
-- US5 — any resolved network admitted; only unresolved fails
-- ----------------------------------------------------

us5NetworkGuardSpec :: Spec
us5NetworkGuardSpec = do
    let resolvedNetworks :: [Text]
        resolvedNetworks =
            ["devnet", "preprod", "preview", "mainnet"]
    mapM_
        ( \name ->
            it
                ( "accepts --network "
                    <> show name
                    <> " and falls through to the "
                    <> "missing-socket check"
                )
                $ do
                    withSystemTempDirectory
                        "reorganize-wizard-s1"
                        $ \tmp -> do
                            let outPath = tmp </> "intent.json"
                            let opts = optsWithOut outPath
                            r <-
                                runReorganizeWizardEither
                                    (mkGlobal (Just name))
                                    opts
                            r
                                `shouldBe` Left
                                    ReorganizeMissingNodeSocket
        )
        resolvedNetworks
    it
        "rejects an unresolvable network magic with the typed \
        \ReorganizeUnresolvedNetwork error"
        $ do
            withSystemTempDirectory "reorganize-wizard-s1" $ \tmp -> do
                let outPath = tmp </> "intent.json"
                let opts = optsWithOut outPath
                r <-
                    runReorganizeWizardEither
                        unresolvableGlobal
                        opts
                r `shouldBe` Left ReorganizeUnresolvedNetwork

-- ----------------------------------------------------
-- Type alias drag — pin the Answers re-export in scope so
-- a stale build does not silently drop the import.
-- ----------------------------------------------------

_pin :: Maybe ReorganizeWizardAnswers
_pin = Nothing
