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
    @submitVoteTx@ path. Slice 4 keeps the missing-vote
    diagnostic for no-reward DevNets, and on the patched
    DevNet drives the shipped materialization surface
    after reward accrual.
-}
module Amaru.Treasury.Smoke.CliDevnetSmokeSpec (spec) where

import Control.Monad (forM_, unless, when)
import Data.List (isInfixOf, isPrefixOf)
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

-- | Human-tutorial recording wrapper shipped alongside the smoke.
recordWrapperPath :: FilePath
recordWrapperPath = "scripts/smoke/record-cli-devnet-smoke"

-- | Legacy library source that still carries an in-process governance vote.
legacyGovernanceLibPath :: FilePath
legacyGovernanceLibPath =
    "lib/Amaru/Treasury/Devnet/GovernanceWithdrawalInit.hs"

-- | Shipped CLI wizard that should expose proposal and materialization only.
shippedGovernanceCliPath :: FilePath
shippedGovernanceCliPath =
    "lib/Amaru/Treasury/Cli/GovernanceWithdrawalInitWizard.hs"

{- | Phase tokens the CLI DevNet smoke recognizes.

The list is the canonical allow-list of phase strings the
@scripts\/smoke\/smoke.sh@ entrypoint and the
@app\/devnet-cli-smoke-host\/Main.hs@ host dispatch must
both keep in sync. Issue #87 adds @\"reorganize\"@.
-}
recognizedPhaseTokens :: [String]
recognizedPhaseTokens =
    [ "scaffold"
    , "preflight"
    , "vault-preflight"
    , "registry-stake"
    , "governance"
    , "disburse"
    , "full"
    , "reorganize"
    ]

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
    , "cardano-cli"
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
    , recordWrapperPath
    ]

