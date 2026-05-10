{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Report.Cli
Description : report-render CLI options
License     : Apache-2.0

Parser and decode helpers for the @report-render@ subcommand.
-}
module Amaru.Treasury.Report.Cli
    ( ReportRenderOpts (..)
    , decodeReportRenderInput
    , renderReportRenderOutput
    , reportRenderOptsP
    ) where

import Data.Aeson
    ( eitherDecodeStrict'
    )
import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Text qualified as T
import Options.Applicative
    ( Parser
    , help
    , long
    , metavar
    , optional
    , strOption
    )

import Amaru.Treasury.Metadata
    ( TreasuryMetadata
    )
import Amaru.Treasury.Report
    ( BuildFailure (..)
    , TxBuildOutput
    )
import Amaru.Treasury.Report.Render
    ( RenderError (..)
    , RenderOutput (..)
    , renderBuildOutputWithMetadata
    )

data ReportRenderOpts = ReportRenderOpts
    { rrInPath :: !(Maybe FilePath)
    , rrOutPath :: !(Maybe FilePath)
    , rrMetadataPath :: !(Maybe FilePath)
    }
    deriving stock (Eq, Show)

reportRenderOptsP :: Parser ReportRenderOpts
reportRenderOptsP =
    ReportRenderOpts
        <$> optionalStdioPath
            "in"
            "PATH"
            "Read the JSON build-output envelope here (defaults to stdin)"
        <*> optionalStdioPath
            "out"
            "PATH"
            "Write Markdown here (defaults to stdout)"
        <*> optional
            ( strOption
                ( long "metadata"
                    <> metavar "PATH"
                    <> help
                        "Treasury metadata source for identity resolution"
                )
            )

optionalStdioPath
    :: String -> String -> String -> Parser (Maybe FilePath)
optionalStdioPath flag meta description =
    normaliseStdioPath
        <$> optional
            ( strOption
                ( long flag
                    <> metavar meta
                    <> help description
                )
            )

normaliseStdioPath :: Maybe FilePath -> Maybe FilePath
normaliseStdioPath = \case
    Just "-" -> Nothing
    other -> other

decodeReportRenderInput :: ByteString -> Either Text TxBuildOutput
decodeReportRenderInput =
    firstText
        . eitherDecodeStrict'
  where
    firstText =
        either
            ( Left
                . ("report-render: invalid build-output envelope: " <>)
                . T.pack
            )
            Right

renderReportRenderOutput
    :: Maybe TreasuryMetadata -> TxBuildOutput -> Either Text Text
renderReportRenderOutput metadata output =
    case renderBuildOutputWithMetadata metadata output of
        Right (RenderOutput rendered) -> Right rendered
        Left (RenderBuildFailure failure) ->
            Left
                ( "report-render: tx-build failed: "
                    <> bfCode failure
                    <> ": "
                    <> bfMessage failure
                )
