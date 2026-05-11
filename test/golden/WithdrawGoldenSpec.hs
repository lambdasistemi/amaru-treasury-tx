{- |
Module      : WithdrawGoldenSpec
Description : Offline golden harness for the synthetic withdraw CBOR
License     : Apache-2.0

Loads the synthetic frozen withdraw fixture under
@test/fixtures/withdraw/synthetic/@, decodes the unified
@intent.json@, and builds a transaction via 'runFromIntent'
against the resulting frozen 'ChainContext'.

Set @UPDATE_GOLDENS=1@ to regenerate @expected.cbor@ from the checked-in
fixture. Without that explicit update flag, missing or changed bytes are
reported by the test.
-}
module WithdrawGoldenSpec (spec) where

import Control.Monad (unless)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as BSL
import System.Directory (doesFileExist)
import System.Environment (lookupEnv)
import Test.Hspec
    ( Spec
    , describe
    , it
    , pendingWith
    , shouldBe
    )

import Amaru.Treasury.Build
    ( BuildResult (..)
    , runFromIntent
    )
import Amaru.Treasury.ChainContext.Fixture
    ( readSwapFixture
    , toFrozenContext
    )
import Amaru.Treasury.IntentJSON
    ( decodeTreasuryIntentFile
    )

fixtureDir :: FilePath
fixtureDir = "test/fixtures/withdraw/synthetic"

spec :: Spec
spec =
    describe "withdraw golden (synthetic frozen ChainContext)" $
        it "rebuilds expected.cbor byte-for-byte" $ do
            intent <-
                decodeTreasuryIntentFile
                    (fixtureDir <> "/intent.json")
            some <- case intent of
                Left e -> error ("intent JSON: " <> e)
                Right ok -> pure ok
            fixture <- readSwapFixture fixtureDir
            let ctx = toFrozenContext fixture
                expectedPath = fixtureDir <> "/expected.cbor"
            expectedExists <- doesFileExist expectedPath
            update <- lookupEnv "UPDATE_GOLDENS"
            unless (expectedExists || update == Just "1") $
                pendingWith
                    "missing expected.cbor; run UPDATE_GOLDENS=1 just golden withdraw"
            tbr <- runFromIntent ctx some
            let actualHex =
                    B16.encode
                        (BSL.toStrict (brCborBytes tbr))
            if update == Just "1"
                then BS.writeFile expectedPath actualHex
                else do
                    expected <- BS.readFile expectedPath
                    actualHex `shouldBe` expected
