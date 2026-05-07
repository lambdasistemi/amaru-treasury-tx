{- |
Module      : SwapGoldenSpec
Description : Offline byte-parity golden for the swap CBOR
License     : Apache-2.0

Loads the frozen swap fixture under
@test/fixtures/swap/@, parses it as a unified
'SomeTreasuryIntent', builds the tx via 'runFromIntent'
against the resulting frozen 'ChainContext', and
byte-diffs the CBOR against @expected.cbor@.

This is the **SC-004 byte-identity gate** of feature
005: the recorded @expected.cbor@ bytes MUST NOT change
as a result of the unification refactor. The intent
JSON's shape changed (top-level @schema@ / @action@ /
@network@ added, scope gained @treasuryLeftoverUsdm@ /
@treasuryLeftoverOtherAssets@) but the on-chain
transaction shape is preserved.
-}
module SwapGoldenSpec (spec) where

import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as BSL
import Test.Hspec (Spec, describe, it, shouldBe)

import Amaru.Treasury.ChainContext.Fixture
    ( readSwapFixture
    , toFrozenContext
    )
import Amaru.Treasury.IntentJSON (decodeTreasuryIntentFile)
import Amaru.Treasury.TreasuryBuild
    ( TreasuryBuildResult (..)
    , runFromIntent
    )

fixtureDir :: FilePath
fixtureDir = "test/fixtures/swap"

spec :: Spec
spec =
    describe "swap golden (frozen ChainContext)" $ do
        it "rebuilds expected.cbor byte-for-byte" $ do
            si <-
                decodeTreasuryIntentFile
                    (fixtureDir <> "/intent.json")
            some <- case si of
                Left e -> error ("intent JSON: " <> e)
                Right v -> pure v
            fixture <- readSwapFixture fixtureDir
            let ctx = toFrozenContext fixture
            tbr <- runFromIntent ctx some
            let actualHex =
                    B16.encode
                        (BSL.toStrict (tbrCborBytes tbr))
            expected <-
                BS.readFile (fixtureDir <> "/expected.cbor")
            actualHex `shouldBe` expected
