{- |
Module      : Amaru.Treasury.Cli.Serve
Description : Thin @serve@ compatibility subcommand
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

The API implementation lives in the standalone
@amaru-treasury-tx-api@ executable. This module keeps the operator
command recovered in #248 available as @amaru-treasury-tx serve
--config service.yaml@ by delegating to that executable.
-}
module Amaru.Treasury.Cli.Serve
    ( ServeOpts (..)
    , serveOptsP
    , runServe
    ) where

import Options.Applicative
    ( Parser
    , help
    , long
    , metavar
    , optional
    , strOption
    )
import System.Process (callProcess)

-- | Options for the @serve@ compatibility command.
newtype ServeOpts = ServeOpts
    { soConfig :: Maybe FilePath
    -- ^ Treasury service YAML config passed through to
    --   @amaru-treasury-tx-api --config@.
    }
    deriving stock (Eq, Show)

-- | Parse @serve --config service.yaml@.
serveOptsP :: Parser ServeOpts
serveOptsP =
    ServeOpts
        <$> optional
            ( strOption
                ( long "config"
                    <> metavar "PATH"
                    <> help "Path to treasury service YAML config"
                )
            )

-- | Run the standalone API executable with the parsed serve options.
runServe :: ServeOpts -> IO ()
runServe opts =
    callProcess "amaru-treasury-tx-api" $
        case soConfig opts of
            Nothing -> []
            Just path -> ["--config", path]
