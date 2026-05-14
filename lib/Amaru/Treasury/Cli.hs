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

import Options.Applicative
    ( Parser
    , ParserInfo
    , command
    , fullDesc
    , helper
    , hsubparser
    , info
    , progDesc
    , (<**>)
    )

import Amaru.Treasury.Cli.AttachWitness
    ( AttachWitnessOpts
    , attachWitnessOptsP
    )
import Amaru.Treasury.Cli.Common
    ( GlobalOpts
    , globalOptsP
    )
import Amaru.Treasury.Cli.DisburseWizard
    ( DisburseWizardOpts
    , disburseWizardOptsP
    )
import Amaru.Treasury.Cli.Submit
    ( SubmitOpts
    , submitOptsP
    )
import Amaru.Treasury.Cli.SwapQuote
    ( SwapQuoteOpts
    , swapQuoteOptsP
    )
import Amaru.Treasury.Cli.SwapWizard
    ( WizardOpts
    , wizardOptsP
    )
import Amaru.Treasury.Cli.TxBuild
    ( TxBuildOpts
    , txBuildOptsP
    )
import Amaru.Treasury.Cli.WithdrawWizard
    ( WithdrawOpts
    , withdrawOptsP
    )
import Amaru.Treasury.Report.Cli
    ( ReportRenderOpts
    , reportRenderOptsP
    )

data Cmd
    = CmdSwapWizard WizardOpts
    | CmdSwapQuote SwapQuoteOpts
    | CmdDisburseWizard DisburseWizardOpts
    | CmdWithdrawWizard WithdrawOpts
    | CmdTxBuild TxBuildOpts
    | CmdReportRender ReportRenderOpts
    | CmdAttachWitness AttachWitnessOpts
    | CmdSubmit SubmitOpts
    | CmdEnvelopeTx
    | CmdEnvelopeWitness
    | CmdEnvelopeSignedTx

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
                "disburse-wizard"
                ( info
                    (CmdDisburseWizard <$> disburseWizardOptsP)
                    ( progDesc
                        "Produce a disburse intent.json from registry and treasury UTxO state"
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
                "attach-witness"
                ( info
                    (CmdAttachWitness <$> attachWitnessOptsP)
                    ( progDesc
                        "Merge detached vkey witnesses into an unsigned Conway tx CBOR hex"
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
        )

opts :: ParserInfo (GlobalOpts, Cmd)
opts =
    info
        ( ((,) <$> globalOptsP <*> cmdP)
            <**> helper
        )
        ( fullDesc
            <> progDesc
                "Build unsigned Amaru treasury transactions"
        )
