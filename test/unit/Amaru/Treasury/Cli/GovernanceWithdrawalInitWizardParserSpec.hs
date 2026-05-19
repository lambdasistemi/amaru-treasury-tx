{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Cli.GovernanceWithdrawalInitWizardParserSpec
Description : Parser-shape and --out check tests for governance-withdrawal-init-wizard (Slice 1 of #160)
License     : Apache-2.0

Slice 1 only validates the parser surface and the typed
@--out@ checks. Slice 2 wires the @proposal@ live path and
Slice 3 wires @materialization@; both follow the
'StakeRewardInitWizard' shape.

The tests reference 'governanceWithdrawalInitWizardOptsP'
and 'validateOutPath' (parent-dir + collision check entry)
from 'Amaru.Treasury.Cli.GovernanceWithdrawalInitWizard',
and 'GovernanceWithdrawalInitError' from
'Amaru.Treasury.Tx.GovernanceWithdrawalInitWizard'.
-}
module Amaru.Treasury.Cli.GovernanceWithdrawalInitWizardParserSpec (spec) where

import Control.Exception (bracket)
import Data.List (isInfixOf)
import Options.Applicative
    ( ParserResult (..)
    , defaultPrefs
    , execParserPure
    , helper
    , info
    , renderFailure
    , (<**>)
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

import Amaru.Treasury.Cli.GovernanceWithdrawalInitWizard
    ( GovernanceWithdrawalInitWizardOpts (..)
    , ProposalOpts (..)
    , governanceWithdrawalInitWizardOptsP
    , validateOutPath
    )
import Amaru.Treasury.Tx.GovernanceWithdrawalInitWizard
    ( GovernanceWithdrawalInitError (..)
    )
import Data.Text qualified as T

spec :: Spec
spec = describe "GovernanceWithdrawalInitWizardParser (Slice 1 of #160)" $ do
    -- T001
    describe "governance-withdrawal-init-wizard top-level" $ do
        it
            "top-level --help lists both subcommand names"
            $ do
                let body = parserHelpBody ["--help"]
                body `shouldSatisfy` ("proposal" `isInfixOf`)
                body `shouldSatisfy` ("materialization" `isInfixOf`)
        it
            "recognizes proposal, materialization as valid subcommands"
            $ do
                parserHelpBody ["proposal", "--help"]
                    `shouldSatisfy` not . isInvalidArg
                parserHelpBody ["materialization", "--help"]
                    `shouldSatisfy` not . isInvalidArg
                parserHelpBody ["totally-not-a-subcommand", "--help"]
                    `shouldSatisfy` isInvalidArg

    -- T002
    describe "proposal --help flag list" $ do
        it "lists the shared flags plus the 5 proposal-specific flags" $ do
            let body = parserHelpBody ["proposal", "--help"]
            -- Shared
            body `shouldSatisfy` ("--wallet-addr" `isInfixOf`)
            body `shouldSatisfy` ("--registry" `isInfixOf`)
            body `shouldSatisfy` ("--stake-reward-accounts" `isInfixOf`)
            body `shouldSatisfy` ("--funding-seed-txin" `isInfixOf`)
            body `shouldSatisfy` ("--out" `isInfixOf`)
            body `shouldSatisfy` ("--validity-hours" `isInfixOf`)
            body `shouldSatisfy` ("--log" `isInfixOf`)
            body `shouldSatisfy` ("--force" `isInfixOf`)
            -- Proposal-specific
            body `shouldSatisfy` ("--funding-stake-key-hash" `isInfixOf`)
            body `shouldSatisfy` ("--voter-key-hash" `isInfixOf`)
            body `shouldSatisfy` ("--withdrawal-amount-lovelace" `isInfixOf`)
            body `shouldSatisfy` ("--anchor-url" `isInfixOf`)
            body `shouldSatisfy` ("--anchor-hash" `isInfixOf`)

    -- T003
    describe "materialization --help flag list" $ do
        it "lists the shared flags plus --rewards-lovelace" $ do
            let body = parserHelpBody ["materialization", "--help"]
            body `shouldSatisfy` ("--wallet-addr" `isInfixOf`)
            body `shouldSatisfy` ("--registry" `isInfixOf`)
            body `shouldSatisfy` ("--stake-reward-accounts" `isInfixOf`)
            body `shouldSatisfy` ("--funding-seed-txin" `isInfixOf`)
            body `shouldSatisfy` ("--out" `isInfixOf`)
            body `shouldSatisfy` ("--validity-hours" `isInfixOf`)
            body `shouldSatisfy` ("--log" `isInfixOf`)
            body `shouldSatisfy` ("--force" `isInfixOf`)
            body `shouldSatisfy` ("--rewards-lovelace" `isInfixOf`)
            -- Materialization MUST NOT carry the proposal flags
            body `shouldSatisfy` not . ("--funding-stake-key-hash" `isInfixOf`)
            body `shouldSatisfy` not . ("--voter-key-hash" `isInfixOf`)
            body
                `shouldSatisfy` not . ("--withdrawal-amount-lovelace" `isInfixOf`)
            body `shouldSatisfy` not . ("--anchor-url" `isInfixOf`)
            body `shouldSatisfy` not . ("--anchor-hash" `isInfixOf`)

    -- T004
    describe "--funding-seed-txin rejects malformed input" $ do
        it "proposal --funding-seed-txin without # is rejected" $
            isParseFailure
                ( replaceFlag "--funding-seed-txin" "deadbeef" proposalArgs
                )
                `shouldBe` True
        it "materialization --funding-seed-txin with bad index is rejected" $
            isParseFailure
                ( replaceFlag
                    "--funding-seed-txin"
                    (goodTxIdHex <> "#notanumber")
                    materializationArgs
                )
                `shouldBe` True

    -- T005
    describe "key-hash flags reject anything other than 56 hex chars" $ do
        it "proposal --funding-stake-key-hash with 55 chars is rejected" $
            isParseFailure
                ( replaceFlag
                    "--funding-stake-key-hash"
                    (replicate 55 'a')
                    proposalArgs
                )
                `shouldBe` True
        it "proposal --funding-stake-key-hash with 57 chars is rejected" $
            isParseFailure
                ( replaceFlag
                    "--funding-stake-key-hash"
                    (replicate 57 'a')
                    proposalArgs
                )
                `shouldBe` True
        it "proposal --funding-stake-key-hash with non-hex chars is rejected" $
            isParseFailure
                ( replaceFlag
                    "--funding-stake-key-hash"
                    (replicate 56 'z')
                    proposalArgs
                )
                `shouldBe` True
        it "proposal --voter-key-hash with 55 chars is rejected" $
            isParseFailure
                ( replaceFlag
                    "--voter-key-hash"
                    (replicate 55 'a')
                    proposalArgs
                )
                `shouldBe` True
        it "proposal --voter-key-hash with non-hex chars is rejected" $
            isParseFailure
                ( replaceFlag
                    "--voter-key-hash"
                    (replicate 56 'g')
                    proposalArgs
                )
                `shouldBe` True
        it "proposal with exact-length hex passes parser" $
            -- This proves the parser ACCEPTS valid input on the happy path
            -- (the other tests prove it rejects invalid input).
            isParseFailure proposalArgs `shouldBe` False

        it
            "proposal preserves operator-supplied mixed-case hex verbatim \
            \in poFundingStakeKeyHash, poVoterKeyHash, poAnchorHash"
            $ do
                -- NFR-008 + FR-004: the parser validates length + hex-ness
                -- but MUST NOT normalize (no lower-casing). The operator's
                -- original casing is preserved through to ProposalOpts so
                -- the eventual intent payload declares exactly what the
                -- operator typed.
                -- 56-char mixed-case hex blocks built from a 4-char unit
                -- repeated 14 times, and a 64-char block built from a
                -- different 4-char unit repeated 16 times. Programmatic
                -- construction sidesteps hand-counting errors and proves
                -- the strings carry both upper- and lower-case hex
                -- characters that NFR-008's verbatim contract must preserve.
                let mixedFunding = concat (replicate 14 "AbCd")
                    mixedVoter = concat (replicate 14 "A1b2")
                    mixedAnchor = concat (replicate 16 "fF00")
                length mixedFunding `shouldBe` 56
                length mixedVoter `shouldBe` 56
                length mixedAnchor `shouldBe` 64
                let argv =
                        replaceFlag "--funding-stake-key-hash" mixedFunding $
                            replaceFlag "--voter-key-hash" mixedVoter $
                                replaceFlag "--anchor-hash" mixedAnchor proposalArgs
                case parseProposalOpts argv of
                    Right po -> do
                        poFundingStakeKeyHash po `shouldBe` T.pack mixedFunding
                        poVoterKeyHash po `shouldBe` T.pack mixedVoter
                        poAnchorHash po `shouldBe` T.pack mixedAnchor
                    Left err ->
                        error
                            ( "expected Right ProposalOpts, got Left: "
                                <> err
                            )

    -- T006
    describe "--anchor-hash rejects anything other than 64 hex chars" $ do
        it "proposal --anchor-hash with 63 chars is rejected" $
            isParseFailure
                ( replaceFlag
                    "--anchor-hash"
                    (replicate 63 'a')
                    proposalArgs
                )
                `shouldBe` True
        it "proposal --anchor-hash with 65 chars is rejected" $
            isParseFailure
                ( replaceFlag
                    "--anchor-hash"
                    (replicate 65 'a')
                    proposalArgs
                )
                `shouldBe` True
        it "proposal --anchor-hash with non-hex chars is rejected" $
            isParseFailure
                ( replaceFlag
                    "--anchor-hash"
                    (replicate 64 'z')
                    proposalArgs
                )
                `shouldBe` True

    -- T007
    describe "amount flags reject zero or negative values" $ do
        it "proposal --withdrawal-amount-lovelace = 0 is rejected" $
            isParseFailure
                ( replaceFlag
                    "--withdrawal-amount-lovelace"
                    "0"
                    proposalArgs
                )
                `shouldBe` True
        it "proposal --withdrawal-amount-lovelace = -1 is rejected" $
            isParseFailure
                ( replaceFlag
                    "--withdrawal-amount-lovelace"
                    "-1"
                    proposalArgs
                )
                `shouldBe` True
        it "materialization --rewards-lovelace = 0 is rejected" $
            isParseFailure
                ( replaceFlag
                    "--rewards-lovelace"
                    "0"
                    materializationArgs
                )
                `shouldBe` True
        it "materialization --rewards-lovelace = -1 is rejected" $
            isParseFailure
                ( replaceFlag
                    "--rewards-lovelace"
                    "-1"
                    materializationArgs
                )
                `shouldBe` True

    -- T008
    describe "missing required flags are rejected" $ do
        it "proposal without --registry is rejected" $
            isParseFailure (dropFlag "--registry" proposalArgs)
                `shouldBe` True
        it "proposal without --stake-reward-accounts is rejected" $
            isParseFailure
                (dropFlag "--stake-reward-accounts" proposalArgs)
                `shouldBe` True
        it "proposal without --funding-stake-key-hash is rejected" $
            isParseFailure
                (dropFlag "--funding-stake-key-hash" proposalArgs)
                `shouldBe` True
        it "proposal without --voter-key-hash is rejected" $
            isParseFailure (dropFlag "--voter-key-hash" proposalArgs)
                `shouldBe` True
        it "proposal without --withdrawal-amount-lovelace is rejected" $
            isParseFailure
                ( dropFlag
                    "--withdrawal-amount-lovelace"
                    proposalArgs
                )
                `shouldBe` True
        it "proposal without --anchor-url is rejected" $
            isParseFailure (dropFlag "--anchor-url" proposalArgs)
                `shouldBe` True
        it "proposal without --anchor-hash is rejected" $
            isParseFailure (dropFlag "--anchor-hash" proposalArgs)
                `shouldBe` True
        it "materialization without --rewards-lovelace is rejected" $
            isParseFailure
                (dropFlag "--rewards-lovelace" materializationArgs)
                `shouldBe` True
        it "materialization without --registry is rejected" $
            isParseFailure (dropFlag "--registry" materializationArgs)
                `shouldBe` True

    describe "--out parent directory checks" $ do
        it
            "missing parent directory surfaces GovernanceWithdrawalInitOutputParentMissing"
            $ do
                r <-
                    validateOutPath
                        "/this/path/should/not/exist-9b3c1f/intent.json"
                        False
                case r of
                    Left
                        (GovernanceWithdrawalInitOutputParentMissing _) -> pure ()
                    other ->
                        error
                            ( "expected"
                                <> " GovernanceWithdrawalInitOutputParentMissing"
                                <> ", got: "
                                <> show other
                            )

    describe "--out collision without --force" $ do
        it
            "existing file without --force surfaces GovernanceWithdrawalInitOutputExistsNoForce"
            $ withScratchDir "govwithd-out-noforce-"
            $ \dir -> do
                (path, h) <- openTempFile dir "intent.json"
                hClose h
                r <- validateOutPath path False
                removeFile path
                case r of
                    Left
                        (GovernanceWithdrawalInitOutputExistsNoForce _) -> pure ()
                    other ->
                        error
                            ( "expected"
                                <> " GovernanceWithdrawalInitOutputExistsNoForce"
                                <> ", got: "
                                <> show other
                            )

        it "existing file WITH --force is accepted" $
            withScratchDir "govwithd-out-force-" $ \dir -> do
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

isInvalidArg :: String -> Bool
isInvalidArg body = "Invalid argument" `isInfixOf` body

parserHelpBody :: [String] -> String
parserHelpBody args =
    case execParserPure
        defaultPrefs
        (info (governanceWithdrawalInitWizardOptsP <**> helper) mempty)
        args of
        Failure failure ->
            let (msg, _) =
                    renderFailure failure "governance-withdrawal-init-wizard"
            in  msg
        Success _ -> ""
        CompletionInvoked _ -> ""

isParseFailure :: [String] -> Bool
isParseFailure args =
    case execParserPure
        defaultPrefs
        (info (governanceWithdrawalInitWizardOptsP <**> helper) mempty)
        args of
        Failure{} -> True
        Success{} -> False
        CompletionInvoked{} -> False

{- | Parse an argv vector and pattern-match the result to the
proposal arm of the discriminated union. Used by the
verbatim-preservation test to inspect the typed
'ProposalOpts' value the parser produced.
-}
parseProposalOpts :: [String] -> Either String ProposalOpts
parseProposalOpts args =
    case execParserPure
        defaultPrefs
        (info (governanceWithdrawalInitWizardOptsP <**> helper) mempty)
        args of
        Success (GovernanceWithdrawalInitProposalOpts po) -> Right po
        Success (GovernanceWithdrawalInitMaterializationOpts _) ->
            Left "got materialization, expected proposal"
        Failure failure ->
            let (msg, _) =
                    renderFailure failure "governance-withdrawal-init-wizard"
            in  Left msg
        CompletionInvoked _ -> Left "completion invoked"

-- | Common flags every subcommand needs.
commonArgs :: [String]
commonArgs =
    [ "--wallet-addr"
    , "addr_test1q"
    , "--registry"
    , "/tmp/registry.json"
    , "--stake-reward-accounts"
    , "/tmp/accounts.json"
    , "--funding-seed-txin"
    , goodTxIn
    , "--out"
    , "/tmp/intent.json"
    ]

-- | Happy-path proposal args (all required flags present, all values valid).
proposalArgs :: [String]
proposalArgs =
    "proposal"
        : commonArgs
        ++ [ "--funding-stake-key-hash"
           , replicate 56 'a'
           , "--voter-key-hash"
           , replicate 56 'b'
           , "--withdrawal-amount-lovelace"
           , "50000000"
           , "--anchor-url"
           , "https://example.com/anchor.json"
           , "--anchor-hash"
           , replicate 64 'c'
           ]

-- | Happy-path materialization args.
materializationArgs :: [String]
materializationArgs =
    "materialization"
        : commonArgs
        ++ [ "--rewards-lovelace"
           , "12345678"
           ]

{- | Drop one --flag and its single value from an argv list.
Pre: the flag is present exactly once and is immediately followed
by its value. Used to construct missing-required-flag tests.
-}
dropFlag :: String -> [String] -> [String]
dropFlag flag = go
  where
    go [] = []
    go (x : v : rest)
        | x == flag = rest
        | otherwise = x : go (v : rest)
    go (x : rest) = x : go rest

{- | Replace the value of one --flag in an argv list.
Pre: the flag is present exactly once and is immediately followed
by its value.
-}
replaceFlag :: String -> String -> [String] -> [String]
replaceFlag flag newValue = go
  where
    go [] = []
    go (x : _ : rest)
        | x == flag = x : newValue : rest
    go (x : rest) = x : go rest

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
