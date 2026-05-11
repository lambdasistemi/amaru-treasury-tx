{- |
Module      : AdaDisburseGoldenSpec
Description : Offline byte-parity golden for the ADA disburse CBOR
License     : Apache-2.0

Loads the frozen disburse fixture under
@test/fixtures/disburse/ada/@, decodes the unified
@intent.json@, builds a tx via 'runFromIntent' against
the resulting frozen 'ChainContext', and byte-diffs the
CBOR against the upstream bash/cardano-cli oracle.

Mirrors 'SwapGoldenSpec'. Refuses to fall back to a live
build or self-recorded Haskell output; surfaces any byte
diff as a regression.
-}
module AdaDisburseGoldenSpec (spec) where

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
fixtureDir = "test/fixtures/disburse/ada"

newtype BashOracle = BashOracle Text

instance FromJSON BashOracle where
    parseJSON =
        withObject "BashOracle" $ \o ->
            BashOracle <$> o .: "cborHex"

spec :: Spec
spec =
    describe "ada-disburse golden (frozen ChainContext)" $
        it "rebuilds the bash oracle byte-for-byte" $ do
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
                        (BSL.toStrict (brCborBytes tbr))
            BashOracle oracleText <-
                BS.readFile (fixtureDir <> "/bash.oracle.tx.json")
                    >>= either
                        (error . ("oracle JSON: " <>))
                        pure
                        . eitherDecodeStrict'
            let oracleHex = Text.encodeUtf8 oracleText
            expected <- BS.readFile (fixtureDir <> "/body.cbor")
            expected `shouldBe` oracleHex
            actualHex `shouldBe` oracleHex
