{- |
Module      : Main
Description : amaru-treasury-tx CLI entry point
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

The executable entry point is intentionally thin:
`Amaru.Treasury.Cli` owns parser assembly, command
modules own option records and runners, and `Main`
only dispatches.
-}
module Main (main) where

import Main.Utf8 (withUtf8)
import Options.Applicative (execParser)

import Amaru.Treasury.Cli
    ( Cmd (..)
    , opts
    )
import Amaru.Treasury.Cli.AttachWitness
    ( runAttachWitness
    )
import Amaru.Treasury.Cli.Common
    ( GlobalOpts (..)
    , withSocket
    )
import Amaru.Treasury.Cli.Devnet
    ( runDevnetRegistryInit
    )
import Amaru.Treasury.Cli.DisburseWizard
    ( runContingencyDisburse
    , runDisburseWizard
    )
import Amaru.Treasury.Cli.Envelope
    ( runDeEnvelope
    , runEnvelope
    )
import Amaru.Treasury.Cli.ReportRender
    ( runReportRender
    )
import Amaru.Treasury.Cli.Submit
    ( runSubmit
    )
import Amaru.Treasury.Cli.SwapCancel
    ( runSwapCancel
    )
import Amaru.Treasury.Cli.SwapQuote
    ( runSwapQuote
    )
import Amaru.Treasury.Cli.SwapWizard
    ( runWizard
    )
import Amaru.Treasury.Cli.TreasuryInspect
    ( runTreasuryInspect
    )
import Amaru.Treasury.Cli.TxBuild
    ( runTxBuild
    )
import Amaru.Treasury.Cli.UpdateCheck
    ( withUpdateCheckMain
    )
import Amaru.Treasury.Cli.Vault
    ( runVaultCreate
    )
import Amaru.Treasury.Cli.WithdrawWizard
    ( runWithdrawWizard
    )
import Amaru.Treasury.Cli.Witness
    ( runWitness
    )
import Amaru.Treasury.Tx.Envelope
    ( EnvelopeKind (..)
    )

main :: IO ()
main = withUtf8 . withUpdateCheckMain $ do
    (g, c) <- execParser opts
    case c of
        CmdReportRender ro ->
            runReportRender ro
        CmdSwapWizard wo ->
            withSocket g $ \socket ->
                runWizard g{goSocketPath = Just socket} wo
        CmdSwapQuote qo ->
            withSocket g $ \socket ->
                runSwapQuote g{goSocketPath = Just socket} qo
        CmdSwapCancel co ->
            withSocket g $ \socket ->
                runSwapCancel g{goSocketPath = Just socket} co
        CmdDevnetRegistryInit dio ->
            runDevnetRegistryInit g dio
        CmdDisburseWizard dwo ->
            withSocket g $ \socket ->
                runDisburseWizard g{goSocketPath = Just socket} dwo
        CmdContingencyDisburse eto ->
            withSocket g $ \socket ->
                runContingencyDisburse g{goSocketPath = Just socket} eto
        CmdWithdrawWizard wo ->
            withSocket g $ \socket ->
                runWithdrawWizard g{goSocketPath = Just socket} wo
        CmdTxBuild to ->
            withSocket g $ \socket ->
                runTxBuild socket to
        CmdTreasuryInspect io ->
            withSocket g $ \socket ->
                runTreasuryInspect g{goSocketPath = Just socket} io
        CmdAttachWitness ao ->
            runAttachWitness ao
        CmdVaultCreate vo ->
            runVaultCreate g vo
        CmdWitness wo ->
            runWitness g wo
        CmdSubmit so ->
            withSocket g $ \socket ->
                runSubmit (goNetworkMagic g) socket so
        CmdEnvelopeTx ->
            runEnvelope Tx
        CmdEnvelopeWitness ->
            runEnvelope Witness
        CmdEnvelopeSignedTx ->
            runEnvelope SignedTx
        CmdDeEnvelope ->
            runDeEnvelope
