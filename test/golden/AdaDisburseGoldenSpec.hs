{- |
Module      : AdaDisburseGoldenSpec
Description : Offline local-fee golden for the ADA disburse CBOR
License     : Apache-2.0

Loads the frozen disburse fixture under
@test/fixtures/disburse/ada/@, decodes the unified
@intent.json@, builds a tx via 'runFromIntent' against
the resulting frozen 'ChainContext', and byte-diffs the
CBOR against the local expected-vkey fee target.

The upstream bash/cardano-cli oracle is still kept in the
fixture and asserted to differ. It uses the conservative
cardano-cli default witness estimate; the local target
prices one wallet witness plus the treasury required
signers.

Set @UPDATE_GOLDENS=1@ to regenerate @body.cbor@ from the
current Haskell builder output.
-}
module AdaDisburseGoldenSpec (spec) where

import Control.Monad (when)
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
import System.Environment (lookupEnv)
import Test.Hspec (Spec, describe, it, shouldBe, shouldNotBe)

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

{- | Two-destination ADA disburse fixture. Reuses the
single-destination frozen 'ChainContext' under
'fixtureDir'; its intent splits the same Σ across two
beneficiary outputs.
-}
multiDir :: FilePath
multiDir = "test/fixtures/disburse/ada-2dest"

newtype BashOracle = BashOracle Text

instance FromJSON BashOracle where
    parseJSON =
        withObject "BashOracle" $ \o ->
            BashOracle <$> o .: "cborHex"

spec :: Spec
spec =
    describe "ada-disburse golden (frozen ChainContext)" $ do
        it
            "rebuilds the local target; bash oracle differs by fee"
            $ do
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
                    BS.readFile
                        (fixtureDir <> "/bash.oracle.tx.json")
                        >>= either
                            (error . ("oracle JSON: " <>))
                            pure
                            . eitherDecodeStrict'
                let oracleHex = Text.encodeUtf8 oracleText
                    expectedPath = fixtureDir <> "/body.cbor"
                update <- lookupEnv "UPDATE_GOLDENS"
                when (update == Just "1") $
                    BS.writeFile expectedPath actualHex
                expected <- BS.readFile (fixtureDir <> "/body.cbor")
                actualHex `shouldBe` expected
                -- The bash/cardano-cli oracle prices the
                -- unsigned body with a conservative witness
                -- estimate. The local builder prices the
                -- expected signed tx witnesses instead.
                actualHex `shouldNotBe` oracleHex
        it
            "rebuilds the 2-destination target (leftover + 2 beneficiary outputs)"
            $ do
                intent <-
                    decodeTreasuryIntentFile
                        (multiDir <> "/intent.json")
                some <- case intent of
                    Left e -> error ("intent JSON: " <> e)
                    Right ok -> pure ok
                fixture <- readSwapFixture fixtureDir
                let ctx = toFrozenContext fixture
                tbr <- runFromIntent ctx some
                let actualHex =
                        B16.encode
                            (BSL.toStrict (brCborBytes tbr))
                    expectedPath = multiDir <> "/body.cbor"
                update <- lookupEnv "UPDATE_GOLDENS"
                when (update == Just "1") $
                    BS.writeFile expectedPath actualHex
                expected <- BS.readFile expectedPath
                actualHex `shouldBe` expected
                -- A 2-destination disburse is a different
                -- transaction than the single-destination
                -- golden built from the same context.
                n1 <- BS.readFile (fixtureDir <> "/body.cbor")
                actualHex `shouldNotBe` n1
