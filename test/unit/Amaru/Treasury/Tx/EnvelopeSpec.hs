{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Tx.EnvelopeSpec
Description : Unit tests for cardano-cli envelope encoding
License     : Apache-2.0
-}
module Amaru.Treasury.Tx.EnvelopeSpec (spec) where

import Data.Text qualified as T
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

import Amaru.Treasury.Tx.Envelope
    ( EnvelopeError (..)
    , EnvelopeKind (..)
    , decodeEnvelope
    , encodeEnvelope
    , renderEnvelopeError
    )

spec :: Spec
spec =
    describe "Amaru.Treasury.Tx.Envelope" $ do
        it "emits cardano-cli key order and indentation for tx bodies" $
            encodeEnvelope Tx "deadbeef"
                `shouldBe` "{\n    \"type\": \"Tx ConwayEra\",\n    \"description\": \"Ledger Cddl Format\",\n    \"cborHex\": \"deadbeef\"\n}\n"

        it "emits cardano-cli witness description" $
            encodeEnvelope Witness "82582000"
                `shouldBe` "{\n    \"type\": \"TxWitness ConwayEra\",\n    \"description\": \"Key Witness ShelleyEra\",\n    \"cborHex\": \"82582000\"\n}\n"

        it "uses the tx envelope type for signed transactions" $
            encodeEnvelope SignedTx "84a0"
                `shouldBe` "{\n    \"type\": \"Tx ConwayEra\",\n    \"description\": \"Ledger Cddl Format\",\n    \"cborHex\": \"84a0\"\n}\n"

        it "keeps empty stdin as an empty cborHex string" $
            encodeEnvelope Tx ""
                `shouldBe` "{\n    \"type\": \"Tx ConwayEra\",\n    \"description\": \"Ledger Cddl Format\",\n    \"cborHex\": \"\"\n}\n"

        it "trims trailing ASCII whitespace before encoding" $
            encodeEnvelope Tx "deadbeef\n\t \r"
                `shouldBe` "{\n    \"type\": \"Tx ConwayEra\",\n    \"description\": \"Ledger Cddl Format\",\n    \"cborHex\": \"deadbeef\"\n}\n"

        describe "decodeEnvelope" $ do
            it "extracts cborHex and appends one trailing newline" $
                decodeEnvelope
                    "{\"type\":\"Tx ConwayEra\",\"description\":\"Ledger Cddl Format\",\"cborHex\":\"deadbeef\"}"
                    `shouldBe` Right "deadbeef\n"

            it "ignores description and extra top-level keys" $
                decodeEnvelope
                    "{\"type\":\"TxWitness ConwayEra\",\"description\":\"anything\",\"cborHex\":\"8258\",\"_source\":\"operator\"}"
                    `shouldBe` Right "8258\n"

            it "rejects input whose first non-whitespace byte is not an object" $
                decodeEnvelope "  deadbeef"
                    `shouldSatisfy` isNotEnvelopeJson

            it "rejects malformed JSON" $
                decodeEnvelope "{\"type\":\"Tx ConwayEra\""
                    `shouldSatisfy` isMalformedEnvelopeJson

            it "rejects envelopes missing type" $
                decodeEnvelope "{\"cborHex\":\"deadbeef\"}"
                    `shouldSatisfy` isMissingType

            it "rejects envelopes missing cborHex" $
                decodeEnvelope "{\"type\":\"Tx ConwayEra\"}"
                    `shouldSatisfy` isMissingCborHex

            it "rejects non-string type fields" $
                decodeEnvelope "{\"type\":1,\"cborHex\":\"deadbeef\"}"
                    `shouldSatisfy` isWrongTypeField

            it "rejects non-string cborHex fields" $
                decodeEnvelope "{\"type\":\"Tx ConwayEra\",\"cborHex\":1}"
                    `shouldSatisfy` isWrongCborHexField

            it "rejects stale eras and keeps the offending era in diagnostics" $
                case decodeEnvelope "{\"type\":\"Tx BabbageEra\",\"cborHex\":\"deadbeef\"}" of
                    Left err ->
                        renderEnvelopeError err
                            `shouldSatisfy` T.isInfixOf "BabbageEra"
                    Right raw ->
                        fail ("expected stale-era rejection, got " <> show raw)

isNotEnvelopeJson :: Either EnvelopeError a -> Bool
isNotEnvelopeJson = \case
    Left EnvelopeInputNotJsonObject{} -> True
    _ -> False

isMalformedEnvelopeJson :: Either EnvelopeError a -> Bool
isMalformedEnvelopeJson = \case
    Left EnvelopeMalformedJson{} -> True
    _ -> False

isMissingType :: Either EnvelopeError a -> Bool
isMissingType = \case
    Left (EnvelopeMissingField "type") -> True
    _ -> False

isMissingCborHex :: Either EnvelopeError a -> Bool
isMissingCborHex = \case
    Left (EnvelopeMissingField "cborHex") -> True
    _ -> False

isWrongTypeField :: Either EnvelopeError a -> Bool
isWrongTypeField = \case
    Left (EnvelopeWrongFieldType "type") -> True
    _ -> False

isWrongCborHexField :: Either EnvelopeError a -> Bool
isWrongCborHexField = \case
    Left (EnvelopeWrongFieldType "cborHex") -> True
    _ -> False
