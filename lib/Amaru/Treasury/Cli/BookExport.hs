{-# LANGUAGE RecordWildCards #-}

{- |
Module      : Amaru.Treasury.Cli.BookExport
Description : Options and runner for the book-export subcommand
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Options, parser, and runner for @book-export@: read the treasury
journal metadata, render the cardano-swiss-knife overlay book
('Amaru.Treasury.Book.Export.renderOverlayBook'), and write it to
@--out@ (defaults to stdout). Offline — no node socket, mirroring
@report-render@.
-}
module Amaru.Treasury.Cli.BookExport
    ( BookExportOpts (..)
    , bookExportOptsP
    , runBookExport
    ) where

import Control.Exception
    ( IOException
    , SomeException
    , displayException
    , try
    )
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Options.Applicative
    ( Parser
    , eitherReader
    , help
    , long
    , metavar
    , option
    , optional
    , strOption
    )
import System.Exit (ExitCode (..), exitWith)
import System.IO (stderr)

import Amaru.Treasury.Book.Export (renderOverlayBook)
import Amaru.Treasury.Metadata
    ( TreasuryMetadata
    , readMetadataFile
    )
import Amaru.Treasury.Scope
    ( ScopeId
    , scopeFromText
    )

-- | Parsed @book-export@ options.
data BookExportOpts = BookExportOpts
    { beMetadataPath :: !FilePath
    -- ^ Treasury journal metadata source (@--metadata@).
    , beOutPath :: !(Maybe FilePath)
    -- ^ Turtle output path; 'Nothing' (or @-@) writes to stdout.
    , beScope :: !(Maybe ScopeId)
    -- ^ Restrict the book to a single scope (@--scope@).
    }
    deriving stock (Eq, Show)

-- | @book-export@ option parser.
bookExportOptsP :: Parser BookExportOpts
bookExportOptsP =
    BookExportOpts
        <$> strOption
            ( long "metadata"
                <> metavar "PATH"
                <> help "Treasury journal metadata to export"
            )
        <*> ( normaliseStdioPath
                <$> optional
                    ( strOption
                        ( long "out"
                            <> metavar "PATH"
                            <> help
                                "Write the overlay Turtle here (defaults to stdout)"
                        )
                    )
            )
        <*> optional
            ( option
                (eitherReader (scopeFromText . T.pack))
                ( long "scope"
                    <> metavar "NAME"
                    <> help "Restrict the book to one scope"
                )
            )

normaliseStdioPath :: Maybe FilePath -> Maybe FilePath
normaliseStdioPath = \case
    Just "-" -> Nothing
    other -> other

-- | Read the metadata, render the overlay book, and write it out.
runBookExport :: BookExportOpts -> IO ()
runBookExport BookExportOpts{..} = do
    metadata <- loadMetadata beMetadataPath
    writeBook beOutPath (renderOverlayBook beScope metadata)

loadMetadata :: FilePath -> IO TreasuryMetadata
loadMetadata path = do
    result <-
        try (readMetadataFile path)
            :: IO (Either SomeException TreasuryMetadata)
    case result of
        Right metadata -> pure metadata
        Left err -> do
            TIO.hPutStrLn
                stderr
                ( "book-export: metadata read failed "
                    <> T.pack path
                    <> ": "
                    <> T.pack (displayException err)
                )
            exitWith (ExitFailure 3)

writeBook :: Maybe FilePath -> T.Text -> IO ()
writeBook Nothing turtle = TIO.putStr turtle
writeBook (Just path) turtle = do
    result <-
        try (TIO.writeFile path turtle) :: IO (Either IOException ())
    case result of
        Right () -> pure ()
        Left err -> do
            TIO.hPutStrLn
                stderr
                ( "book-export: output write failed "
                    <> T.pack path
                    <> ": "
                    <> T.pack (displayException err)
                )
            exitWith (ExitFailure 4)
