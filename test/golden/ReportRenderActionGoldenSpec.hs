{- |
Module      : ReportRenderActionGoldenSpec
Description : Markdown goldens for non-swap report-render outputs
License     : Apache-2.0

Rebuilds every @report.golden.json@ found under @test/fixtures@ with
the real writer and compares it byte-for-byte with the checked-in
file; a report golden without a regenerating writer fails. Then
renders the checked-in disburse and withdraw build-output envelopes
through the pure Markdown renderer and compares them with checked-in
operator-facing reports.

Set @UPDATE_GOLDENS=1@ to rewrite the report goldens from the writer.
-}
module ReportRenderActionGoldenSpec (spec) where

import Control.Monad (filterM, forM_, when)
import Data.Aeson
    ( eitherDecodeStrict'
    )
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.ByteString.Lazy.Char8 qualified as BSL8
import Data.Char (isDigit)
import Data.List (isSuffixOf, sort, uncons)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory
    ( doesDirectoryExist
    , doesFileExist
    , listDirectory
    )
import System.Environment (lookupEnv)
import Test.Hspec
    ( Expectation
    , Spec
    , describe
    , expectationFailure
    , it
    , runIO
    , shouldBe
    )

import SwapGoldenSpec qualified as Swap
import TreasuryInspectGoldenSpec qualified as Inspect

import Amaru.Treasury.Build
    ( BuildResult (..)
    , runFromIntent
    )
import Amaru.Treasury.ChainContext.Fixture
    ( readSwapFixture
    , toFrozenContext
    )
import Amaru.Treasury.IntentJSON
    ( ScopeJSON (..)
    , SomeTreasuryIntent (..)
    , TreasuryIntent (..)
    , decodeTreasuryIntentFile
    )
import Amaru.Treasury.Report
    ( ReportContext (..)
    , TxBuildOutput (..)
    , TxBuildOutputResult (..)
    , TxBuildSuccess (..)
    , buildTransactionReport
    , encodeBuildOutput
    , txCborHexFromBytes
    )
import Amaru.Treasury.Report.Render
    ( RenderOutput (..)
    , renderBuildOutput
    )

data RenderFixture = RenderFixture
    { rfName :: !String
    , rfBuildDir :: !FilePath
    , rfReportDir :: !FilePath
    }

fixtures :: [RenderFixture]
fixtures =
    [ RenderFixture
        { rfName = "disburse"
        , rfBuildDir = "test/fixtures/disburse/ada"
        , rfReportDir = "test/fixtures/disburse"
        }
    , RenderFixture
        { rfName = "withdraw"
        , rfBuildDir = "test/fixtures/withdraw/synthetic"
        , rfReportDir = "test/fixtures/withdraw"
        }
    ]

spec :: Spec
spec = do
    reportGoldenSpec
    describe "report-render action Markdown goldens" $
        mapM_ fixtureSpec fixtures

fixturesRoot :: FilePath
fixturesRoot = "test/fixtures"

-- | Each report golden paired with the writer that regenerates it.
reportGoldenWriters :: [(FilePath, IO BSL.ByteString)]
reportGoldenWriters =
    [ (inputPath fixture, encodeBuildOutput <$> regenerate fixture)
    | fixture <- fixtures
    ]
        <> [ (Swap.reportGoldenPath, Swap.regenerateReportGolden)
           , (Inspect.goldenPath, Inspect.regenerateReportGolden)
           ]
  where
    regenerate fixture =
        readIntent (rfBuildDir fixture)
            >>= buildOutput (rfBuildDir fixture)

reportGoldenSpec :: Spec
reportGoldenSpec =
    describe "report.golden.json regeneration" $ do
        found <- runIO (findReportGoldens fixturesRoot)
        it "every report golden has a regenerating writer" $
            found `shouldBe` sort (fst <$> reportGoldenWriters)
        forM_ found $ \path ->
            it ("regenerates " <> path <> " byte-for-byte") $
                case lookup path reportGoldenWriters of
                    Nothing ->
                        expectationFailure
                            ("no writer regenerates " <> path)
                    Just regenerate -> do
                        actual <- regenerate
                        update <- lookupEnv "UPDATE_GOLDENS"
                        when (update == Just "1") $
                            BSL.writeFile path actual
                        expected <- BSL.readFile path
                        shouldMatchGolden path actual expected

-- | Every @report.golden.json@ below a directory, sorted.
findReportGoldens :: FilePath -> IO [FilePath]
findReportGoldens dir = do
    paths <- fmap ((dir <> "/") <>) <$> listDirectory dir
    dirs <- filterM doesDirectoryExist paths
    nested <- concat <$> mapM findReportGoldens dirs
    let here = filter ("/report.golden.json" `isSuffixOf`) paths
    pure (sort (here <> nested))

{- | Byte equality; on failure name the first differing line and
how to regenerate.
-}
shouldMatchGolden
    :: FilePath -> BSL.ByteString -> BSL.ByteString -> Expectation
