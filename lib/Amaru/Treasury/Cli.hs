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
    , opts
    ) where

import Data.Version (showVersion)
import Options.Applicative
    ( Parser
    , ParserInfo
    , command
    , fullDesc
    , help
    , helper
    , hsubparser
    , info
    , infoOption
    , long
    , progDesc
    , short
    , (<**>)
    )

import Paths_amaru_treasury_tx (version)

import Amaru.Treasury.Cli.AttachWitness
    ( AttachWitnessOpts
    , attachWitnessOptsP
    )
import Amaru.Treasury.Cli.Common
    ( GlobalOpts
    , globalOptsP
    )
import Amaru.Treasury.Cli.DisburseWizard
    ( ContingencyDisburseOpts
    , DisburseWizardOpts
    , contingencyDisburseOptsP
    , disburseWizardOptsP
    )
import Amaru.Treasury.Cli.GovernanceWithdrawalInitWizard
    ( GovernanceWithdrawalInitWizardOpts
    , governanceWithdrawalInitWizardOptsP
    )
import Amaru.Treasury.Cli.RegistryInitWizard
    ( RegistryInitWizardOpts
    , registryInitWizardOptsP
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
    | CmdDisburseWizard DisburseWizardOpts
    | CmdContingencyDisburse ContingencyDisburseOpts
    | CmdWithdrawWizard WithdrawOpts
    | CmdRegistryInitWizard RegistryInitWizardOpts
    | CmdStakeRewardInitWizard StakeRewardInitWizardOpts
    | CmdGovernanceWithdrawalInitWizard GovernanceWithdrawalInitWizardOpts
    | CmdTxBuild TxBuildOpts
    | CmdReportRender ReportRenderOpts
    | CmdTreasuryInspect InspectOpts
    | CmdAttachWitness AttachWitnessOpts
    | CmdVaultCreate VaultCreateOpts
    | CmdWitness WitnessOpts
    | CmdSubmit SubmitOpts
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
                "disburse-wizard"
                ( info
                    (CmdDisburseWizard <$> disburseWizardOptsP)
                    ( progDesc
                        "Produce a disburse intent.json from registry and treasury UTxO state"
                    )
                )
            <> command
                "contingency-disburse-wizard"
                ( info
                    (CmdContingencyDisburse <$> contingencyDisburseOptsP)
                    ( progDesc
                        "Move ADA from the contingency treasury to another treasury scope"
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
                "treasury-inspect"
                ( info
                    (CmdTreasuryInspect <$> inspectOptsP)
                    ( progDesc
                        "Read-only report: treasury balances + pending SundaeSwap orders per scope"
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
        ( ((,) <$> globalOptsP <*> cmdP)
            <**> helper
            <**> versionOption
        )
        ( fullDesc
            <> progDesc
                "Build unsigned Amaru treasury transactions"
        )
