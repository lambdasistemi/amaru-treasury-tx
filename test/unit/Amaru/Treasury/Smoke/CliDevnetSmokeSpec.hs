{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Smoke.CliDevnetSmokeSpec
Description : Static no-fallback guard for the CLI DevNet smoke entrypoint
License     : Apache-2.0

Issue #161 ships @scripts\/smoke\/smoke.sh@ as the
operator/CLI proof layer for the DevNet bootstrap +
disburse play. The acceptance contract is that the
script (and any narrow host helper) drives the shipped
@amaru-treasury-tx@ CLI rather than re-entering the
in-process library runners that @SmokeSpec@ uses.

This spec mechanically pins three properties:

  * the public smoke script exists and is executable;
  * no product script or host file contains forbidden
    in-process runner references; and
  * the governance vote reachability gap is recorded
    here as an audit fixture rather than implied:
    the shipped CLI exposes proposal and
    materialization sub-actions only, while the
    legacy library source still carries a
    @submitVoteTx@ path. Slice 4 is the live proof
    that the patched DevNet genesis either does not
    require a shipped vote tx, or fails loudly with
    @missing-shipped-governance-vote@.
-}
module Amaru.Treasury.Smoke.CliDevnetSmokeSpec (spec) where

import Control.Monad (forM_, unless, when)
import Data.List (isInfixOf)
import Data.Maybe (catMaybes)
import System.Directory
    ( doesFileExist
    , executable
    , getPermissions
    )
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    , shouldSatisfy
    )

-- | The public CLI/operator smoke entrypoint shipped by #161.
smokeScriptPath :: FilePath
smokeScriptPath = "scripts/smoke/smoke.sh"

-- | The optional narrow DevNet lifecycle host. Present from Slice 2.
hostMainPath :: FilePath
hostMainPath = "app/devnet-cli-smoke-host/Main.hs"

-- | Legacy library source that still carries an in-process governance vote.
legacyGovernanceLibPath :: FilePath
legacyGovernanceLibPath =
    "lib/Amaru/Treasury/Devnet/GovernanceWithdrawalInit.hs"

-- | Shipped CLI wizard that should expose proposal and materialization only.
shippedGovernanceCliPath :: FilePath
shippedGovernanceCliPath =
    "lib/Amaru/Treasury/Cli/GovernanceWithdrawalInitWizard.hs"

{- | Forbidden references for product (non-test) smoke files.

The names of in-process runners that the CLI smoke must
not enter. The string list is the canonical contract;
new fallbacks should be added here, not weakened.
-}
forbiddenRunnerStrings :: [String]
forbiddenRunnerStrings =
    [ "runDevnet"
    , "Amaru.Treasury.Devnet.Runner"
    , "cabal test devnet-tests"
    , "DEVNET_SMOKE_PHASE"
    ]

{- | Product files that the static guard scans.

Scoped on purpose: this list does not include the
spec/plan/tasks files under @specs/@, nor this test
source, because all three legitimately name the
forbidden strings as documentation/contract data.
-}
guardedProductFiles :: [FilePath]
guardedProductFiles =
    [ smokeScriptPath
    , hostMainPath
    ]

spec :: Spec
spec = describe "CLI DevNet smoke static guard (#161)" $ do
    describe "public entrypoint" $ do
        it "scripts/smoke/smoke.sh exists" $ do
            exists <- doesFileExist smokeScriptPath
            exists `shouldBe` True

        it "scripts/smoke/smoke.sh is executable" $ do
            exists <- doesFileExist smokeScriptPath
            unless exists $
                expectationFailure $
                    "missing: " <> smokeScriptPath
            perms <- getPermissions smokeScriptPath
            perms `shouldSatisfy` executable

        it "scripts/smoke/smoke.sh advertises --help" $ do
            contents <- readIfPresent smokeScriptPath
            case contents of
                Nothing ->
                    expectationFailure $
                        "missing: " <> smokeScriptPath
                Just src ->
                    forM_
                        [ "--run-dir"
                        , "--inside-devnet"
                        , "--phase"
                        , "--timeout-seconds"
                        , "--force"
                        , "--help"
                        ]
                        $ \flag ->
                            src `shouldSatisfyContain` flag

    describe "no in-process runner fallback" $ do
        forM_ forbiddenRunnerStrings $ \needle ->
            it ("no product smoke file contains " <> show needle) $ do
                hits <- collectHits needle guardedProductFiles
                hits `shouldBe` []

    describe "governance vote reachability audit" $ do
        it
            "shipped CLI exposes proposal and materialization actions"
            $ do
                src <- mustRead shippedGovernanceCliPath
                src `shouldSatisfyContain` "GovernanceWithdrawalInitProposalOpts"
                src
                    `shouldSatisfyContain` "GovernanceWithdrawalInitMaterializationOpts"

        it
            "shipped CLI has no vote sub-action"
            $ do
                src <- mustRead shippedGovernanceCliPath
                src `shouldSatisfyNotContain` "GovernanceWithdrawalInitVoteOpts"

        it
            "legacy library still carries the in-process submitVoteTx path"
            $ do
                src <- mustRead legacyGovernanceLibPath
                src `shouldSatisfyContain` "submitVoteTx"

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------

readIfPresent :: FilePath -> IO (Maybe String)
readIfPresent path = do
    exists <- doesFileExist path
    if exists
        then Just <$> readFile path
        else pure Nothing

mustRead :: FilePath -> IO String
mustRead path = do
    exists <- doesFileExist path
    if exists
        then readFile path
        else do
            expectationFailure $ "missing file: " <> path
            pure ""

collectHits :: String -> [FilePath] -> IO [FilePath]
collectHits needle paths = do
    matches <- mapM (matchOne needle) paths
    pure (catMaybes matches)

matchOne :: String -> FilePath -> IO (Maybe FilePath)
matchOne needle path = do
    contents <- readIfPresent path
    case contents of
        Nothing -> pure Nothing
        Just src ->
            if needle `isInfixOf` src
                then pure (Just path)
                else pure Nothing

shouldSatisfyContain :: String -> String -> IO ()
shouldSatisfyContain haystack needle =
    unless (needle `isInfixOf` haystack) $
        expectationFailure $
            "expected to contain " <> show needle

shouldSatisfyNotContain :: String -> String -> IO ()
shouldSatisfyNotContain haystack needle =
    when (needle `isInfixOf` haystack) $
        expectationFailure $
            "expected to NOT contain " <> show needle