shouldMatchGolden path actual expected
    | actual == expected = pure ()
    | otherwise =
        expectationFailure $
            path
                <> " differs from its regeneration at line "
                <> show line
                <> "\n  golden:      "
                <> golden
                <> "\n  regenerated: "
                <> regenerated
                <> "\nrun UPDATE_GOLDENS=1 just golden;"
                <> " review the git diff"
  where
    (line, golden, regenerated) =
        firstDiff 1 (BSL8.lines expected) (BSL8.lines actual)
    firstDiff
        :: Int
        -> [BSL.ByteString]
        -> [BSL.ByteString]
        -> (Int, String, String)
    firstDiff n (e : es) (a : as)
        | e == a = firstDiff (n + 1) es as
    firstDiff n es as = (n, firstLine es, firstLine as)
    firstLine = maybe "<end of file>" (BSL8.unpack . fst) . uncons

fixtureSpec :: RenderFixture -> Spec
fixtureSpec fixture =
    it ("renders the checked-in " <> rfName fixture <> " envelope") $ do
        update <- lookupEnv "UPDATE_GOLDENS"
        output <-
            if update == Just "1"
                then buildAndWriteOutput fixture
                else readBuildOutput fixture
        actual <- renderReport output
        if update == Just "1"
            then TIO.writeFile (goldenPath fixture) actual
            else do
                exists <- doesFileExist (goldenPath fixture)
                if exists
                    then do
                        expected <- TIO.readFile (goldenPath fixture)
                        actual `shouldBe` expected
                        assertNoBareAddresses actual
                        assertNoBareHex28 actual
                    else
                        expectationFailure
                            ( "missing "
                                <> goldenPath fixture
                                <> "; run UPDATE_GOLDENS=1 just golden"
                            )

buildAndWriteOutput :: RenderFixture -> IO TxBuildOutput
buildAndWriteOutput fixture = do
    some <- readIntent (rfBuildDir fixture)
    build <- buildOutput (rfBuildDir fixture) some
    BSL.writeFile (inputPath fixture) (encodeBuildOutput build)
    pure build

buildOutput :: FilePath -> SomeTreasuryIntent -> IO TxBuildOutput
buildOutput fixtureDir some = do
    fixture <- readSwapFixture fixtureDir
    result <- runFromIntent (toFrozenContext fixture) some
    pure
        TxBuildOutput
            { txoIntent = some
            , txoResult =
                TxBuildOutputSuccess
                    TxBuildSuccess
                        { tbsTxCbor =
                            txCborHexFromBytes (brCborBytes result)
                        , tbsReport =
                            buildTransactionReport
                                (reportContext some)
                                result
                        }
            }

reportContext :: SomeTreasuryIntent -> ReportContext
reportContext (SomeTreasuryIntent _ intent) =
    ReportContext
        { rcNetwork = tiNetwork intent
        , rcSocketNetworkMagic = 764_824_073
        , rcSelectedScopeOwner =
            case tiSigners intent of
                owner : _ -> Just (owner, sjId (tiScope intent))
                [] -> Nothing
        , rcExtraSigners = drop 1 (tiSigners intent)
        , rcIntentRequiredSigners = []
        }

renderReport :: TxBuildOutput -> IO Text
renderReport output =
    case renderBuildOutput output of
        Left err -> fail ("render failed: " <> show err)
        Right (RenderOutput text) -> pure text

readBuildOutput :: RenderFixture -> IO TxBuildOutput
readBuildOutput fixture = do
    bytes <- BS.readFile (inputPath fixture)
    case eitherDecodeStrict' bytes of
        Left err -> fail ("decode failed: " <> err)
        Right output -> pure output

readIntent :: FilePath -> IO SomeTreasuryIntent
readIntent fixtureDir = do
    decoded <- decodeTreasuryIntentFile (fixtureDir <> "/intent.json")
    either (fail . ("intent JSON: " <>)) pure decoded

inputPath :: RenderFixture -> FilePath
inputPath fixture = rfReportDir fixture <> "/report.golden.json"

goldenPath :: RenderFixture -> FilePath
goldenPath fixture = rfReportDir fixture <> "/report.golden.md"

assertNoBareAddresses :: Text -> IO ()
assertNoBareAddresses rendered = do
    T.isInfixOf "addr1" rendered
        `shouldBe` False
    T.isInfixOf "addr_test1" rendered
        `shouldBe` False

assertNoBareHex28 :: Text -> IO ()
assertNoBareHex28 rendered =
    case filter isBareHex28 (T.words rendered) of
        [] -> pure ()
        (raw : _) ->
            expectationFailure
                ("rendered Markdown leaked a bare 28-byte hex: " <> T.unpack raw)
  where
    isBareHex28 token =
        let stripped =
                T.dropAround
                    (`elem` (",.;:()[]{}" :: String))
                    token
        in  T.length stripped == 56
                && T.all isLowerHex stripped

    isLowerHex c =
        isDigit c
            || ('a' <= c && c <= 'f')