{- | Transaction-runner Haskell modules the host must not import.

The host is allowed to use Cardano.Node.Client.E2E.Devnet
(@withCardanoNode@) for node lifecycle only. Anything
that would let it construct, sign, or submit a bootstrap
transaction in process is forbidden here.
-}
forbiddenHostImports :: [String]
forbiddenHostImports =
    [ "Amaru.Treasury.Devnet.Runner"
    , "Amaru.Treasury.Devnet.RegistryInit"
    , "Amaru.Treasury.Devnet.StakeRewardInit"
    , "Amaru.Treasury.Devnet.GovernanceWithdrawalInit"
    , "Amaru.Treasury.Devnet.DisburseSubmit"
    , "runDevnet"
    , "submitVoteTx"
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

    describe "DevNet lifecycle host" $ do
        it "app/devnet-cli-smoke-host/Main.hs exists" $ do
            exists <- doesFileExist hostMainPath
            exists `shouldBe` True

        it "host imports the cardano-node-clients DevNet bring-up" $ do
            src <- mustRead hostMainPath
            src `shouldSatisfyContain` "Cardano.Node.Client.E2E.Devnet"
            src `shouldSatisfyContain` "withCardanoNode"

        it "host does not import any transaction-builder runner module" $ do
            src <- mustRead hostMainPath
            forM_ forbiddenHostImports $ \needle ->
                src `shouldSatisfyNotContain` needle

        it "host exports the funding address for the shell smoke" $ do
            src <- mustRead hostMainPath
            src `shouldSatisfyContain` "CLI_SMOKE_FUNDING_ADDR"
            src `shouldSatisfyContain` "devnetFundingAddress"

    describe "vault preflight surface in smoke.sh" $ do
        it "smoke.sh names shipped CLI signing subcommands" $ do
            src <- mustRead smokeScriptPath
            forM_
                [ "vault create"
                , "witness"
                , "attach-witness"
                ]
                $ \needle ->
                    src `shouldSatisfyContain` needle

        it "smoke.sh exposes a preflight or vault phase" $ do
            src <- mustRead smokeScriptPath
            src `shouldSatisfyContain` "vault-preflight"

    describe "registry-stake CLI surface" $ do
        it "smoke.sh exposes a registry-stake phase" $ do
            src <- mustRead smokeScriptPath
            src `shouldSatisfyContain` "registry-stake"

        it "smoke.sh names shipped registry/stake wizards and tx-pipeline" $ do
            src <- mustRead smokeScriptPath
            forM_
                [ "registry-init-wizard"
                , "stake-reward-init-wizard"
                , "tx-build"
                , "witness"
                , "attach-witness"
                , "submit"
                ]
                $ \needle ->
                    src `shouldSatisfyContain` needle

        it "smoke.sh routes non-inside live phases through the host" $ do
            src <- mustRead smokeScriptPath
            src `shouldSatisfyContain` "devnet-cli-smoke-host"

        it "registry-stake consumes the host funding address" $ do
            src <- mustRead smokeScriptPath
            src `shouldSatisfyContain` "require_env CLI_SMOKE_FUNDING_ADDR"
            src
                `shouldSatisfyContain` "wallet_addr=\"$CLI_SMOKE_FUNDING_ADDR\""

        it
            "accounts.json uses devnet artifact network and Testnet ledger network"
            $ do
                src <- mustRead smokeScriptPath
                src `shouldSatisfyContain` "network: \"devnet\""
                src `shouldSatisfyContain` "ledgerNetwork: \"Testnet\""

    describe "governance CLI surface" $ do
        it "smoke.sh exposes the shipped governance proposal path" $ do
            src <- mustRead smokeScriptPath
            forM_
                [ "governance-withdrawal-init-wizard proposal"
                , "governance-proposal"
                ]
                $ \needle ->
                    src `shouldSatisfyContain` needle

        it "smoke.sh exposes the shipped governance materialization path" $ do
            src <- mustRead smokeScriptPath
            forM_
                [ "governance-withdrawal-init-wizard materialization"
                , "governance-materialization"
                , "governance-withdrawal-init"
                , "materialized.json"
                , "treasuryMaterializedTxIn"
                , "materializationChangeTxIn"
                ]
                $ \needle ->
                    src `shouldSatisfyContain` needle

        it "materialized.json does not hardcode reward observations" $ do
            src <- mustRead smokeScriptPath
            src `shouldSatisfyNotContain` "rewardBeforeSubmitLovelace"
            src `shouldSatisfyNotContain` "rewardAfterSubmitLovelace"

        it "proposal uses funding and voter key hashes for their own roles" $ do
            src <- mustRead smokeScriptPath
            src
                `shouldSatisfyContain` "--funding-stake-key-hash \"$CLI_SMOKE_FUNDING_KEY_HASH\""
            src
                `shouldSatisfyContain` "--voter-key-hash \"$CLI_SMOKE_VOTER_KEY_HASH\""

        it "proposal attaches both funding and voter witnesses" $ do
            src <- mustRead smokeScriptPath
            src `shouldSatisfyContain` "build_sign_submit_multi \\"
            src `shouldSatisfyContain` "\"devnet_funding\""
            src `shouldSatisfyContain` "\"devnet_voter\""

        it "host runs governance assertions for the governance phase" $ do
            src <- mustRead hostMainPath
            src `shouldSatisfyContain` "\"governance\""
            src `shouldSatisfyContain` "runGovernanceAssertionsIfPresent"
            src `shouldSatisfyContain` "governance-materialization-verified"
            src `shouldSatisfyContain` "missing-shipped-governance-vote"
            src `shouldSatisfyContain` "runGovernanceMaterializationAssertions"
            src `shouldSatisfyContain` "queryGovernanceSnapshot"
            src `shouldSatisfyContain` "gcsMaterializedPresent"
            src `shouldSatisfyContain` "gcsMaterializationChangePresent"
            src `shouldSatisfyContain` "writeGovernanceMaterializationSummary"
            src `shouldSatisfyContain` "materializedJson"

        it "host address rendering uses Bech32 not raw UTF-8" $ do
            src <- mustRead hostMainPath
            src `shouldSatisfyNotContain` "decodeUtf8 (serialiseAddr"
            src
                `shouldSatisfyContain` "renderAddr (txOut ^. addrTxOutL)"

    describe "disburse and full CLI surface" $ do
        it "smoke.sh implements a disburse phase function" $ do
            src <- mustRead smokeScriptPath
            src `shouldSatisfyContain` "disburse_phase()"
            src
                `shouldSatisfyContain` "governance-withdrawal-init/materialized.json"
            src
                `shouldSatisfyContain` "require_env CLI_SMOKE_BENEFICIARY_ADDR"

        it "disburse phase names the shipped wizard and tx-pipeline" $ do
            src <- mustRead smokeScriptPath
            forM_
                [ "disburse-wizard"
                , "--unit ada"
                , "--treasury-txin \"$treasury_input\""
                , "tx-build"
                , "witness"
                , "attach-witness"
                , "submit"
                ]
                $ \needle ->
                    src `shouldSatisfyContain` needle

        it "disburse summary links expected artifacts and tx ids" $ do
            src <- mustRead smokeScriptPath
            forM_
                [ "disburse-submit/summary.json"
                , "disburseIntent"
                , "disburseTxId"
                , "beneficiaryTxIn"
                , "walletChangeTxIn"
                , "treasuryInput"
                , "treasuryOutputTxIn"
                , "expected 3 outputs (treasury + beneficiary + wallet change)"
                , "chainAssertionsRequest"
                ]
                $ \needle ->
                    src `shouldSatisfyContain` needle

        it "full phase writes a top-level linked summary" $ do
            src <- mustRead smokeScriptPath
            src `shouldSatisfyContain` "full_phase()"
            src `shouldSatisfyContain` "write_full_summary"
            forM_
                [ "registrySummary"
                , "governanceSummary"
                , "disburseSummary"
                , "runDir"
                , "socketPath"
                , "verificationStatus"
                ]
                $ \needle ->
                    src `shouldSatisfyContain` needle

        it "host marks full summary passed after chain assertions" $ do
            src <- mustRead hostMainPath
            let fullBranch = sectionBetween "\"full\" -> do" "_ -> case" src
            fullBranch `shouldSatisfyContain` "markFullSummaryPassed"
            forM_
                [ "markFullSummaryPassed"
                , "verificationStatus\" .= (\"passed\""
                , "chainAssertions\" .= chainAssertionsPath"
                , "disburseChainAssertions\" .= disburseAssertionsPath"
                , "seedSplitTxId"
                , "registryMintTxId"
                , "referenceScriptsTxId"
                , "stakeRewardScriptAccountTxId"
                , "stakeRewardPlainAccountTxId"
                , "proposalTxId"
                , "materializationTxId"
                , "disburseTxId"
                ]
                $ \needle ->
                    src `shouldSatisfyContain` needle

        it "host exports deterministic beneficiary and verifies disburse" $ do
            src <- mustRead hostMainPath
            forM_
                [ "CLI_SMOKE_BENEFICIARY_ADDR"
                , "devnetBeneficiaryAddress"
                , "runDisburseAssertionsIfPresent"
                , "disburse.assertions.request.json"
                , "beneficiaryReceiptLovelace"
                , "consumedMaterializedInput"
                , "reducedTreasuryOutput"
                ]
                $ \needle ->
                    src `shouldSatisfyContain` needle

    describe "build_sign_submit error propagation" $ do
        it
            "smoke.sh has no `local <var>=$(build_sign_submit` \
            \form (would swallow the function's exit code)"
            $ do
                src <- mustRead smokeScriptPath
                let buggy = "local "
                    needle = "=$(build_sign_submit"
                    -- A simple two-step scan: find each call site
                    -- and assert it is not preceded on the same line
                    -- by `local `.
                    offending =
                        [ line
                        | line <- lines src
                        , needle `isInfixOf` line
                        , buggy `isInfixOf` line
                        ]
                offending `shouldBe` []

        it
            "each `build_sign_submit` invocation is followed by an \
            \explicit `|| die ...`"
            $ do
                src <- mustRead smokeScriptPath
                let calls =
                        length
                            [ ()
                            | line <- lines src
                            , "build_sign_submit \\" `isInfixOf` line
                                || "build_sign_submit_multi \\"
                                    `isInfixOf` line
                            ]
                    diesOnFail =
                        length
                            [ ()
                            | line <- lines src
                            , "|| die" `isInfixOf` line
                            , "build/sign/submit failed" `isInfixOf` line
                            ]
                    timeoutDies =
                        length
                            [ ()
                            | line <- lines src
                            , "build/sign/submit failed before timeout"
                                `isInfixOf` line
                            ]
                diesOnFail + timeoutDies `shouldBe` calls

        it
            "witness commands inside build_sign_submit helpers pass \
            \--force for retry idempotency"
            $ do
                src <- mustRead smokeScriptPath
                let single =
                        sectionBetween
                            "build_sign_submit() {"
                            "# Variant for governance proposal"
                            src
                    multi =
                        sectionBetween
                            "build_sign_submit_multi() {"
                            "create_devnet_vault() {"
                            src
                    singleWitnesses = witnessCommandBlocks single
                    multiWitnesses = witnessCommandBlocks multi
                length singleWitnesses `shouldBe` 1
                length multiWitnesses `shouldBe` 1
                mapM_
                    (`shouldSatisfyContain` "--force \\")
                    (singleWitnesses <> multiWitnesses)

    describe "human-tutorial recording wrapper" $ do
        it "scripts/smoke/record-cli-devnet-smoke exists" $ do
            exists <- doesFileExist recordWrapperPath
            exists `shouldBe` True

        it "scripts/smoke/record-cli-devnet-smoke is executable" $ do
            exists <- doesFileExist recordWrapperPath
            unless exists $
                expectationFailure $
                    "missing: " <> recordWrapperPath
            perms <- getPermissions recordWrapperPath
            perms `shouldSatisfy` executable

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

    describe "reorganize CLI surface (#87)" $ do
        it "smoke.sh print_help mentions the reorganize phase" $ do
            src <- mustRead smokeScriptPath
            printHelpFnBody src `shouldSatisfyContain` "reorganize"

        it "smoke.sh main case has a reorganize) arm" $ do
            src <- mustRead smokeScriptPath
            let caseBlock = mainPhaseCaseBlock src
            caseBlock `shouldSatisfyContain` "reorganize)"

        it "reorganize) arm emits the MISSING_REORGANIZE_BUILDER diagnostic" $ do
            src <- mustRead smokeScriptPath
            let arm = reorganizeArm src
            arm `shouldSatisfyContain` "MISSING_REORGANIZE_BUILDER"

        it
            "reorganize) arm checks reorganize-wizard --help via $AMARU_EXE"
            $ do
                src <- mustRead smokeScriptPath
                let arm = reorganizeArm src
                arm `shouldSatisfyContain` "reorganize-wizard --help"

        it
            "MISSING_REORGANIZE_BUILDER fires before require_inside_devnet \
            \in the reorganize arm"
            $ do
                src <- mustRead smokeScriptPath
                let arm = reorganizeArm src
                case ( substringOffset "MISSING_REORGANIZE_BUILDER" arm
                     , substringOffset "require_inside_devnet" arm
                     ) of
                    (Just m, Just r) ->
                        unless (m < r) $
                            expectationFailure $
                                "expected MISSING_REORGANIZE_BUILDER offset ("
                                    <> show m
                                    <> ") to be strictly less than "
                                    <> "require_inside_devnet offset ("
                                    <> show r
                                    <> ") inside the reorganize) arm"
                    (Nothing, _) ->
                        expectationFailure $
                            "MISSING_REORGANIZE_BUILDER absent from "
                                <> "reorganize) arm"
                    (_, Nothing) ->
                        expectationFailure $
                            "require_inside_devnet absent from "
                                <> "reorganize) arm (S1 scaffold must "
                                <> "still chain through the host)"

        it
            "recognizedPhaseTokens contains reorganize and every token has \
            \a smoke.sh case arm"
            $ do
                "reorganize" `shouldSatisfy` (`elem` recognizedPhaseTokens)
                src <- mustRead smokeScriptPath
                let caseBlock = mainPhaseCaseBlock src
                forM_ recognizedPhaseTokens $ \token ->
                    caseBlock `shouldSatisfyContain` (token <> ")")

        it "host Main.hs recognizes the reorganize phase string" $ do
            src <- mustRead hostMainPath
            src `shouldSatisfyContain` "\"reorganize\""

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

sectionBetween :: String -> String -> String -> String
sectionBetween start end =
    unlines
        . takeWhile (not . (end `isInfixOf`))
        . dropWhile (not . (start `isInfixOf`))
        . lines

{- | Slice the body of the @print_help()@ shell function out of
@scripts/smoke/smoke.sh@. Returns every line between the opening
@print_help() {@ and the standalone closing @}@ line, including
the heredoc body — which is what holds the @--phase <name>@
documentation we want to assert on.
-}
printHelpFnBody :: String -> String
printHelpFnBody =
    unlines
        . takeWhile (/= "}")
        . drop 1
        . dropWhile (not . ("print_help() {" `isInfixOf`))
        . lines

{- | Slice the main @case "$phase"@ block out of
@scripts/smoke/smoke.sh@. There are two such case statements
in the file (one in @preflight_for_phase@, one in @main@); this
helper anchors on @main() {@ first so it returns the @main@
switch and not the preflight one.
-}
mainPhaseCaseBlock :: String -> String
mainPhaseCaseBlock src =
    let mainBody = sectionBetween "main() {" "main \"$@\"" src
    in  sectionBetween "case \"$phase\" in" "esac" mainBody

{- | Slice the @reorganize)@ arm out of the main @case "$phase"@
block in @scripts/smoke/smoke.sh@. Returns the text from the line
containing @reorganize)@ up to (but not including) the next line
containing @;;@.
-}
reorganizeArm :: String -> String
reorganizeArm src =
    sectionBetween "reorganize)" ";;" (mainPhaseCaseBlock src)

{- | Zero-based character offset of the first occurrence of
@needle@ in @haystack@, or @Nothing@ if absent.
-}
substringOffset :: String -> String -> Maybe Int
substringOffset needle = go 0
  where
    go _ [] = Nothing
    go i s
        | needle `isPrefixOf` s = Just i
        | otherwise = case s of
            (_ : cs) -> go (i + 1) cs
            [] -> Nothing

witnessCommandBlocks :: String -> [String]
witnessCommandBlocks = go . lines
  where
    go [] = []
    go (line : rest)
        | "\"$AMARU_EXE\" --network devnet witness \\"
            `isInfixOf` line =
            let (blockRest, afterBlock) =
                    break ("|| witness_status=$?" `isInfixOf`) rest
                block =
                    line : blockRest <> take 1 afterBlock
            in  unlines block : go (drop 1 afterBlock)
        | otherwise = go rest
