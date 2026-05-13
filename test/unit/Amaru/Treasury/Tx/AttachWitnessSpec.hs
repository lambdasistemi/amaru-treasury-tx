{- |
Module      : Amaru.Treasury.Tx.AttachWitnessSpec
Description : Unit tests for the attach-witness library
License     : Apache-2.0

Validates the decode/encode round-trip is byte-faithful, that
non-base16 input is rejected with a typed error, and that the witness
merge is a no-op when the input set is empty (so that operators who
re-run @attach-witness@ with no @--witness@ flags don't perturb the
unsigned bytes).
-}
module Amaru.Treasury.Tx.AttachWitnessSpec (spec) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Set qualified as Set
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldSatisfy
    )

import Amaru.Treasury.Tx.AttachWitness
    ( AttachError (..)
    , attachWitnesses
    , decodeUnsignedTxHex
    , encodeSignedTxHex
    , renderAttachError
    )

spec :: Spec
spec = describe "Amaru.Treasury.Tx.AttachWitness" $ do
    describe "decode / encode round-trip" $ do
        it "re-encodes the frozen swap fixture byte-identically" $ do
            hex <- BS.readFile fixtureSwapCbor
            case decodeUnsignedTxHex hex of
                Left err ->
                    fail $
                        "fixture failed to decode: "
                            <> show (renderAttachError err)
                Right tx ->
                    encodeSignedTxHex tx
                        `shouldBe` BS.filter (`BS.notElem` whitespaceBytes) hex

        it "tolerates a trailing newline in the input" $ do
            hex <- BS.readFile fixtureSwapCbor
            decodeUnsignedTxHex (hex <> "\n")
                `shouldSatisfy` isRight

    describe "attachWitnesses" $ do
        it "is a no-op for an empty witness set" $ do
            hex <- BS.readFile fixtureSwapCbor
            case decodeUnsignedTxHex hex of
                Left err ->
                    fail (show (renderAttachError err))
                Right tx ->
                    encodeSignedTxHex (attachWitnesses Set.empty tx)
                        `shouldBe` encodeSignedTxHex tx

    describe "decode error paths" $ do
        it "rejects invalid base16 with a typed error" $
            decodeUnsignedTxHex "deadbeefnothex"
                `shouldSatisfy` isAttachInvalidHex

        it "rejects valid base16 that is not a Conway tx" $
            decodeUnsignedTxHex "deadbeef"
                `shouldSatisfy` isAttachDecodeTxFailed

fixtureSwapCbor :: FilePath
fixtureSwapCbor = "test/fixtures/swap/expected.cbor"

whitespaceBytes :: ByteString
whitespaceBytes = BS.pack [0x20, 0x09, 0x0a, 0x0d]

isRight :: Either a b -> Bool
isRight = \case
    Right _ -> True
    Left _ -> False

isAttachInvalidHex :: Either AttachError a -> Bool
isAttachInvalidHex = \case
    Left (AttachInvalidHex _ _) -> True
    _ -> False

isAttachDecodeTxFailed :: Either AttachError a -> Bool
isAttachDecodeTxFailed = \case
    Left (AttachDecodeTxFailed _) -> True
    _ -> False
