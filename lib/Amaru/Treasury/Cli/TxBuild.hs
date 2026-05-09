{-# LANGUAGE OverloadedStrings #-}

module Amaru.Treasury.Cli.TxBuild
    ( TxBuildOpts (..)
    , txBuildOptsP
    ) where

import Options.Applicative
    ( Parser
    , help
    , long
    , metavar
    , optional
    , short
    , strOption
    )

{- | Flags for the unified @tx-build@ subcommand. The
network is read from the intent's @network@ field, not
from any CLI flag — the intent is the single source of
truth.
-}
data TxBuildOpts = TxBuildOpts
    { tboIntentPath :: !(Maybe FilePath)
    -- ^ 'Nothing' = read intent.json from stdin
    , tboOutPath :: !(Maybe FilePath)
    -- ^ 'Nothing' = stdout
    , tboLog :: !(Maybe FilePath)
    -- ^ 'Nothing' = stderr
    , tboReportPath :: !(Maybe FilePath)
    -- ^ 'Nothing' = do not write a transaction report
    }
    deriving stock (Eq, Show)

txBuildOptsP :: Parser TxBuildOpts
txBuildOptsP =
    TxBuildOpts
        <$> optional
            ( strOption
                ( long "intent"
                    <> short 'i'
                    <> metavar "PATH"
                    <> help
                        "Path to the unified intent.json (defaults to stdin)"
                )
            )
        <*> optional
            ( strOption
                ( long "out"
                    <> short 'o'
                    <> metavar "PATH"
                    <> help "Write hex CBOR here (defaults to stdout)"
                )
            )
        <*> optional
            ( strOption
                ( long "log"
                    <> metavar "PATH"
                    <> help
                        "Where to write step-by-step trace lines (defaults to stderr)"
                )
            )
        <*> optional
            ( strOption
                ( long "report"
                    <> metavar "PATH"
                    <> help
                        "Write a deterministic JSON transaction report after successful validation"
                )
            )
