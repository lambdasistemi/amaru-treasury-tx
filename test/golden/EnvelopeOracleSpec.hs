{- |
Module      : EnvelopeOracleSpec
Description : cardano-cli envelope byte-identity oracle
License     : Apache-2.0

Pins the exact JSON envelope shape emitted by a real @cardano-cli@
binary. These tests are the first RED source for issue #106:
production envelope code must match the oracle byte-for-byte.
-}
module EnvelopeOracleSpec (spec) where

import Data.ByteString qualified as BS
import Test.Hspec (Spec, describe, it, shouldBe)

import Amaru.Treasury.Tx.Envelope
    ( EnvelopeKind (..)
    , encodeEnvelope
    )

fixtureDir :: FilePath
fixtureDir = "test/fixtures/106-cardano-cli-oracle"

spec :: Spec
spec =
    describe "cardano-cli envelope oracle" $ do
        it "wraps tx body hex exactly like cardano-cli" $ do
            raw <- BS.readFile (fixtureDir <> "/tx.body.cborHex")
            oracle <- BS.readFile (fixtureDir <> "/tx.body.json")
            encodeEnvelope Tx raw `shouldBe` oracle

        it "wraps witness hex exactly like cardano-cli" $ do
            raw <- BS.readFile (fixtureDir <> "/tx.witness.cborHex")
            oracle <- BS.readFile (fixtureDir <> "/tx.witness.json")
            encodeEnvelope Witness raw `shouldBe` oracle

        it "wraps signed tx hex exactly like cardano-cli" $ do
            raw <- BS.readFile (fixtureDir <> "/tx.signed.cborHex")
            oracle <- BS.readFile (fixtureDir <> "/tx.signed.json")
            encodeEnvelope SignedTx raw `shouldBe` oracle
