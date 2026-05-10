{- |
Module      : ReportRenderSwapGoldenSpec
Description : Markdown golden for report-render swap output
License     : Apache-2.0

Renders the checked-in swap build-output envelope through the pure
Markdown renderer and compares the bytes with the checked-in
operator-facing report.
-}
module ReportRenderSwapGoldenSpec (spec) where

import Data.Aeson
    ( eitherDecodeStrict'
    )
import Data.ByteString qualified as BS
import Data.Char (isDigit)
import Data.Text (Text)
import Data.Text qualified as T
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

import Amaru.Treasury.Report
    ( TxBuildOutput
    )
import Amaru.Treasury.Report.Render
    ( RenderOutput (..)
    , renderBuildOutput
    )

fixtureDir :: FilePath
fixtureDir = "test/fixtures/swap"

goldenPath :: FilePath
goldenPath = fixtureDir <> "/report.golden.md"

inputPath :: FilePath
inputPath = fixtureDir <> "/report.golden.json"

spec :: Spec
spec =
    describe "report-render swap Markdown golden" $
        it "renders the checked-in swap envelope byte-for-byte" $ do
            actual <- renderSwapReport
            update <- lookupEnv "UPDATE_GOLDENS"
            case update of
                Just "1" -> TIO.writeFile goldenPath actual
                _ -> do
                    exists <- doesFileExist goldenPath
                    if exists
                        then do
                            expected <- TIO.readFile goldenPath
                            actual `shouldBe` expected
                            assertNoBareAddresses actual
                            assertNoBareHex28 actual
                        else
                            expectationFailure
                                ( "missing "
                                    <> goldenPath
                                    <> "; run UPDATE_GOLDENS=1 just golden"
                                )

renderSwapReport :: IO Text
renderSwapReport = do
    output <- readBuildOutput
    case renderBuildOutput output of
        Left err -> fail ("render failed: " <> show err)
        Right (RenderOutput text) -> pure text

readBuildOutput :: IO TxBuildOutput
readBuildOutput = do
    bytes <- BS.readFile inputPath
    case eitherDecodeStrict' bytes of
        Left err -> fail ("decode failed: " <> err)
        Right output -> pure output

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
