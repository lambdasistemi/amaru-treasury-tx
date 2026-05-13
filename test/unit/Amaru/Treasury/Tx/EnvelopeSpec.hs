{- |
Module      : Amaru.Treasury.Tx.EnvelopeSpec
Description : Unit tests for the cardano-cli envelope compat layer
License     : Apache-2.0

Coverage:

* Round-trip — writing a 'TxEnvelope' / 'SignedTxEnvelope' / etc. and
  reading the same file back yields the original hex bytes.
* Auto-detect — 'readEnvelopeOrHex' falls back to raw hex when the
  file is not JSON; reads the @cborHex@ when it is.
* Wrong-era rejection — a @Shelley@ envelope is rejected with
  'EnvelopeWrongEra'.
* Kind-mismatch — passing a witness envelope where a tx envelope is
  expected raises 'EnvelopeKindMismatch'.
* Rendered output — the rendered envelope JSON has the keys in
  cardano-cli order (@type@, @description@, @cborHex@).
-}
module Amaru.Treasury.Tx.EnvelopeSpec (spec) where

import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as B8
import System.IO (hClose)
import System.IO.Temp (withSystemTempFile)
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldSatisfy
    )

import Amaru.Treasury.Tx.Envelope
    ( EnvelopeError (..)
    , EnvelopeKind (..)
    , readEnvelopeOrHex
    , renderEnvelopeJson
    , writeEnvelopeFile
    )

spec :: Spec
spec = describe "Amaru.Treasury.Tx.Envelope" $ do
    describe "readEnvelopeOrHex" $ do
        it "falls back to raw hex when the file is not JSON" $
            withTempFile "raw" sampleHex $ \path -> do
                result <- readEnvelopeOrHex TxEnvelope path
                result `shouldBe` Right sampleHex

        it "extracts cborHex from a Conway tx-body envelope" $
            withTempFile "tx.json" sampleUnwitnessedEnvelope $ \path -> do
                result <- readEnvelopeOrHex TxEnvelope path
                result `shouldBe` Right sampleHex

        it "accepts a Signed Tx envelope where a tx is asked for" $
            withTempFile "signed.json" sampleSignedTxEnvelope $ \path -> do
                result <- readEnvelopeOrHex TxEnvelope path
                result `shouldBe` Right sampleHex

        it "extracts cborHex from a witness envelope" $
            withTempFile "wit.json" sampleWitnessEnvelope $ \path -> do
                result <- readEnvelopeOrHex WitnessEnvelope path
                result `shouldBe` Right sampleWitnessHex

        it "rejects a Shelley envelope" $
            withTempFile "shelley.json" sampleShelleyEnvelope $ \path -> do
                result <- readEnvelopeOrHex TxEnvelope path
                result `shouldSatisfy` isWrongEra

        it "rejects a witness envelope handed to a tx flag" $
            withTempFile "kindwrong.json" sampleWitnessEnvelope $ \path -> do
                result <- readEnvelopeOrHex TxEnvelope path
                result `shouldSatisfy` isKindMismatch

    describe "writeEnvelopeFile / round-trip" $ do
        it "writes a Signed Tx envelope and reads the same cborHex back" $
            withSystemTempFile "envelope.json" $ \path handle -> do
                hClose handle
                writeRes <-
                    writeEnvelopeFile SignedTxEnvelope path sampleHex
                writeRes `shouldBe` Right ()
                readBack <- readEnvelopeOrHex TxEnvelope path
                readBack `shouldBe` Right sampleHex

    describe "renderEnvelopeJson" $ do
        it
            "emits keys in cardano-cli order: type, description, cborHex"
            $ do
                let json = renderEnvelopeJson SignedTxEnvelope sampleHex
                B8.unpack json
                    `shouldBe` "{\n\
                               \    \"type\": \"Signed Tx ConwayEra\",\n\
                               \    \"description\": \"Ledger Cddl Format\",\n\
                               \    \"cborHex\": \"deadbeef\"\n\
                               \}\n"

withTempFile :: String -> ByteString -> (FilePath -> IO a) -> IO a
withTempFile name bytes action =
    withSystemTempFile name $ \path handle -> do
        B8.hPut handle bytes
        hClose handle
        action path

sampleHex :: ByteString
sampleHex = "deadbeef"

sampleWitnessHex :: ByteString
sampleWitnessHex = "82" <> "5820" <> "00" -- shape doesn't matter for these tests

sampleUnwitnessedEnvelope :: ByteString
sampleUnwitnessedEnvelope =
    "{\
    \\"type\":\"Unwitnessed Tx ConwayEra\",\
    \\"description\":\"Ledger Cddl Format\",\
    \\"cborHex\":\"deadbeef\"\
    \}"

sampleSignedTxEnvelope :: ByteString
sampleSignedTxEnvelope =
    "{\
    \\"type\":\"Signed Tx ConwayEra\",\
    \\"description\":\"Ledger Cddl Format\",\
    \\"cborHex\":\"deadbeef\"\
    \}"

sampleWitnessEnvelope :: ByteString
sampleWitnessEnvelope =
    "{\
    \\"type\":\"TxWitness ConwayEra\",\
    \\"description\":\"Key Witness ShelleyEra\",\
    \\"cborHex\":\"82582000\"\
    \}"

sampleShelleyEnvelope :: ByteString
sampleShelleyEnvelope =
    "{\
    \\"type\":\"Unwitnessed Tx ShelleyEra\",\
    \\"description\":\"Ledger Cddl Format\",\
    \\"cborHex\":\"deadbeef\"\
    \}"

isWrongEra :: Either EnvelopeError a -> Bool
isWrongEra = \case
    Left (EnvelopeWrongEra _ _) -> True
    _ -> False

isKindMismatch :: Either EnvelopeError a -> Bool
isKindMismatch = \case
    Left (EnvelopeKindMismatch _ _ _) -> True
    _ -> False
