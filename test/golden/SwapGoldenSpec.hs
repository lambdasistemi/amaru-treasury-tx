{- |
Module      : SwapGoldenSpec
Description : Offline byte-parity golden for the swap CBOR
License     : Apache-2.0

Loads the frozen swap fixture under
@test/fixtures/swap/@, builds a tx via
'runSwapBuild' against the resulting frozen
'ChainContext', and byte-diffs the CBOR against
@expected.cbor@.

This test runs without a node socket. It will refuse to
fall back to a live build and surfaces any byte diff as
a regression — either the builders changed, or the
fixture needs refreshing (see
[@docs/freeze-workflow.md@](https://github.com/lambdasistemi/amaru-treasury-tx/blob/feat/001-phase4-frozen-context/docs/freeze-workflow.md)).
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
import Amaru.Treasury.Tx.SwapBuild
    ( SwapBuildInputs (..)
    , SwapBuildResult (..)
    , runSwapBuild
    )
import Amaru.Treasury.Tx.SwapIntentJSON
    ( TranslatedIntent (..)
    , decodeSwapIntentFile
    , translateIntent
    )

fixtureDir :: FilePath
fixtureDir = "test/fixtures/swap"

spec :: Spec
spec =
    describe "swap golden (frozen ChainContext)" $ do
        it "rebuilds expected.cbor byte-for-byte" $ do
            sij <- decodeSwapIntentFile (fixtureDir <> "/intent.json")
            ti <- case sij of
                Left e -> error ("intent JSON: " <> e)
                Right v -> case translateIntent v of
                    Left e ->
                        error
                            ("intent translation: " <> e)
                    Right ok -> pure ok
            fixture <- readSwapFixture fixtureDir
            let ctx = toFrozenContext fixture
            sbr <-
                runSwapBuild
                    ctx
                    SwapBuildInputs
                        { sbiIntent = tiSwapIntent ti
                        , sbiRationale = tiRationale ti
                        , sbiWalletTxIn = tiWalletTxIn ti
                        , sbiWalletAddr = tiWalletAddr ti
                        }
            let actualHex =
                    B16.encode
                        (BSL.toStrict (sbrCborBytes sbr))
            expected <-
                BS.readFile (fixtureDir <> "/expected.cbor")
            actualHex `shouldBe` expected
