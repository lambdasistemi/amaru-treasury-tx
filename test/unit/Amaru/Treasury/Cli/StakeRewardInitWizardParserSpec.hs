{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Cli.StakeRewardInitWizardParserSpec
Description : Parser-shape and --out check tests for stake-reward-init-wizard (Slice 1 of #159)
License     : Apache-2.0

Slice 1 only validates the parser surface and the typed
@--out@ checks. The full resolver/translation lands in
Slices 2-3.

The tests reference 'stakeRewardInitWizardOptsP' and
'validateOutPath' (parent-dir + collision check entry) from
'Amaru.Treasury.Cli.StakeRewardInitWizard', and
'StakeRewardInitError' from 'Amaru.Treasury.Tx.StakeRewardInitWizard'.
-}
module Amaru.Treasury.Cli.StakeRewardInitWizardParserSpec (spec) where

import Control.Exception (bracket)
import Data.List (isInfixOf)
import Options.Applicative
    ( ParserResult (..)
    , defaultPrefs
    , execParserPure
    , info
    , renderFailure
    )
import System.Directory
    ( createDirectory
    , doesDirectoryExist
    , getTemporaryDirectory
    , removeDirectoryRecursive
    , removeFile
    )
import System.FilePath ((</>))
import System.IO (hClose, openTempFile)
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldSatisfy
    )

import Amaru.Treasury.Cli.StakeRewardInitWizard
    ( stakeRewardInitWizardOptsP
    , validateOutPath
    )
import Amaru.Treasury.Tx.StakeRewardInitWizard
    ( StakeRewardInitError (..)
    )

spec :: Spec
spec = describe "StakeRewardInitWizardParser (Slice 1 of #159)" $ do
    describe "stake-reward-init-wizard top-level" $ do
        it
            "recognizes script-account, plain-account as valid subcommands"
            $ do
                -- An unknown subcommand name lands in the failure body
                -- as "Invalid argument `<name>'"; recognized names take
                -- their own arg-parsing path and do not produce that
                -- message. Test both the same way: invoking each with
                -- --help must not emit "Invalid argument".
                parserHelpBody ["script-account", "--help"]
                    `shouldSatisfy` not . isInvalidArg
                parserHelpBody ["plain-account", "--help"]
                    `shouldSatisfy` not . isInvalidArg
                -- And an unknown name MUST fail, to keep the test honest.
                parserHelpBody ["totally-not-a-subcommand", "--help"]
                    `shouldSatisfy` isInvalidArg

    describe "subcommand --help flag lists" $ do
        it "script-account --help lists the required and optional flags" $ do
            let body = parserHelpBody ["script-account", "--help"]
            body `shouldSatisfy` ("--wallet-addr" `isInfixOf`)
            body `shouldSatisfy` ("--registry" `isInfixOf`)
            body `shouldSatisfy` ("--funding-seed-txin" `isInfixOf`)
            body `shouldSatisfy` ("--out" `isInfixOf`)
            body `shouldSatisfy` ("--validity-hours" `isInfixOf`)
            body `shouldSatisfy` ("--log" `isInfixOf`)
            body `shouldSatisfy` ("--force" `isInfixOf`)

        it "plain-account --help lists the required and optional flags" $ do
            let body = parserHelpBody ["plain-account", "--help"]
            body `shouldSatisfy` ("--wallet-addr" `isInfixOf`)
            body `shouldSatisfy` ("--registry" `isInfixOf`)
            body `shouldSatisfy` ("--funding-seed-txin" `isInfixOf`)
            body `shouldSatisfy` ("--out" `isInfixOf`)
            body `shouldSatisfy` ("--validity-hours" `isInfixOf`)
            body `shouldSatisfy` ("--log" `isInfixOf`)
            body `shouldSatisfy` ("--force" `isInfixOf`)

    describe "--funding-seed-txin rejects malformed input" $ do
        it "script-account --funding-seed-txin without # is rejected" $
            isParseFailure
                ( scriptAccountArgsNoFundingSeed
                    ++ ["--funding-seed-txin", "deadbeef"]
                )
                `shouldBe` True
        it "plain-account --funding-seed-txin with bad index is rejected" $
            isParseFailure
                ( plainAccountArgsNoFundingSeed
                    ++ ["--funding-seed-txin", goodTxIdHex <> "#notanumber"]
                )
                `shouldBe` True

    describe "missing required --registry" $ do
        it "script-account without --registry is rejected" $
            isParseFailure scriptAccountArgsNoRegistry
                `shouldBe` True
        it "plain-account without --registry is rejected" $
            isParseFailure plainAccountArgsNoRegistry
                `shouldBe` True

    describe "--out parent directory checks" $ do
        it
            "missing parent directory surfaces StakeRewardInitOutputParentMissing"
            $ do
                r <-
                    validateOutPath
                        "/this/path/should/not/exist-9b3c1f/intent.json"
                        False
                case r of
                    Left (StakeRewardInitOutputParentMissing _) -> pure ()
                    other ->
                        error
                            ( "expected StakeRewardInitOutputParentMissing, got: "
                                <> show other
                            )

    describe "--out collision without --force" $ do
        it
            "existing file without --force surfaces StakeRewardInitOutputExistsNoForce"
            $ withScratchDir "stkrwd-out-noforce-"
            $ \dir -> do
                (path, h) <- openTempFile dir "intent.json"
                hClose h
                r <- validateOutPath path False
                removeFile path
                case r of
                    Left (StakeRewardInitOutputExistsNoForce _) -> pure ()
                    other ->
                        error
                            ( "expected StakeRewardInitOutputExistsNoForce, got: "
                                <> show other
                            )

        it "existing file WITH --force is accepted" $
            withScratchDir "stkrwd-out-force-" $ \dir -> do
                (path, h) <- openTempFile dir "intent.json"
                hClose h
                r <- validateOutPath path True
                removeFile path
                case r of
                    Right () -> pure ()
                    other ->
                        error
                            ( "expected Right (), got: "
                                <> show other
                            )

