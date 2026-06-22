{- |
Module      : Amaru.Treasury.Cli
Description : Top-level CLI parser assembly
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

This module owns the executable's parser tree. Command
modules own their option records, subcommand parsers,
and runners.
-}
module Amaru.Treasury.Cli
    ( Cmd (..)
    , execCliParser
    , opts
    , parseCliArgs
    , parseCliArgsWithEnv
    ) where

import Data.Bifunctor (first)
import Data.List (isInfixOf)
import Data.Version (showVersion)
import Options.Applicative
    ( Parser
    , ParserFailure (..)
    , ParserInfo
    , ParserResult (..)
    , command
    , defaultPrefs
    , execParserPure
    , fullDesc
    , handleParseResult
    , help
    , helper
    , hsubparser
    , info
    , infoOption
    , long
    , progDesc
    , renderFailure
    , short
    , (<**>)
    )
import Options.Applicative.Help.Types (ParserHelp)
import System.Environment
    ( getArgs
    , getEnvironment
    )
import System.Exit (ExitCode (..))
import System.Exit qualified as Exit

import Paths_amaru_treasury_tx (version)

import Amaru.Treasury.Cli.AttachWitness
    ( AttachWitnessOpts
    , attachWitnessOptsP
    )
import Amaru.Treasury.Cli.Common
    ( GlobalConfigOpts
    , GlobalOpts
    , globalConfigOptsP
    , globalConfigToGlobalOpts
    )
import Amaru.Treasury.Cli.Config
    ( CliConfigError
    , renderCliConfigError
    , resolveGlobalConfig
    , resolveTreasuryInspectConfig
    )
import Amaru.Treasury.Cli.DisburseWizard
    ( DisburseWizardInput
    , disburseWizardInputP
    )
import Amaru.Treasury.Cli.GovernanceWithdrawalInitWizard
    ( GovernanceWithdrawalInitWizardOpts
    , governanceWithdrawalInitWizardOptsP
    )
import Amaru.Treasury.Cli.History
    ( HistoryOpts
    , TxDetailOpts
    , historyOptsP
    , txDetailOptsP
    )
import Amaru.Treasury.Cli.RegistryInitWizard
    ( RegistryInitWizardOpts
    , registryInitWizardOptsP
    )
import Amaru.Treasury.Cli.ReorganizeWizard
    ( ReorganizeWizardOpts
    , reorganizeWizardOptsP
    )
import Amaru.Treasury.Cli.Serve
    ( ServeOpts
    , serveOptsP
    )
import Amaru.Treasury.Cli.StakeRewardInitWizard
    ( StakeRewardInitWizardOpts
    , stakeRewardInitWizardOptsP
    )
import Amaru.Treasury.Cli.Submit
    ( SubmitOpts
    , submitOptsP
    )
import Amaru.Treasury.Cli.SwapCancel
    ( SwapCancelOpts
    , swapCancelOptsP
    )
import Amaru.Treasury.Cli.SwapQuote
    ( SwapQuoteOpts
    , swapQuoteOptsP
    )
import Amaru.Treasury.Cli.SwapRerate
    ( SwapRerateOpts
    , swapRerateOptsP
    )
import Amaru.Treasury.Cli.SwapWizard
    ( WizardOpts
    , wizardOptsP
    )
import Amaru.Treasury.Cli.TreasuryInspect
    ( InspectOpts
    , inspectOptsP
    )
import Amaru.Treasury.Cli.TxBuild
    ( TxBuildOpts
    , txBuildOptsP
    )
import Amaru.Treasury.Cli.Vault
    ( VaultCreateOpts
    , vaultCreateOptsP
    )
import Amaru.Treasury.Cli.WithdrawWizard
    ( WithdrawOpts
    , withdrawOptsP
    )
import Amaru.Treasury.Cli.Witness
    ( WitnessOpts
    , witnessOptsP
    )
import Amaru.Treasury.Report.Cli
    ( ReportRenderOpts
    , reportRenderOptsP
    )

data Cmd
    = CmdSwapWizard WizardOpts
    | CmdSwapQuote SwapQuoteOpts
    | CmdSwapCancel SwapCancelOpts
    | CmdSwapRerate SwapRerateOpts
    | CmdDisburseWizard DisburseWizardInput
    | CmdWithdrawWizard WithdrawOpts
    | CmdRegistryInitWizard RegistryInitWizardOpts
    | CmdStakeRewardInitWizard StakeRewardInitWizardOpts
    | CmdGovernanceWithdrawalInitWizard GovernanceWithdrawalInitWizardOpts
    | CmdReorganizeWizard ReorganizeWizardOpts
    | CmdTxBuild TxBuildOpts
    | CmdReportRender ReportRenderOpts
    | CmdTreasuryInspect InspectOpts
    | CmdHistory HistoryOpts
    | CmdTxDetail TxDetailOpts
    | CmdAttachWitness AttachWitnessOpts
    | CmdVaultCreate VaultCreateOpts
    | CmdWitness WitnessOpts
    | CmdSubmit SubmitOpts
    | CmdServe ServeOpts
    | CmdEnvelopeTx
    | CmdEnvelopeWitness
    | CmdEnvelopeSignedTx
    | CmdDeEnvelope

