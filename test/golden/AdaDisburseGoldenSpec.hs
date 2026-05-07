{- |
Module      : AdaDisburseGoldenSpec
Description : Offline byte-parity golden for the ADA disburse CBOR
License     : Apache-2.0

Loads the frozen disburse fixture under
@test/fixtures/disburse/ada/@, decodes the unified
@intent.json@, builds a tx via 'runFromIntent' against
the resulting frozen 'ChainContext', and byte-diffs the
CBOR against @body.cbor@.

Mirrors 'SwapGoldenSpec'. Refuses to fall back to a live
build; surfaces any byte diff as a regression. To
re-record the golden after an intentional change, set
@UPDATE_GOLDENS=1@ in the environment and re-run.
-}
module AdaDisburseGoldenSpec (spec) where

import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as BSL
import System.Directory (doesFileExist)
import System.Environment (lookupEnv)
import Test.Hspec (Spec, describe, it, shouldBe)

import Amaru.Treasury.ChainContext.Fixture
    ( readSwapFixture
    , toFrozenContext
    )
import Amaru.Treasury.IntentJSON
    ( decodeTreasuryIntentFile
    )
import Amaru.Treasury.TreasuryBuild
    ( TreasuryBuildResult (..)
    , runFromIntent
    )

fixtureDir :: FilePath
fixtureDir = "test/fixtures/disburse/ada"

spec :: Spec
spec =
    describe "ada-disburse golden (frozen ChainContext)" $
        it "rebuilds body.cbor byte-for-byte" $ do
            intent <-
                decodeTreasuryIntentFile
                    (fixtureDir <> "/intent.json")
            some <- case intent of
                Left e -> error ("intent JSON: " <> e)
                Right ok -> pure ok
            fixture <- readSwapFixture fixtureDir
            let ctx = toFrozenContext fixture
            tbr <- runFromIntent ctx some
            let actualHex =
                    B16.encode
                        (BSL.toStrict (tbrCborBytes tbr))
                goldenPath = fixtureDir <> "/body.cbor"
            update <- lookupEnv "UPDATE_GOLDENS"
            exists <- doesFileExist goldenPath
            if not exists || update == Just "1"
                then do
                    BS.writeFile goldenPath actualHex
                    error
                        ( "Golden written to "
                            <> goldenPath
                            <> "; review and re-run "
                            <> "without UPDATE_GOLDENS=1"
                        )
                else do
                    expected <- BS.readFile goldenPath
                    actualHex `shouldBe` expected
