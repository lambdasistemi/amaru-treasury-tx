{- |
Module      : SwapGoldenSpec
Description : Offline byte-parity golden for the swap CBOR
License     : Apache-2.0

Loads the frozen swap fixture under
@test/fixtures/swap/@, parses it as a unified
'SomeTreasuryIntent', builds the tx via 'runFromIntent'
against the resulting frozen 'ChainContext', and
byte-diffs the CBOR against the upstream
bash/cardano-cli oracle.

This is the swap byte-identity gate: the checked-in
@expected.cbor@ must be the bash oracle's @cborHex@, and
the Haskell rebuild must match that same oracle.
-}
module SwapGoldenSpec (spec) where

import Data.Aeson
    ( FromJSON (..)
    , eitherDecodeStrict'
    , withObject
    , (.:)
    )
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as BSL
import Data.Text (Text)
import Data.Text.Encoding qualified as Text
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

newtype BashOracle = BashOracle Text

instance FromJSON BashOracle where
    parseJSON =
        withObject "BashOracle" $ \o ->
            BashOracle <$> o .: "cborHex"

spec :: Spec
spec =
    describe "swap golden (frozen ChainContext)" $ do
        it "rebuilds the bash oracle byte-for-byte" $ do
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
            BashOracle oracleText <-
                BS.readFile (fixtureDir <> "/bash.oracle.tx.json")
                    >>= either
                        (error . ("oracle JSON: " <>))
                        pure
                        . eitherDecodeStrict'
            let oracleHex = Text.encodeUtf8 oracleText
            expected <-
                BS.readFile (fixtureDir <> "/expected.cbor")
            expected `shouldBe` oracleHex
            actualHex `shouldBe` oracleHex
        it
            "legacy intent without extraTxIns rebuilds byte-identical bytes"
            $ do
                si <-
                    decodeTreasuryIntentFile
                        (fixtureDir <> "/legacy/intent.json")
                some <- case si of
                    Left e ->
                        error ("legacy intent JSON: " <> e)
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
