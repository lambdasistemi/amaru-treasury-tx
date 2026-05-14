{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Tx.EnvelopeSpec
Description : Unit tests for cardano-cli envelope encoding
License     : Apache-2.0
-}
module Amaru.Treasury.Tx.EnvelopeSpec (spec) where

import Test.Hspec (Spec, describe, it, shouldBe)

import Amaru.Treasury.Tx.Envelope
    ( EnvelopeKind (..)
    , encodeEnvelope
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