cmdP :: Parser Cmd
cmdP =
    hsubparser
        ( command
            "tx-build"
            ( info
                (CmdTxBuild <$> txBuildOptsP)
                ( progDesc
                    "Build any treasury transaction from a unified intent.json"
                )
            )
            <> command
                "report-render"
                ( info
                    (CmdReportRender <$> reportRenderOptsP)
                    ( progDesc
                        "Render a tx-build report envelope as Markdown"
                    )
                )
            <> command
                "swap-wizard"
                ( info
                    (CmdSwapWizard <$> wizardOptsP)
                    ( progDesc
                        "Produce a swap intent.json from a typed questionnaire"
                    )
                )
            <> command
                "swap-quote"
                ( info
                    (CmdSwapQuote <$> swapQuoteOptsP)
                    ( progDesc
                        "Prepare a quote-derived swap run"
                    )
                )
            <> command
                "swap-cancel"
                ( info
                    (CmdSwapCancel <$> swapCancelOptsP)
                    ( progDesc
                        "Build an unsigned transaction that cancels one pending SundaeSwap order"
                    )
                )
            <> command
                "swap-rerate"
                ( info
                    (CmdSwapRerate <$> swapRerateOptsP)
                    ( progDesc
                        "Build an unsigned transaction that re-rates selected pending SundaeSwap orders"
                    )
                )
            <> command
                "disburse-wizard"
                ( info
                    (CmdDisburseWizard <$> disburseWizardInputP)
                    ( progDesc
                        "Produce a disburse intent.json from registry and treasury UTxO state (--scope contingency --to <scope>:<ada> for contingency disburse)"
                    )
                )
            <> command
                "withdraw-wizard"
                ( info
                    (CmdWithdrawWizard <$> withdrawOptsP)
                    ( progDesc
                        "Produce a withdraw intent.json from registry and reward state"
                    )
                )
            <> command
                "registry-init-wizard"
                ( info
                    (CmdRegistryInitWizard <$> registryInitWizardOptsP)
                    ( progDesc
                        "Produce registry-init intent.json files for seed-split | mint | reference-scripts (devnet only; Slice 1 stubs the live path)"
                    )
                )
            <> command
                "stake-reward-init-wizard"
                ( info
                    (CmdStakeRewardInitWizard <$> stakeRewardInitWizardOptsP)
                    ( progDesc
                        "Produce stake-reward-init intent.json files for script-account | plain-account (devnet only; Slice 1 stubs the live path)"
                    )
                )
            <> command
                "governance-withdrawal-init-wizard"
                ( info
                    ( CmdGovernanceWithdrawalInitWizard
                        <$> governanceWithdrawalInitWizardOptsP
                    )
                    ( progDesc
                        "Produce governance-withdrawal-init intent.json files for proposal | materialization (devnet only; Slice 1 stubs the live path)"
                    )
                )
            <> command
                "reorganize-wizard"
                ( info
                    (CmdReorganizeWizard <$> reorganizeWizardOptsP)
                    ( progDesc
                        "Produce a reorganize intent.json from registry and treasury UTxO state (devnet only; Slice 1 stubs the live path)"
                    )
                )
            <> command
                "treasury-inspect"
                ( info
                    (CmdTreasuryInspect <$> inspectOptsP)
                    ( progDesc
                        "Read-only report: treasury balances + pending SundaeSwap orders per scope"
                    )
                )
            <> command
                "history"
                ( info
                    (CmdHistory <$> historyOptsP)
                    ( progDesc
                        "Read-only: print treasury tx history for a scope from the local indexer"
                    )
                )
            <> command
                "tx-detail"
                ( info
                    (CmdTxDetail <$> txDetailOptsP)
                    ( progDesc
                        "Read-only: print one decoded treasury transaction from the local indexer"
                    )
                )
            <> command
                "attach-witness"
                ( info
                    (CmdAttachWitness <$> attachWitnessOptsP)
                    ( progDesc
                        "Merge detached vkey witnesses into an unsigned Conway tx CBOR hex"
                    )
                )
            <> command
                "vault"
                ( info
                    vaultCmdP
                    ( progDesc
                        "Manage encrypted witness vaults"
                    )
                )
            <> command
                "witness"
                ( info
                    (CmdWitness <$> witnessOptsP)
                    ( progDesc
                        "Create a detached Conway vkey witness from an encrypted vault identity"
                    )
                )
            <> command
                "submit"
                ( info
                    (CmdSubmit <$> submitOptsP)
                    ( progDesc
                        "Submit a signed Conway tx CBOR hex via the local node socket"
                    )
                )
            <> command
                "serve"
                ( info
                    (CmdServe <$> serveOptsP)
                    ( progDesc
                        "Run the HTTP API service (delegates to amaru-treasury-tx-api)"
                    )
                )
            <> command
                "envelope-tx"
                ( info
                    (pure CmdEnvelopeTx)
                    ( progDesc
                        "Wrap raw tx CBOR hex as a cardano-cli Conway tx envelope"
                    )
                )
            <> command
                "envelope-witness"
                ( info
                    (pure CmdEnvelopeWitness)
                    ( progDesc
                        "Wrap raw witness CBOR hex as a cardano-cli Conway witness envelope"
                    )
                )
            <> command
                "envelope-signed-tx"
                ( info
                    (pure CmdEnvelopeSignedTx)
                    ( progDesc
                        "Wrap raw signed tx CBOR hex as a cardano-cli Conway tx envelope"
                    )
                )
            <> command
                "de-envelope"
                ( info
                    (pure CmdDeEnvelope)
                    ( progDesc
                        "Extract raw CBOR hex from a cardano-cli Conway envelope"
                    )
                )
        )

