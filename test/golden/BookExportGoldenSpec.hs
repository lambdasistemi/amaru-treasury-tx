{- |
Module      : BookExportGoldenSpec
Description : Golden for the book-export overlay Turtle
License     : Apache-2.0

Renders the checked-in treasury metadata fixture through the pure
overlay-book emitter and pins the exported Turtle — the full book and a
single-scope (@--scope@) restriction.
-}
module BookExportGoldenSpec (spec) where

import Data.Text.IO qualified as TIO
import System.Directory (doesFileExist)
import System.Environment (lookupEnv)
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    )

import Amaru.Treasury.Book.Export (renderOverlayBook)
import Amaru.Treasury.Metadata (readMetadataFile)
import Amaru.Treasury.Scope (ScopeId (..))

data BookCase = BookCase
    { bcName :: !String
    , bcScope :: !(Maybe ScopeId)
    , bcGolden :: !FilePath
    }

fixtureMetadataPath :: FilePath
fixtureMetadataPath = "test/fixtures/metadata.json"

cases :: [BookCase]
cases =
    [ BookCase
        { bcName = "full book"
        , bcScope = Nothing
        , bcGolden = "test/fixtures/book-export/book.golden.ttl"
        }
    , BookCase
        { bcName = "single scope (core_development)"
        , bcScope = Just CoreDevelopment
        , bcGolden =
            "test/fixtures/book-export/book.core_development.golden.ttl"
        }
    ]

spec :: Spec
spec =
    describe "book-export overlay Turtle golden" $
        mapM_ caseSpec cases

caseSpec :: BookCase -> Spec
caseSpec bookCase =
    it ("pins the " <> bcName bookCase <> " Turtle") $ do
        metadata <- readMetadataFile fixtureMetadataPath
        let actual = renderOverlayBook (bcScope bookCase) metadata
        update <- lookupEnv "UPDATE_GOLDENS"
        if update == Just "1"
            then TIO.writeFile (bcGolden bookCase) actual
            else do
                exists <- doesFileExist (bcGolden bookCase)
                if exists
                    then do
                        expected <- TIO.readFile (bcGolden bookCase)
                        actual `shouldBe` expected
                    else
                        expectationFailure
                            ( "missing "
                                <> bcGolden bookCase
                                <> "; run UPDATE_GOLDENS=1 just golden"
                            )
