{- |
Module      : Amaru.Treasury.Cli.UpdateCheck
Description : Wiring for the github-release-check update banner
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Resolves the executable's update-check config (repo, version, opt-out
env var) and exposes 'withUpdateCheckMain' so @Main@ can wrap its
dispatch with one line. The library does the heavy lifting; this
module only carries the project-specific knobs.

Opt-out: @AMARU_TREASURY_TX_NO_UPDATE_CHECK=1@.
-}
module Amaru.Treasury.Cli.UpdateCheck
    ( withUpdateCheckMain
    ) where

import Data.Maybe (isJust)
import System.Environment (lookupEnv)

import GitHub.Release.Check
    ( RepoSlug (..)
    , cfgDisabled
    , defaultConfig
    , withUpdateCheck
    )

import Paths_amaru_treasury_tx (version)

{- | Wrap an 'IO' action with the @github-release-check@ banner.

The check fires after the action returns (success or exception),
hits @lambdasistemi\/amaru-treasury-tx@'s @releases\/latest@ at most
once per hour, and prints the banner to @stderr@ at most once per
hour. Setting @AMARU_TREASURY_TX_NO_UPDATE_CHECK@ in the environment
disables the whole thing.
-}
withUpdateCheckMain :: IO a -> IO a
withUpdateCheckMain action = do
    disabled <-
        isJust <$> lookupEnv "AMARU_TREASURY_TX_NO_UPDATE_CHECK"
    cfg <-
        defaultConfig
            (RepoSlug "lambdasistemi" "amaru-treasury-tx")
            "amaru-treasury-tx"
            version
    withUpdateCheck cfg{cfgDisabled = disabled} action
