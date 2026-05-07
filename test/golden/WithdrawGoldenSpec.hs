{- |
Module      : WithdrawGoldenSpec
Description : Offline golden harness for the synthetic withdraw CBOR
License     : Apache-2.0

Loads the synthetic frozen withdraw fixture under
@test/fixtures/withdraw/synthetic/@, decodes the unified
@intent.json@, and builds a transaction via 'runFromIntent'
against the resulting frozen 'ChainContext'.

The checked-in @expected.cbor@ lands later in T040. Until then this
spec still proves that the intent and frozen context decode, while the
byte comparison remains pending.
-}
module WithdrawGoldenSpec (spec) where

import Control.Monad (unless)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as BSL
import System.Directory (doesFileExist)
import Test.Hspec
    ( Spec
    , describe
    , it
    , pendingWith
    , shouldBe
    )

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
            unless expectedExists $
                pendingWith
                    "T040 records expected.cbor after the withdraw builder lands"
            tbr <- runFromIntent ctx some
            let actualHex =
                    B16.encode
                        (BSL.toStrict (tbrCborBytes tbr))
            expected <- BS.readFile expectedPath
            actualHex `shouldBe` expected
