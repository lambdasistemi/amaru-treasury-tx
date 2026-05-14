{-# LANGUAGE OverloadedStrings #-}

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
import Data.Text qualified as T
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    , shouldSatisfy
    )

import Amaru.Treasury.Tx.AttachWitness
    ( decodeUnsignedTxHex
    , encodeSignedTxHex
    , renderAttachError
    )
import Amaru.Treasury.Tx.Envelope
    ( EnvelopeKind (..)
    , decodeEnvelope
    , encodeEnvelope
    , renderEnvelopeError
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

        it "unwraps cardano-cli tx body envelopes to raw hex" $
            shouldDeEnvelope
                "tx.body.json"
                "tx.body.cborHex"

        it "unwraps cardano-cli witness envelopes to raw hex" $
            shouldDeEnvelope
                "tx.witness.json"
                "tx.witness.cborHex"

        it "unwraps cardano-cli signed tx envelopes to raw hex" $
            shouldDeEnvelope
                "tx.signed.json"
                "tx.signed.cborHex"

        it "rejects stale non-Conway envelopes with the offending era" $ do
            stale <- BS.readFile (fixtureDir <> "/tx.babbage.json")
            case decodeEnvelope stale of
                Left err ->
                    renderEnvelopeError err
                        `shouldSatisfy` T.isInfixOf "BabbageEra"
                Right raw ->
                    expectationFailure
                        ("expected BabbageEra rejection, got " <> show raw)

        it "feeds de-envelope tx body output into raw attach-witness decoding" $ do
            envelope <- BS.readFile (fixtureDir <> "/tx.body.json")
            raw <- BS.readFile (fixtureDir <> "/tx.body.cborHex")
            case decodeEnvelope envelope of
                Left err ->
                    expectationFailure (show (renderEnvelopeError err))
                Right deEnveloped ->
                    case decodeUnsignedTxHex deEnveloped of
                        Left err ->
                            expectationFailure (show (renderAttachError err))
                        Right tx ->
                            encodeSignedTxHex tx `shouldBe` raw

        it "keeps direct raw tx body decoding byte-identical" $ do
            raw <- BS.readFile (fixtureDir <> "/tx.body.cborHex")
            case decodeUnsignedTxHex raw of
                Left err ->
                    expectationFailure (show (renderAttachError err))
                Right tx ->
                    encodeSignedTxHex tx `shouldBe` raw

shouldDeEnvelope :: FilePath -> FilePath -> IO ()
shouldDeEnvelope envelopeFile rawFile = do
    envelope <- BS.readFile (fixtureDir <> "/" <> envelopeFile)
    raw <- BS.readFile (fixtureDir <> "/" <> rawFile)
    decodeEnvelope envelope `shouldBe` Right (raw <> "\n")
