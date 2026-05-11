{-# LANGUAGE RecordWildCards #-}

{- |
Module      : Amaru.Treasury.Cli.ReportRender
Description : Runner for the report-render subcommand
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0
-}
module Amaru.Treasury.Cli.ReportRender
    ( runReportRender
    ) where

import Control.Exception
    ( IOException
    , SomeException
    , displayException
    , try
    )
import Data.ByteString qualified as BS
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory (doesFileExist)
import System.Exit (ExitCode (..), exitWith)
import System.IO (stderr)
import System.IO qualified as IO

import Amaru.Treasury.Metadata
    ( TreasuryMetadata
    , readMetadataFile
    )
import Amaru.Treasury.Report.Cli
    ( ReportRenderOpts (..)
    , decodeReportRenderInput
    , renderReportRenderOutput
    )

runReportRender :: ReportRenderOpts -> IO ()
runReportRender ReportRenderOpts{..} = do
    metadata <- loadReportRenderMetadata rrMetadataPath
    bytes <- case rrInPath of
        Nothing -> BS.hGetContents IO.stdin
        Just path -> BS.readFile path
    output <- case decodeReportRenderInput bytes of
        Left err -> do
            TIO.hPutStrLn stderr err
            exitWith (ExitFailure 3)
        Right decoded -> pure decoded
    rendered <- case renderReportRenderOutput metadata output of
        Left err -> do
            TIO.hPutStrLn stderr err
            exitWith (ExitFailure 5)
        Right text -> pure text
    writeRenderedReport rrOutPath rendered

loadReportRenderMetadata
    :: Maybe FilePath -> IO (Maybe TreasuryMetadata)
loadReportRenderMetadata requestedPath = do
    metadataPath <- case requestedPath of
        Just path -> pure (Just path)
        Nothing -> do
            exists <- doesFileExist defaultReportRenderMetadataPath
            pure $
                if exists
                    then Just defaultReportRenderMetadataPath
                    else Nothing
    case metadataPath of
        Nothing -> pure Nothing
        Just path -> do
            result <-
                try (readMetadataFile path)
                    :: IO (Either SomeException TreasuryMetadata)
            case result of
                Right metadata -> pure (Just metadata)
                Left err -> do
                    TIO.hPutStrLn
                        stderr
                        ( "report-render: metadata read failed "
                            <> T.pack path
                            <> ": "
                            <> T.pack (displayException err)
                        )
                    exitWith (ExitFailure 3)

defaultReportRenderMetadataPath :: FilePath
defaultReportRenderMetadataPath = "journal/2026/metadata.json"

writeRenderedReport :: Maybe FilePath -> T.Text -> IO ()
writeRenderedReport Nothing text =
    TIO.putStr text
writeRenderedReport (Just path) text = do
    result <- try (TIO.writeFile path text) :: IO (Either IOException ())
    case result of
        Right () -> pure ()
        Left err -> do
            TIO.hPutStrLn
                stderr
                ( "report-render: output write failed "
                    <> T.pack path
                    <> ": "
                    <> T.pack (displayException err)
                )
            exitWith (ExitFailure 4)