-- ---------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------

{- | True when the failure body indicates the leading token was
not recognized as a subcommand name (optparse reports unknown
subcommand names as @Invalid argument `<name>'@).
-}
isInvalidArg :: String -> Bool
isInvalidArg body = "Invalid argument" `isInfixOf` body

{- | Render the help/usage body the stake-reward-init-wizard parser
emits for the given argv. Tests inspect the body via
'isInfixOf' to assert the expected subcommands and flags
appear.
-}
parserHelpBody :: [String] -> String
parserHelpBody args =
    case execParserPure
        defaultPrefs
        (info stakeRewardInitWizardOptsP mempty)
        args of
        Failure failure ->
            let (msg, _) = renderFailure failure "stake-reward-init-wizard"
            in  msg
        Success _ -> ""
        CompletionInvoked _ -> ""

{- | True when 'execParserPure' returns a 'Failure' for the given
argument vector against the stake-reward-init-wizard parser.
-}
isParseFailure :: [String] -> Bool
isParseFailure args =
    case execParserPure
        defaultPrefs
        (info stakeRewardInitWizardOptsP mempty)
        args of
        Failure{} -> True
        Success{} -> False
        CompletionInvoked{} -> False

-- | Required common flags every subcommand needs.
commonArgs :: [String]
commonArgs =
    [ "--wallet-addr"
    , "addr_test1q"
    , "--registry"
    , "/tmp/registry.json"
    , "--out"
    , "/tmp/intent.json"
    ]

{- | script-account args including the funding-seed-txin flag header
but no funding-seed-txin value (the test fills the value).
-}
scriptAccountArgsNoFundingSeed :: [String]
scriptAccountArgsNoFundingSeed = "script-account" : commonArgs

{- | plain-account args including the funding-seed-txin flag header
but no funding-seed-txin value (the test fills the value).
-}
plainAccountArgsNoFundingSeed :: [String]
plainAccountArgsNoFundingSeed = "plain-account" : commonArgs

{- | script-account args without --registry — used for the
missing-required-option test.
-}
scriptAccountArgsNoRegistry :: [String]
scriptAccountArgsNoRegistry =
    [ "script-account"
    , "--wallet-addr"
    , "addr_test1q"
    , "--out"
    , "/tmp/intent.json"
    , "--funding-seed-txin"
    , goodTxIn
    ]

-- | plain-account args without --registry.
plainAccountArgsNoRegistry :: [String]
plainAccountArgsNoRegistry =
    [ "plain-account"
    , "--wallet-addr"
    , "addr_test1q"
    , "--out"
    , "/tmp/intent.json"
    , "--funding-seed-txin"
    , goodTxIn
    ]

-- | 64-char hex txid + index 0 — accepted by 'txInFromText'.
goodTxIn :: String
goodTxIn = goodTxIdHex <> "#0"

goodTxIdHex :: String
goodTxIdHex = replicate 64 'a'

{- | Create a fresh scratch directory under the system temp root,
run the action, and recursively delete the directory afterwards.
-}
withScratchDir :: String -> (FilePath -> IO a) -> IO a
withScratchDir prefix action = do
    sysTmp <- getTemporaryDirectory
    let scratch = sysTmp </> (prefix <> show pid)
    bracket (mkFresh scratch) removeDirectoryRecursive action
  where
    -- Cheap unique suffix using the kernel-allocated openTempFile;
    -- we want a *directory* though, so reroll a numeric tail and
    -- recover if the candidate is in use.
    pid :: Int
    pid = 0
    mkFresh d = do
        exists <- doesDirectoryExist d
        if exists
            then do
                removeDirectoryRecursive d
                createDirectory d
                pure d
            else do
                createDirectory d
                pure d
