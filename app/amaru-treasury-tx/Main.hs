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

import Options.Applicative (execParser)

import Amaru.Treasury.Cli
    ( Cmd (..)
    , opts
    )
import Amaru.Treasury.Cli.Common
    ( GlobalOpts (..)
    , withSocket
    )
import Amaru.Treasury.Cli.DisburseWizard
    ( runDisburseWizard
    )
import Amaru.Treasury.Cli.ReportRender
    ( runReportRender
    )
import Amaru.Treasury.Cli.SwapQuote
    ( runSwapQuote
    )
import Amaru.Treasury.Cli.SwapWizard
    ( runWizard
    )
import Amaru.Treasury.Cli.TxBuild
    ( runTxBuild
    )
import Amaru.Treasury.Cli.WithdrawWizard
    ( runWithdrawWizard
    )

main :: IO ()
main = do
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
        CmdDisburseWizard dwo ->
            withSocket g $ \socket ->
                runDisburseWizard g{goSocketPath = Just socket} dwo
        CmdWithdrawWizard wo ->
            withSocket g $ \socket ->
                runWithdrawWizard g{goSocketPath = Just socket} wo
        CmdTxBuild to ->
            withSocket g $ \socket ->
                runTxBuild socket to
