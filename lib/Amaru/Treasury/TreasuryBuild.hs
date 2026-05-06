{- |
Module      : Amaru.Treasury.TreasuryBuild
Description : Unified IO build pipeline (skeleton)
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Placeholder skeleton for feature 005 phase 4 (T021).
'runBuild', 'runFromIntent', and the per-action runners
('runSwap', 'runDisburse', 'runWithdraw',
'runReorganize') land in T021 — the swap runner with the
existing 'Amaru.Treasury.Tx.SwapBuild.runSwapBuild' body
verbatim, the others as 'throwIO . userError' stubs
until features 004/005/006 ship.
-}
module Amaru.Treasury.TreasuryBuild
    (
    ) where