vaultCmdP :: Parser Cmd
vaultCmdP =
    hsubparser
        ( command
            "create"
            ( info
                (CmdVaultCreate <$> vaultCreateOptsP)
                ( progDesc
                    "Create an age-encrypted witness vault from a signing key"
                )
            )
        )

versionOption :: Parser (a -> a)
versionOption =
    infoOption
        ("amaru-treasury-tx " <> showVersion version)
        ( long "version"
            <> short 'V'
            <> help "Show version and exit"
        )

opts :: ParserInfo (GlobalOpts, Cmd)
opts =
    info
        ( ( (,) . globalConfigToGlobalOpts
                <$> globalConfigOptsP
                <*> cmdP
          )
            <**> helper
            <**> versionOption
        )
        ( fullDesc
            <> progDesc
                "Build unsigned Amaru treasury transactions"
        )

optsWithConfig :: ParserInfo (GlobalConfigOpts, Cmd)
optsWithConfig =
    info
        ( ((,) <$> globalConfigOptsP <*> cmdP)
            <**> helper
            <**> versionOption
        )
        ( fullDesc
            <> progDesc
                "Build unsigned Amaru treasury transactions"
        )

execCliParser :: IO (GlobalOpts, Cmd)
execCliParser = do
    args <- getArgs
    raw <- handleParseResult (parseCliConfigArgs args)
    envs <- getEnvironment
    resolved <- resolveCliCommand envs raw
    case resolved of
        Right parsed -> pure parsed
        Left err ->
            Exit.die ("amaru-treasury-tx: " <> renderCliConfigError err)

parseCliArgs :: [String] -> ParserResult (GlobalOpts, Cmd)
parseCliArgs args =
    adjustDisburseReferenceFailure args $
        execParserPure defaultPrefs opts args

parseCliConfigArgs :: [String] -> ParserResult (GlobalConfigOpts, Cmd)
parseCliConfigArgs args =
    adjustDisburseReferenceFailure args $
        execParserPure defaultPrefs optsWithConfig args

parseCliArgsWithEnv
    :: [(String, String)]
    -> [String]
    -> IO (Either String (GlobalOpts, Cmd))
parseCliArgsWithEnv envs args =
    case parseCliConfigArgs args of
        Success raw ->
            first renderCliConfigError <$> resolveCliCommand envs raw
        Failure failure ->
            let (body, _) = renderFailure failure "amaru-treasury-tx"
            in  pure (Left body)
        CompletionInvoked{} -> pure (Left "completion invoked")

resolveCliCommand
    :: [(String, String)]
    -> (GlobalConfigOpts, Cmd)
    -> IO (Either CliConfigError (GlobalOpts, Cmd))
resolveCliCommand envs (globals, cmd) =
    case cmd of
        CmdTreasuryInspect inspect -> do
            resolved <- resolveTreasuryInspectConfig envs globals inspect
            pure $ fmap (fmap CmdTreasuryInspect) resolved
        _ -> do
            resolved <- resolveGlobalConfig envs globals
            pure $ fmap (pairWithCmd cmd) resolved

pairWithCmd :: Cmd -> GlobalOpts -> (GlobalOpts, Cmd)
pairWithCmd cmd globalOpts = (globalOpts, cmd)

adjustDisburseReferenceFailure
    :: [String]
    -> ParserResult a
    -> ParserResult a
adjustDisburseReferenceFailure args (Failure failure)
    | "disburse-wizard" `elem` args
    , isDisburseReferenceGrammarFailure failure =
        Failure (withFailureExit (ExitFailure 2) failure)
adjustDisburseReferenceFailure _ result = result

isDisburseReferenceGrammarFailure
    :: ParserFailure ParserHelp -> Bool
isDisburseReferenceGrammarFailure failure =
    any
        (`isInfixOf` body)
        [ "--reference-label requires a preceding --reference-uri"
        , "--reference-type requires a preceding --reference-uri"
        ]
  where
    (body, _) = renderFailure failure "amaru-treasury-tx"

withFailureExit
    :: ExitCode -> ParserFailure h -> ParserFailure h
withFailureExit exitCode failure =
    ParserFailure $ \programName ->
        let (body, _oldExitCode, columns) = execFailure failure programName
        in  (body, exitCode, columns)
